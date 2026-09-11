import Foundation
import Security

protocol WLOCCertificateMaterialStore: AnyObject {
    func loadPrivateKey() throws -> SecKey?
    func loadRootCertificateDER() throws -> Data?
    func createPrivateKey() throws -> SecKey
    func saveRootCertificateDER(_ data: Data) throws
}

/// Uses the signed default Keychain group; no new group entitlement, App Group, or sync.
/// A re-signer may assign that group to other apps too: this is not extension-only isolation.
final class WLOCKeychainCertificateStore: WLOCCertificateMaterialStore {
    private let namespace = Bundle.main.bundleIdentifier ?? "app.stikdebug.wloc"
    private var keyTag: Data { Data("\(namespace).wloc.stage2.ca.private-key.v1".utf8) }
    private var certificateLabel: String { "StikDebug WLOC Stage 2 Root v1 (\(namespace))" }

    func loadPrivateKey() throws -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable: false,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw WLOCCertificateError.keychain(operation: "read private key", status: status)
        }
        guard let keys = result as? [SecKey], keys.count == 1 else {
            throw WLOCCertificateError.ambiguousMaterial
        }
        return keys[0]
    }

    func loadRootCertificateDER() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecAttrSynchronizable: false,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw WLOCCertificateError.keychain(operation: "read root certificate", status: status)
        }
        guard let certificates = result as? [SecCertificate], certificates.count == 1 else {
            throw WLOCCertificateError.ambiguousMaterial
        }
        return SecCertificateCopyData(certificates[0]) as Data
    }

    func createPrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable: false
            ]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw WLOCCertificateError.invalidMaterial("Keychain key generation")
        }
        return key
    }

    func saveRootCertificateDER(_ data: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw WLOCCertificateError.invalidMaterial("root DER")
        }
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: certificateLabel,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WLOCCertificateError.keychain(operation: "save root certificate", status: status)
        }
    }
}
