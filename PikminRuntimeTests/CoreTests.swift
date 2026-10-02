import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

struct CoordinateTests {
    @Test func hongKongScreenshotCoordinatesRoundTrip() {
        let map = CLLocationCoordinate2D(latitude: 22.2918, longitude: 114.179)
        let gps = MapCoordinateSystem.gcj02.fromMap(map)
        #expect(gps.latitude > 22.294 && gps.latitude < 22.295)
        #expect(gps.longitude > 114.174 && gps.longitude < 114.175)
        let restored = MapCoordinateSystem.gcj02.toMap(gps)
        #expect(abs(restored.latitude - map.latitude) < 1e-8)
        #expect(abs(restored.longitude - map.longitude) < 1e-8)
    }
    @Test func standardMapKeepsManualGPSExact() {
        let gps = CLLocationCoordinate2D(latitude: 22.2918, longitude: 114.179)
        #expect(MapCoordinateSystem.wgs84.toMap(gps).latitude == gps.latitude)
        #expect(MapCoordinateSystem.wgs84.fromMap(gps).longitude == gps.longitude)
    }
    @Test func shanghaiMatchesKnownTransform() {
        let gps = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let p = MapCoordinateSystem.gcj02.toMap(gps)
        #expect(abs(p.latitude - 31.2284577376) < 1e-7)
        #expect(abs(p.longitude - 121.4782230593) < 1e-7)
    }
    @Test func overseasDestinationsAreUnchanged() {
        for p in [CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
                  CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
                  CLLocationCoordinate2D(latitude: 37.775, longitude: -122.419)] {
            #expect(MapCoordinateSystem.gcj02.toMap(p).latitude == p.latitude)
            #expect(MapCoordinateSystem.gcj02.fromMap(p).longitude == p.longitude)
        }
    }
}

struct LicenseTests {
    let key = P256.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func envelope(status: String = "VALID", vip: Bool = true, banned: Bool = false,
                  udid: String = "device-A", nonce: String = "nonce-A", age: Double = 0,
                  expire: Double = 0, includeFlags: Bool = true) throws -> Data {
        var payload: [String: Any] = ["udid": udid, "status": status, "nonce": nonce,
                                     "ts": (now.timeIntervalSince1970 - age)*1000, "expireAt": expire]
        if includeFlags { payload["isVip"] = vip; payload["isBanned"] = banned }
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        return try JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(),
            "sig": key.signature(for: bytes).derRepresentation.base64EncodedString(), "pub": "untrusted"])
    }
    func verify(_ data: Data, udid: String = "device-A", nonce: String? = "nonce-A") throws -> VipLicense {
        try VipLicenseVerifier.verify(data, udid: udid, nonce: nonce, now: now, publicKey: key.publicKey.x963Representation)
    }
    @Test func acceptsSignedValidDevice() throws {
        #expect(try verify(envelope()).permitsUse(at: now))
    }
    @Test func deniesBanEvenWhenVIPFlagIsTrue() throws {
        #expect(try !verify(envelope(banned: true)).permitsUse(at: now))
        #expect(try !verify(envelope(status: "BANNED")).permitsUse(at: now))
    }
    @Test func deniesNonVIPExpiredAndUnknown() throws {
        #expect(try !verify(envelope(vip: false)).permitsUse(at: now))
        #expect(try !verify(envelope(status: "UNKNOWN")).permitsUse(at: now))
        #expect(try !verify(envelope(expire: now.timeIntervalSince1970*1000)).permitsUse(at: now))
    }
    @Test func rejectsCopiedIdentityAndNonceReplay() throws {
        let raw = try envelope()
        #expect(throws: (any Error).self) { try verify(raw, udid: "device-B") }
        #expect(throws: (any Error).self) { try verify(raw, nonce: "nonce-B") }
    }
    @Test func rejectsReplacementPublicKeyAndTampering() throws {
        let raw = try envelope()
        #expect(throws: (any Error).self) {
            try VipLicenseVerifier.verify(raw, udid: "device-A", nonce: "nonce-A", now: now,
                                          publicKey: P256.Signing.PrivateKey().publicKey.x963Representation)
        }
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: String])
        object["payload"] = Data("{}".utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try verify(tampered) }
    }
    @Test func rejectsOldServerWithoutBanFields() throws {
        let raw = try envelope(includeFlags: false)
        #expect(throws: (any Error).self) { try verify(raw) }
    }
    @Test func offlineGraceIsBoundedBySignedTimeAndExpiry() throws {
        #expect(try verify(envelope(age: 86400), nonce: nil).permitsUse(at: now))
        #expect(try !verify(envelope(age: 3*86400), nonce: nil).permitsUse(at: now))
        #expect(try !verify(envelope(age: -600), nonce: nil).permitsUse(at: now))
        #expect(throws: (any Error).self) { try verify(envelope(age: 600)) }
    }
    @Test func commandGateBindsDeviceAndRevokes() throws {
        let gate = VipLocationGate()
        let license = try verify(envelope())
        #expect(!gate.allows(now: now))
        gate.update(license, now: now)
        #expect(gate.allows(udid: "device-A", now: now))
        #expect(!gate.allows(udid: "device-B", now: now))
        gate.update(nil, now: now)
        #expect(!gate.allows(now: now))
    }
}
