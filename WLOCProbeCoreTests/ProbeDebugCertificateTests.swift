#if DEBUG
import XCTest
@testable import WLOCProbeCore

final class ProbeDebugCertificateTests: XCTestCase {
    private func certificate() -> ProbeDebugCertificate {
        ProbeDebugCertificate(prepared: true, fingerprintSHA256: String(repeating: "AB09", count: 16),
                              notAfter: 2000, systemTrusted: false, checkedAt: 1000.5)
    }

    private func record(_ certificate: ProbeDebugCertificate) -> ProbeDebugRecord {
        ProbeDebugRecord(source: .app, event: .command, certificate: certificate)
    }

    func testCertificateMetadataRoundTripsOnlyFiveAllowedFields() throws {
        let metadata = certificate()
        let data = try record(metadata).encoded()
        XCTAssertLessThan(data.count, 4096)
        let decoded = try JSONDecoder().decode(ProbeDebugRecord.self, from: data)
        XCTAssertEqual(decoded.certificate?.prepared, true)
        XCTAssertEqual(decoded.certificate?.fingerprintSHA256, metadata.fingerprintSHA256)
        XCTAssertEqual(decoded.certificate?.notAfter, 2000)
        XCTAssertEqual(decoded.certificate?.systemTrusted, false)
        XCTAssertEqual(decoded.certificate?.checkedAt, 1000.5)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let certificateObject = try XCTUnwrap(object["certificate"] as? [String: Any])
        XCTAssertEqual(Set(certificateObject.keys), Set([
            "prepared", "fingerprintSHA256", "notAfter", "systemTrusted", "checkedAt"
        ]))
    }

    func testUnpreparedAndStatusOnlyMetadataOmitAbsentValues() throws {
        for prepared in [false, true] {
            let data = try record(ProbeDebugCertificate(prepared: prepared)).encoded()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let certificate = try XCTUnwrap(object["certificate"] as? [String: Any])
            XCTAssertEqual(Set(certificate.keys), ["prepared"])
            XCTAssertEqual(certificate["prepared"] as? Bool, prepared)
        }
        var status = certificate()
        status.systemTrusted = nil
        status.checkedAt = nil
        XCTAssertNoThrow(try record(status).encoded())
    }

    func testOlderRecordsDecodeWithoutCertificateAndKeepTheirWireShape() throws {
        let old = Data(#"{"version":1,"at":1000,"bundleID":"test.app","source":"app","event":"command","result":"ok"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProbeDebugRecord.self, from: old)
        XCTAssertNil(decoded.certificate)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded.encoded()) as? [String: Any])
        XCTAssertNil(reencoded["certificate"])
        XCTAssertEqual(reencoded["event"] as? String, "command")
    }

    func testEncodingRejectsCertificateOutsideAppCommand() {
        XCTAssertThrowsError(try ProbeDebugRecord(source: .tunnel, event: .command, certificate: certificate()).encoded())
        for event: ProbeDebugRecord.Event in [.ready, .snapshot, .reset, .stopped, .selfTest, .connection] {
            XCTAssertThrowsError(try ProbeDebugRecord(source: .app, event: event, certificate: certificate()).encoded())
        }
    }

    func testEncodingRejectsMalformedFingerprintAndIncompleteTrustPair() throws {
        for value in ["", String(repeating: "A", count: 63), String(repeating: "A", count: 65),
                      String(repeating: "Ｇ", count: 64), String(repeating: "F:", count: 32),
                      String(repeating: "0", count: 63) + "\n", "https://private.example"] {
            var invalid = certificate()
            invalid.fingerprintSHA256 = value
            XCTAssertThrowsError(try record(invalid).encoded())
        }
        var lowercase = certificate()
        lowercase.fingerprintSHA256 = String(repeating: "ab09", count: 16)
        XCTAssertNoThrow(try record(lowercase).encoded())
        var missingTrust = certificate()
        missingTrust.systemTrusted = nil
        XCTAssertThrowsError(try record(missingTrust).encoded())
        var missingTime = certificate()
        missingTime.checkedAt = nil
        XCTAssertThrowsError(try record(missingTime).encoded())
    }

    func testEncodingRejectsUnpreparedExtrasAndInvalidTimestamps() {
        let unprepared: [ProbeDebugCertificate] = [
            .init(prepared: false, fingerprintSHA256: String(repeating: "A", count: 64)),
            .init(prepared: false, notAfter: 1000),
            .init(prepared: false, systemTrusted: false, checkedAt: 1000)
        ]
        for invalid in unprepared { XCTAssertThrowsError(try record(invalid).encoded()) }
        for value in [-1.0, .infinity, .nan] {
            var badExpiry = certificate()
            badExpiry.notAfter = value
            XCTAssertThrowsError(try record(badExpiry).encoded())
            var badCheck = certificate()
            badCheck.checkedAt = value
            XCTAssertThrowsError(try record(badCheck).encoded())
        }
    }

    func testCertificateCodableRejectsInvalidFieldTypes() {
        for json in [#"{"prepared":1}"#, #"{"prepared":"true"}"#,
                     #"{"prepared":true,"fingerprintSHA256":123}"#,
                     #"{"prepared":true,"notAfter":"1000"}"#,
                     #"{"prepared":true,"systemTrusted":1,"checkedAt":1000}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProbeDebugCertificate.self, from: Data(json.utf8)))
        }
    }
}
#endif
