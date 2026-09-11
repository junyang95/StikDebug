import CryptoKit
import Foundation
import Security
import X509
#if SWIFT_PACKAGE
import WLOCProbeCore
#endif

public enum WLOCCertificateError: Error, Equatable, LocalizedError {
    case keychain(operation: String, status: OSStatus)
    case incompleteMaterial
    case ambiguousMaterial
    case invalidMaterial(String)
    case operationFailed(domain: String, code: Int)
    case notPrepared
    case unsupportedHostname

    public var errorDescription: String? {
        switch self {
        case let .keychain(operation, status):
            return "证书钥匙串操作失败（\(operation)，\(status)）。现有材料未自动覆盖，请联系开发者诊断。"
        case .incompleteMaterial:
            return "已保存的根证书或私钥缺失，未自动覆盖。请联系开发者诊断，不要为此卸载整个 App。"
        case .ambiguousMaterial:
            return "发现多个匹配的证书材料，未自动覆盖。请联系开发者诊断，不要为此卸载整个 App。"
        case let .invalidMaterial(reason):
            return "已保存的证书材料无效（\(reason)），未自动覆盖。请联系开发者诊断，不要为此卸载整个 App。"
        case let .operationFailed(domain, code):
            return "证书生成或校验失败（\(domain)，\(code)），现有材料未自动覆盖。请联系开发者诊断。"
        case .notPrepared:
            return "请先生成本设备的实验证书。"
        case .unsupportedHostname:
            return "此域名不在实验证书的允许范围内。"
        }
    }
}

/// Owned by the tunnel extension. No operation exports private key bytes or changes system trust.
public final class WLOCCertificateAuthority {
    // All instances in the extension serialize the read/create pair, including fresh instances.
    private static let materialLock = NSLock()
    private let store: any WLOCCertificateMaterialStore
    private let now: () -> Date

    public convenience init() {
        self.init(store: WLOCKeychainCertificateStore())
    }

    init(store: any WLOCCertificateMaterialStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func prepare() throws -> WLOCCertificateInfo {
        try withMaterialLock {
            if let material = try loadMaterial() { return material.info }
            let key = try store.createPrivateKey()
            let root = try WLOCCertificateFactory.makeRoot(privateKey: key, now: now())
            let der = try WLOCCertificateFactory.der(root)
            // A failed certificate save deliberately leaves the key in place. A later call reports
            // incomplete material instead of silently replacing an already exported/trusted CA.
            try store.saveRootCertificateDER(der)
            guard let material = try loadMaterial() else {
                throw WLOCCertificateError.incompleteMaterial
            }
            return material.info
        }
    }

    public func status() throws -> WLOCCertificateInfo? {
        try withMaterialLock { try loadMaterial()?.info }
    }

    public func rootCertificateDER() throws -> Data {
        try withMaterialLock {
            guard let material = try loadMaterial() else { throw WLOCCertificateError.notPrepared }
            return material.info.certificateDER
        }
    }

    /// This is a system-anchor check, not an application-local trust override or a TLS handshake.
    public func verifySystemTrust() throws -> Bool {
        try withMaterialLock {
            guard let material = try loadMaterial() else { throw WLOCCertificateError.notPrepared }
            let leafKey = try WLOCCertificateFactory.makeEphemeralKey()
            let hostname = WLOCCertificateFactory.trustTestHostname
            let leaf = try WLOCCertificateFactory.makeLeaf(
                privateKey: leafKey, root: material.root, rootPrivateKey: material.key,
                hostname: hostname, now: now()
            )
            return try WLOCCertificateFactory.evaluateSystemTrust(
                leaf: leaf, root: material.root, hostname: hostname
            )
        }
    }

    private struct Material {
        let key: SecKey
        let root: X509.Certificate
        let info: WLOCCertificateInfo
    }

    private func loadMaterial() throws -> Material? {
        let key = try store.loadPrivateKey()
        let der = try store.loadRootCertificateDER()
        if key == nil && der == nil { return nil }
        guard let key, let der else { throw WLOCCertificateError.incompleteMaterial }
        let root: X509.Certificate
        do { root = try X509.Certificate(derEncoded: Array(der)) }
        catch { throw WLOCCertificateError.invalidMaterial("certificate encoding") }
        try WLOCCertificateFactory.validateRoot(root, privateKey: key, now: now())
        let secCertificate = try SecCertificate.makeWithCertificate(root)
        var commonName: CFString?
        guard SecCertificateCopyCommonName(secCertificate, &commonName) == errSecSuccess,
              let commonName else {
            throw WLOCCertificateError.invalidMaterial("missing common name")
        }
        let info = WLOCCertificateInfo(
            commonName: commonName as String,
            fingerprintSHA256: SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(),
            notBefore: root.notValidBefore, notAfter: root.notValidAfter, certificateDER: der
        )
        return Material(key: key, root: root, info: info)
    }

    private func withMaterialLock<T>(_ body: () throws -> T) throws -> T {
        Self.materialLock.lock()
        defer { Self.materialLock.unlock() }
        do { return try body() }
        catch let error as WLOCCertificateError { throw error }
        catch {
            // Retain a diagnostic domain/code without exposing a framework's arbitrary
            // object description or replacing the user's saved material on failure.
            let underlying = error as NSError
            throw WLOCCertificateError.operationFailed(domain: underlying.domain, code: underlying.code)
        }
    }
}

/// Typed X.509 construction and signature validation; no Keychain storage or DER hand-encoding.
enum WLOCCertificateFactory {
    static let rootLifetime: TimeInterval = 90 * 24 * 60 * 60
    static let trustTestHostname = "gs-loc.apple.com"

