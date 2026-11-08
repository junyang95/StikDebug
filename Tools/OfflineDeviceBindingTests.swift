import CryptoKit
import Foundation

@main
enum OfflineDeviceBindingTests {
    static var assertions = 0
    static let udid = "00008110-000a010203040506"
    static let product = "pikmin-helper"
    static let signingKey = P256.Signing.PrivateKey()
    static var testPublicKey: Data { signingKey.publicKey.x963Representation }

    static func main() throws {
        let body: [String: Any] = ["schema": 1, "purpose": "wow.offline-device-binding", "product": product, "udid": udid]
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let valid = try signed(payload)
        let credential = try verify(valid)
        try check(credential.product == product && credential.udid == udid, "valid signed binding")
        try credential.validate(actualUDID: udid.uppercased())
        try check(true, "actual UDID comparison is case insensitive")
        try rejects(.deviceMismatch, "different device") { try credential.validate(actualUDID: "00008110-000a010203040507") }
        try rejects(.invalidDeviceIdentifier, "IDFV is not UDID") { try credential.validate(actualUDID: UUID().uuidString) }
        try rejects(.wrongProduct, "cross product") { _ = try OfflineDeviceBinding._verify(valid, expectedProduct: "jit-launcher", trustedPublicKey: testPublicKey) }
        try rejects(.wrongProduct, "unknown client product") { _ = try OfflineDeviceBinding._verify(valid, expectedProduct: "other", trustedPublicKey: testPublicKey) }

        var changed = body
        changed["udid"] = "00008110-000a010203040507"
        let changedPayload = try JSONSerialization.data(withJSONObject: changed)
        let originalSignature = try signingKey.signature(for: payload).derRepresentation
        try rejects(.invalidSignature, "edited UDID without server key") {
            _ = try verify(envelope(payload: changedPayload, signature: originalSignature))
        }
        let otherKey = P256.Signing.PrivateKey()
        try rejects(.invalidSignature, "attacker signature") {
            _ = try verify(envelope(payload: payload, signature: otherKey.signature(for: payload).derRepresentation))
        }
        try rejects(.invalidCredential, "envelope cannot supply a trust anchor") {
            let dict = ["payload": payload.base64EncodedString(), "sig": originalSignature.base64EncodedString(), "pub": otherKey.publicKey.x963Representation.base64EncodedString()]
            _ = try verify(PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
        }
        try rejects(.invalidSignature, "production verifier rejects test signer") {
            _ = try OfflineDeviceBinding.verify(valid, expectedProduct: product)
        }
        for (field, value, error) in [
            ("schema", 2 as Any, OfflineDeviceBindingError.unsupportedCredential),
            ("schema", true as Any, .invalidCredential),
            ("schema", "1" as Any, .invalidCredential),
            ("purpose", "vip-license" as Any, .unsupportedCredential),
            ("product", "jit-launcher" as Any, .wrongProduct),
            ("udid", udid.uppercased() as Any, .invalidCredential),
            ("udid", "invalid" as Any, .invalidDeviceIdentifier)
        ] {
            var invalid = body
            invalid[field] = value
            try rejects(error, "reject signed invalid \(field) \(value)") { _ = try verify(signed(JSONSerialization.data(withJSONObject: invalid))) }
        }
        for field in body.keys {
            var missing = body
            missing.removeValue(forKey: field)
            try rejects(.invalidCredential, "missing signed field \(field)") { _ = try verify(signed(JSONSerialization.data(withJSONObject: missing))) }
        }
        var extra = body
        extra["isVip"] = true
        try rejects(.invalidCredential, "no VIP payload compatibility") { _ = try verify(signed(JSONSerialization.data(withJSONObject: extra))) }
        for version in ["1.0", "1e0"] {
            let floating = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"schema\":1", with: "\"schema\":\(version)").utf8)
            try rejects(.invalidCredential, "schema must be an integer token") { _ = try verify(signed(floating)) }
        }
        for data in [Data(), Data("plain UDID: \(udid)".utf8), Data(repeating: 65, count: 16_385)] {
            try rejects(.invalidCredential, "invalid or oversized envelope") { _ = try verify(data) }
        }
        for fields: [String: Any] in [[:], ["udid": udid], ["payload": "%%%", "sig": "AQ=="], ["payload": payload, "sig": originalSignature.base64EncodedString()]] {
            try rejects(.invalidCredential, "malformed envelope fields") { _ = try verify(PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)) }
        }
        try rejects(.invalidSignature, "malformed DER") { _ = try verify(envelope(payload: payload, signature: Data([1, 2, 3]))) }
        try rejects(.invalidCredential, "oversized signed payload") { _ = try verify(signed(Data(repeating: 65, count: 1_025))) }
        try rejects(.invalidCredential, "invalid UTF8 JSON") { _ = try verify(signed(Data([255, 0, 1]))) }
        try check(try OfflineDeviceBinding.normalizedUDID("ABCDEF0123456789ABCDEF0123456789ABCDEF01") == "abcdef0123456789abcdef0123456789abcdef01", "legacy UDID shape")
        for invalid in ["", " " + udid, udid + " ", udid.replacingOccurrences(of: "-", with: ""), "00008110-000a01020304050z", "00008110-000a01020304050", "８0008110-000a010203040506", String(repeating: "a", count: 39)] {
            try rejects(.invalidDeviceIdentifier, "invalid UDID format") { _ = try OfflineDeviceBinding.normalizedUDID(invalid) }
        }
        let productionKey = Data(base64Encoded: OfflineDeviceBinding.publicKeyBase64)!
        try check(SHA256.hash(data: productionKey).map { String(format: "%02x", $0) }.joined() == OfflineDeviceBinding.keyID, "production public key fingerprint")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-binding-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wowdevice.plist")
        try valid.write(to: file)
        try check(try OfflineDeviceBinding._credential(at: file, expectedProduct: product, trustedPublicKey: testPublicKey) == credential, "load local credential")
        try rejects(.missingCredential, "missing credential") { _ = try OfflineDeviceBinding._credential(at: nil, expectedProduct: product, trustedPublicKey: testPublicKey) }
        try rejects(.invalidCredential, "missing file is denied") { _ = try OfflineDeviceBinding._credential(at: directory.appendingPathComponent("absent"), expectedProduct: product, trustedPublicKey: testPublicKey) }
        try rejects(.invalidCredential, "directory is denied") { _ = try OfflineDeviceBinding._credential(at: directory, expectedProduct: product, trustedPublicKey: testPublicKey) }
        let link = directory.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try rejects(.invalidCredential, "symlink is denied") { _ = try OfflineDeviceBinding._credential(at: link, expectedProduct: product, trustedPublicKey: testPublicKey) }
        try Data(repeating: 0, count: 16_385).write(to: file)
        try rejects(.invalidCredential, "oversized disk file") { _ = try OfflineDeviceBinding._credential(at: file, expectedProduct: product, trustedPublicKey: testPublicKey) }

        // Optional fixtures are emitted by the backend's Java signing tests.
        if CommandLine.arguments.count == 2 {
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let key = Data(base64Encoded: try String(contentsOf: fixtures.appendingPathComponent("public-key.b64"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            for item in ["jit-launcher", "pikmin-helper"] {
                let data = try Data(contentsOf: fixtures.appendingPathComponent("\(item).plist"))
                let result = try OfflineDeviceBinding._verify(data, expectedProduct: item, trustedPublicKey: key)
                try result.validate(actualUDID: udid)
                try check(true, "Java to Swift \(item)")
                try rejects(.wrongProduct, "Java credential is scoped to product") {
                    _ = try OfflineDeviceBinding._verify(data, expectedProduct: item == "jit-launcher" ? "pikmin-helper" : "jit-launcher", trustedPublicKey: key)
                }
            }
        }
        print("OfflineDeviceBinding: \(assertions) assertions passed")
    }

    static func verify(_ data: Data) throws -> OfflineDeviceCredential {
        try OfflineDeviceBinding._verify(data, expectedProduct: product, trustedPublicKey: testPublicKey)
    }
    static func signed(_ payload: Data) throws -> Data {
        try envelope(payload: payload, signature: signingKey.signature(for: payload).derRepresentation)
    }
    static func envelope(payload: Data, signature: Data) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["payload": payload.base64EncodedString(), "sig": signature.base64EncodedString()], format: .xml, options: 0)
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw NSError(domain: "OfflineDeviceBindingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        assertions += 1
    }
    static func rejects(_ expected: OfflineDeviceBindingError, _ name: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch let error as OfflineDeviceBindingError {
            try check(error == expected, "\(name): expected \(expected), got \(error)")
            return
        }
        throw NSError(domain: "OfflineDeviceBindingTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name): did not reject"])
    }
}
