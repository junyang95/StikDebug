import XCTest
@testable import WLOCProbeCore

final class CertificateProtocolTests: XCTestCase {
    private let info = WLOCCertificateInfo(commonName: "StikDebug WLOC Test",
        fingerprintSHA256: String(repeating: "ab", count: 32), notBefore: Date(),
        notAfter: Date().addingTimeInterval(86400), certificateDER: Data([0x30, 0x01, 0x00]))

    func testProfileContainsOnlyRemovablePublicRoot() throws {
        let data = try WLOCCertificateProfile.make(info: info)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(plist["PayloadRemovalDisallowed"] as? Bool, false)
        let payloads = try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0]["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payloads[0]["PayloadContent"] as? Data, info.certificateDER)
        XCTAssertEqual(Set(payloads[0].keys), Set(["PayloadType", "PayloadVersion", "PayloadIdentifier", "PayloadUUID", "PayloadDisplayName", "PayloadContent", "PayloadCertificateFileName"]))
        XCTAssertEqual(try WLOCCertificateProfile.make(info: info), data)
    }

    func testReplyRoundTripIsPublicOnly() throws {
        let encoded = try JSONEncoder().encode(WLOCCertificateReply(info: info, systemTrusted: false))
        let decoded = try JSONDecoder().decode(WLOCCertificateReply.self, from: encoded)
        XCTAssertEqual(decoded.info, info)
        XCTAssertEqual(decoded.systemTrusted, false)
        XCTAssertNil(decoded.downloadURL)
        XCTAssertNil(decoded.error)
    }

    func testRejectsInvalidFingerprintAndOversizedCertificate() {
        for (fingerprint, certificate) in [("oops", Data([1])), (info.fingerprintSHA256, Data()),
                                         (info.fingerprintSHA256, Data(repeating: 0, count: 16 * 1024 + 1))] {
            let invalid = WLOCCertificateInfo(commonName: info.commonName, fingerprintSHA256: fingerprint,
                notBefore: info.notBefore, notAfter: info.notAfter, certificateDER: certificate)
            XCTAssertThrowsError(try WLOCCertificateProfile.make(info: invalid))
        }
    }
}