    static func makeEphemeralKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw WLOCCertificateError.invalidMaterial("key generation")
        }
        return key
    }

    static func makeRoot(privateKey: SecKey, now: Date) throws -> X509.Certificate {
        let key = try X509.Certificate.PrivateKey(privateKey)
        let subject = try DistinguishedName {
            CommonName("StikDebug WLOC Test CA \(UUID().uuidString)")
        }
        let notBefore = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 60)
        return try X509.Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: notBefore, notValidAfter: notBefore.addingTimeInterval(rootLifetime),
            issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: X509.Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: key
        )
    }

    static func validateRoot(_ root: X509.Certificate, privateKey: SecKey, now: Date) throws {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits] as? Int == 256 else {
            throw WLOCCertificateError.invalidMaterial("expected P-256 private key")
        }
        let key: X509.Certificate.PrivateKey
        do { key = try X509.Certificate.PrivateKey(privateKey) }
        catch { throw WLOCCertificateError.invalidMaterial("private key") }
        guard root.version == .v3, root.issuer == root.subject,
              root.publicKey == key.publicKey, root.signatureAlgorithm == .ecdsaWithSHA256,
              root.publicKey.isValidSignature(root.signature, for: root) else {
            throw WLOCCertificateError.invalidMaterial("root signature or key mismatch")
        }
        guard root.notValidBefore <= now, now < root.notValidAfter,
              root.notValidAfter.timeIntervalSince(root.notValidBefore) == rootLifetime else {
            throw WLOCCertificateError.invalidMaterial("validity interval")
        }
        do {
            guard try root.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0),
                  try root.extensions.keyUsage == KeyUsage(keyCertSign: true, cRLSign: true),
                  root.extensions.first(where: { $0.oid == .X509ExtensionID.basicConstraints })?.critical == true,
                  root.extensions.first(where: { $0.oid == .X509ExtensionID.keyUsage })?.critical == true,
                  try root.extensions.subjectKeyIdentifier == SubjectKeyIdentifier(hash: root.publicKey) else {
                throw WLOCCertificateError.invalidMaterial("CA constraints")
            }
        } catch let error as WLOCCertificateError { throw error }
        catch { throw WLOCCertificateError.invalidMaterial("CA extensions") }
    }

    /// Deliberately limited to the single hostname used by the stage-2 trust probe.
    static func makeLeaf(
        privateKey: SecKey, root: X509.Certificate, rootPrivateKey: SecKey,
        hostname: String, now: Date
    ) throws -> X509.Certificate {
        guard hostname == trustTestHostname else { throw WLOCCertificateError.unsupportedHostname }
        try validateRoot(root, privateKey: rootPrivateKey, now: now)
        let key = try X509.Certificate.PrivateKey(privateKey)
        let signer = try X509.Certificate.PrivateKey(rootPrivateKey)
        let subject = try DistinguishedName { CommonName(hostname) }
        let notBefore = max(root.notValidBefore, Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 60))
        let notAfter = min(root.notValidAfter, notBefore.addingTimeInterval(24 * 60 * 60))
        return try X509.Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: notBefore, notValidAfter: notAfter,
            issuer: root.subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: X509.Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(hostname)])
                SubjectKeyIdentifier(hash: key.publicKey)
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
            },
            issuerPrivateKey: signer
        )
    }

    static func der(_ certificate: X509.Certificate) throws -> Data {
        SecCertificateCopyData(try SecCertificate.makeWithCertificate(certificate)) as Data
    }

    static func evaluateSystemTrust(
        leaf: X509.Certificate, root: X509.Certificate, hostname: String
    ) throws -> Bool {
        guard hostname == trustTestHostname else { throw WLOCCertificateError.unsupportedHostname }
        let certificates = try [SecCertificate.makeWithCertificate(leaf), SecCertificate.makeWithCertificate(root)]
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else {
            throw WLOCCertificateError.keychain(operation: "create trust", status: status)
        }
        // The root in the supplied chain is not a trust anchor. Only the OS/user trust store
        // may anchor this evaluation; there are intentionally no custom anchors or exceptions.
        let fetchStatus = SecTrustSetNetworkFetchAllowed(trust, false)
        guard fetchStatus == errSecSuccess else {
            throw WLOCCertificateError.keychain(operation: "disable trust fetch", status: fetchStatus)
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
