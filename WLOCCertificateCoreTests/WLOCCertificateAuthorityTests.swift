import CryptoKit
import Foundation
import Security
import XCTest
import X509
@testable import WLOCCertificateCore

final class WLOCCertificateAuthorityTests: XCTestCase {
    private let testDate = Date(timeIntervalSince1970: 1_789_084_800)

    func testInitializationAndReadOnlyStatusDoNotGenerateMaterial() throws {
        let store = MemoryCertificateStore()
        let authority = WLOCCertificateAuthority(store: store)
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.createCount, 0)
        XCTAssertNil(try authority.status())
        XCTAssertThrowsError(try authority.rootCertificateDER()) {
            XCTAssertEqual($0 as? WLOCCertificateError, .notPrepared)
        }
        XCTAssertThrowsError(try authority.verifySystemTrust()) {
            XCTAssertEqual($0 as? WLOCCertificateError, .notPrepared)
        }
        XCTAssertEqual(store.createCount, 0)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testPrepareIsIdempotentAndPublicInfoContainsOnlyCertificateMaterial() throws {
        let store = MemoryCertificateStore()
        let authority = WLOCCertificateAuthority(store: store, now: { self.testDate })
        let info = try authority.prepare()
        XCTAssertEqual(try authority.prepare(), info)
        XCTAssertEqual(try authority.status(), info)
        XCTAssertEqual(try authority.rootCertificateDER(), info.certificateDER)
        XCTAssertEqual(store.createCount, 1)
        XCTAssertEqual(store.saveCount, 1)

        let certificate = try X509.Certificate(derEncoded: Array(info.certificateDER))
        XCTAssertEqual(try WLOCCertificateFactory.der(certificate), info.certificateDER)
        XCTAssertTrue(info.commonName.hasPrefix("StikDebug WLOC Test CA "))
        XCTAssertEqual(info.notBefore, certificate.notValidBefore)
        XCTAssertEqual(info.notAfter, certificate.notValidAfter)
        XCTAssertEqual(info.fingerprintSHA256.count, 64)
        XCTAssertTrue(info.fingerprintSHA256.allSatisfy { "0123456789ABCDEF".contains($0) })
        XCTAssertEqual(info.fingerprintSHA256,
                       SHA256.hash(data: info.certificateDER).map { String(format: "%02X", $0) }.joined())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set([
            "commonName", "fingerprintSHA256", "notBefore", "notAfter", "certificateDER"
        ]))
        // The certificate round-trip consumes the complete DER object. The public response
        // carries only that object, not a PEM/PKCS#12 archive or an appended private key.
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(json["certificateDER"] as? String)), info.certificateDER)
    }

    func testSeparateAuthoritiesGenerateUniqueRootsAndKeys() throws {
        let firstStore = MemoryCertificateStore()
        let secondStore = MemoryCertificateStore()
        let first = try WLOCCertificateAuthority(store: firstStore).prepare()
        let second = try WLOCCertificateAuthority(store: secondStore).prepare()
        let firstRoot = try X509.Certificate(derEncoded: Array(first.certificateDER))
        let secondRoot = try X509.Certificate(derEncoded: Array(second.certificateDER))
        XCTAssertNotEqual(first.commonName, second.commonName)
        XCTAssertNotEqual(first.fingerprintSHA256, second.fingerprintSHA256)
        XCTAssertNotEqual(firstRoot.serialNumber, secondRoot.serialNumber)
        XCTAssertNotEqual(firstRoot.publicKey, secondRoot.publicKey)
    }

    func testRootHasNinetyDayValidityAndCriticalCAConstraints() throws {
        let key = try WLOCCertificateFactory.makeEphemeralKey()
        let root = try WLOCCertificateFactory.makeRoot(privateKey: key, now: testDate)
        XCTAssertEqual(root.version, .v3)
        XCTAssertEqual(root.issuer, root.subject)
        XCTAssertEqual(root.signatureAlgorithm, .ecdsaWithSHA256)
        XCTAssertTrue(root.publicKey.isValidSignature(root.signature, for: root))
        XCTAssertEqual(root.notValidAfter.timeIntervalSince(root.notValidBefore), 90 * 24 * 60 * 60)
        XCTAssertLessThanOrEqual(root.notValidBefore, testDate)
        XCTAssertGreaterThan(root.notValidAfter, testDate)
        XCTAssertEqual(try root.extensions.basicConstraints, .isCertificateAuthority(maxPathLength: 0))
        XCTAssertEqual(try root.extensions.keyUsage, KeyUsage(keyCertSign: true, cRLSign: true))
        XCTAssertEqual(root.extensions.first { $0.oid == .X509ExtensionID.basicConstraints }?.critical, true)
        XCTAssertEqual(root.extensions.first { $0.oid == .X509ExtensionID.keyUsage }?.critical, true)
        XCTAssertEqual(try root.extensions.subjectKeyIdentifier, SubjectKeyIdentifier(hash: root.publicKey))
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(key) as? [CFString: Any])
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits] as? Int, 256)
        XCTAssertEqual(attributes[kSecAttrKeyType] as? String, kSecAttrKeyTypeECSECPrimeRandom as String)
        try WLOCCertificateFactory.validateRoot(root, privateKey: key, now: testDate)
    }

    func testLeafHasExactSANServerAuthAndRootSignature() throws {
        let rootKey = try WLOCCertificateFactory.makeEphemeralKey()
        let leafKey = try WLOCCertificateFactory.makeEphemeralKey()
        let root = try WLOCCertificateFactory.makeRoot(privateKey: rootKey, now: testDate)
        let leaf = try makeLeaf(root: root, rootKey: rootKey, leafKey: leafKey, now: testDate)
        XCTAssertEqual(leaf.issuer, root.subject)
        XCTAssertNotEqual(leaf.publicKey, root.publicKey)
        XCTAssertTrue(root.publicKey.isValidSignature(leaf.signature, for: leaf))
        XCTAssertFalse(leaf.publicKey.isValidSignature(leaf.signature, for: leaf))
        XCTAssertEqual(try leaf.extensions.basicConstraints, .notCertificateAuthority)
        XCTAssertEqual(try leaf.extensions.keyUsage, KeyUsage(digitalSignature: true))
        XCTAssertEqual(try leaf.extensions.extendedKeyUsage, try ExtendedKeyUsage([.serverAuth]))
        XCTAssertEqual(try leaf.extensions.subjectAlternativeNames,
                       SubjectAlternativeNames([.dnsName("gs-loc.apple.com")]))
        XCTAssertEqual(leaf.extensions.first { $0.oid == .X509ExtensionID.basicConstraints }?.critical, true)
        XCTAssertEqual(try leaf.extensions.authorityKeyIdentifier?.keyIdentifier,
                       SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
        XCTAssertGreaterThanOrEqual(leaf.notValidBefore, root.notValidBefore)
        XCTAssertLessThanOrEqual(leaf.notValidAfter, root.notValidAfter)
        XCTAssertLessThanOrEqual(leaf.notValidAfter.timeIntervalSince(leaf.notValidBefore), 24 * 60 * 60)
        let another = try makeLeaf(root: root, rootKey: rootKey, leafKey: leafKey, now: testDate)
        XCTAssertNotEqual(leaf.serialNumber, another.serialNumber)
    }

    func testLeafIssuanceRejectsUnapprovedOrNonExactHostnames() throws {
        let key = try WLOCCertificateFactory.makeEphemeralKey()
        let root = try WLOCCertificateFactory.makeRoot(privateKey: key, now: testDate)
        for hostname in ["example.com", "*.apple.com", "GS-LOC.APPLE.COM", "gs-loc.apple.com.", "gs-loc.apple.com.evil.test"] {
            XCTAssertThrowsError(try WLOCCertificateFactory.makeLeaf(
                privateKey: key, root: root, rootPrivateKey: key, hostname: hostname, now: testDate
            )) { XCTAssertEqual($0 as? WLOCCertificateError, .unsupportedHostname) }
        }
    }

    func testValidLeafPassesOnlyExplicitTestAnchorAndCorrectHostname() throws {
        // Explicit anchors exist only in this test helper, never in verifySystemTrust().
        let now = Date()
        let rootKey = try WLOCCertificateFactory.makeEphemeralKey()
        let leafKey = try WLOCCertificateFactory.makeEphemeralKey()
        let root = try WLOCCertificateFactory.makeRoot(privateKey: rootKey, now: now)
        let leaf = try makeLeaf(root: root, rootKey: rootKey, leafKey: leafKey, now: now)
        XCTAssertTrue(try evaluateWithTestAnchor(leaf: leaf, root: root, hostname: "gs-loc.apple.com"))
        XCTAssertFalse(try evaluateWithTestAnchor(leaf: leaf, root: root, hostname: "example.com"))
        XCTAssertFalse(try WLOCCertificateFactory.evaluateSystemTrust(
            leaf: leaf, root: root, hostname: "gs-loc.apple.com"
        ))
    }

    func testFreshAuthorityIsNotSystemTrustedAndTrustCheckDoesNotPersistLeaf() throws {
        let store = MemoryCertificateStore()
        let authority = WLOCCertificateAuthority(store: store)
        let info = try authority.prepare()
        XCTAssertFalse(try authority.verifySystemTrust())
        XCTAssertEqual(try authority.status(), info)
        XCTAssertEqual(store.createCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testMissingEitherHalfFailsWithoutGeneratingReplacement() throws {
        let complete = MemoryCertificateStore()
        _ = try WLOCCertificateAuthority(store: complete).prepare()
        for store in [
            MemoryCertificateStore(key: complete.key, rootDER: nil),
            MemoryCertificateStore(key: nil, rootDER: complete.rootDER)
        ] {
            let authority = WLOCCertificateAuthority(store: store)
            XCTAssertThrowsError(try authority.status()) {
                XCTAssertEqual($0 as? WLOCCertificateError, .incompleteMaterial)
            }
            XCTAssertThrowsError(try authority.prepare()) {
                XCTAssertEqual($0 as? WLOCCertificateError, .incompleteMaterial)
            }
            XCTAssertEqual(store.createCount, 0)
            XCTAssertEqual(store.saveCount, 0)
        }
    }

    func testCorruptCertificateAndMismatchedKeyDoNotReplaceMaterial() throws {
        let store = MemoryCertificateStore()
        _ = try WLOCCertificateAuthority(store: store).prepare()
        let validDER = try XCTUnwrap(store.rootDER)
        var corruptSignature = validDER
        corruptSignature[corruptSignature.count - 1] ^= 1
        for invalidStore in [
            MemoryCertificateStore(key: store.key, rootDER: Data([0, 1, 2, 3])),
            MemoryCertificateStore(key: store.key, rootDER: corruptSignature),
            MemoryCertificateStore(key: try WLOCCertificateFactory.makeEphemeralKey(), rootDER: validDER)
        ] {
            let authority = WLOCCertificateAuthority(store: invalidStore)
            let before = invalidStore.rootDER
            XCTAssertThrowsError(try authority.prepare()) { error in
                guard case .invalidMaterial = error as? WLOCCertificateError else {
                    return XCTFail("Expected invalid material, got \(error)")
                }
            }
            XCTAssertEqual(invalidStore.rootDER, before)
            XCTAssertEqual(invalidStore.createCount, 0)
            XCTAssertEqual(invalidStore.saveCount, 0)
        }
    }

    func testExpiredRootFailsWithoutAutomaticRotation() throws {
        let store = MemoryCertificateStore()
        let info = try WLOCCertificateAuthority(store: store, now: { self.testDate }).prepare()
        let expired = WLOCCertificateAuthority(store: store, now: { info.notAfter })
        XCTAssertThrowsError(try expired.prepare()) {
            XCTAssertEqual($0 as? WLOCCertificateError, .invalidMaterial("validity interval"))
        }
        XCTAssertEqual(store.rootDER, info.certificateDER)
        XCTAssertEqual(store.createCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testFailedCertificateSaveLeavesKeyAndNextPrepareFailsClosed() throws {
        let store = MemoryCertificateStore()
        store.rejectSave = true
        let authority = WLOCCertificateAuthority(store: store)
        XCTAssertThrowsError(try authority.prepare())
        XCTAssertNotNil(store.key)
        XCTAssertNil(store.rootDER)
        store.rejectSave = false
        XCTAssertThrowsError(try authority.prepare()) {
            XCTAssertEqual($0 as? WLOCCertificateError, .incompleteMaterial)
        }
        XCTAssertEqual(store.createCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    private func makeLeaf(
        root: X509.Certificate, rootKey: SecKey, leafKey: SecKey, now: Date
    ) throws -> X509.Certificate {
        try WLOCCertificateFactory.makeLeaf(
            privateKey: leafKey, root: root, rootPrivateKey: rootKey,
            hostname: "gs-loc.apple.com", now: now
        )
    }

    private func evaluateWithTestAnchor(
        leaf: X509.Certificate, root: X509.Certificate, hostname: String
    ) throws -> Bool {
        let leafRef = try SecCertificate.makeWithCertificate(leaf)
        let rootRef = try SecCertificate.makeWithCertificate(root)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(
            [leafRef, rootRef] as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust
        ), errSecSuccess)
        let evaluation = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(evaluation, false), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificates(evaluation, [rootRef] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(evaluation, true), errSecSuccess)
        var error: CFError?
        return SecTrustEvaluateWithError(evaluation, &error)
    }
}

private final class MemoryCertificateStore: WLOCCertificateMaterialStore {
    var key: SecKey?
    var rootDER: Data?
    var readCount = 0
    var createCount = 0
    var saveCount = 0
    var rejectSave = false

    init(key: SecKey? = nil, rootDER: Data? = nil) {
        self.key = key
        self.rootDER = rootDER
    }

    func loadPrivateKey() throws -> SecKey? {
        readCount += 1
        return key
    }

    func loadRootCertificateDER() throws -> Data? {
        readCount += 1
        return rootDER
    }

    func createPrivateKey() throws -> SecKey {
        createCount += 1
        let generated = try WLOCCertificateFactory.makeEphemeralKey()
        key = generated
        return generated
    }

    func saveRootCertificateDER(_ data: Data) throws {
        saveCount += 1
        if rejectSave { throw WLOCCertificateError.keychain(operation: "test save", status: errSecIO) }
        rootDER = data
    }
}
