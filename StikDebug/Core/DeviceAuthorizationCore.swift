import CryptoKit
import Foundation

// Shared verbatim by PikminHelper and JITLauncher. See Tools/check-device-authorization-parity.py.
// Foundation/CryptoKit only: UI, networking, Keychain and device reads belong to adapters.
enum DeviceAuthorizationPolicy: String, Codable, Sendable { case vip, registeredUnbanned }

struct SignedDeviceLicense: Decodable, Equatable {
    let udid: String
    let status: String
    let isVip: Bool
    let isBanned: Bool
    let expireAt: Double
    let nonce: String
    let ts: Double
    var isRegistered: Bool? = nil

    func validUntil(for policy: DeviceAuthorizationPolicy) -> Date {
        let graceEnd = ts / 1000 + 7 * 86400
        let expiry = policy == .vip && expireAt > 0 ? min(expireAt / 1000, graceEnd) : graceEnd
        return Date(timeIntervalSince1970: expiry)
    }

    func permitsUse(policy: DeviceAuthorizationPolicy, at now: Date) -> Bool {
        guard !isBanned, status != "BANNED", ts.isFinite, expireAt.isFinite,
              ts > 0, expireAt >= 0, now.timeIntervalSince1970 >= ts / 1000 - 300,
              now < validUntil(for: policy) else { return false }
        switch policy {
        case .vip: return status == "VALID" && isVip
        case .registeredUnbanned:
            return isRegistered == true && ["VALID", "EXPIRED", "UNKNOWN"].contains(status)
        }
    }

}

enum DeviceAuthorizationVerifier {
    // Public key retrieved over HTTPS from the production license service.
    // Never trust the envelope's `pub` or a replaceable wowvip.plist as a trust anchor.
    static let maximumResponseBytes = 1_048_576
    static let publicKeyBase64 = "BFBKnwXkljQY3olaB7UmLcaKQWqsQ2EjxBJEXYvEnzbWaHTZrI8OiaaLG+WYbC7FT8SUBLMQs6EAVHfT48+JsdE="

    enum Failure: Error { case malformed, signature, identity, nonce, timestamp }
    private struct Envelope: Decodable { let payload: String; let sig: String }

    static func verify(
        _ data: Data, udid: String, nonce: String?, now: Date = Date(),
        publicKey: Data = Data(base64Encoded: publicKeyBase64)!,
        trustFreshServerTime: Bool = false
    ) throws -> SignedDeviceLicense {
        guard !data.isEmpty, data.count <= maximumResponseBytes else { throw Failure.malformed }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.sig), !payload.isEmpty, payload.count <= maximumResponseBytes,
              !signature.isEmpty, signature.count <= 80 else { throw Failure.malformed }
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(sig, for: payload) else { throw Failure.signature }
        let license = try JSONDecoder().decode(SignedDeviceLicense.self, from: payload)
        guard license.ts.isFinite, license.ts > 0, license.expireAt.isFinite, license.expireAt >= 0 else {
            throw Failure.timestamp
        }
        guard !udid.isEmpty, license.udid.caseInsensitiveCompare(udid) == .orderedSame else {
            throw Failure.identity
        }
        if let nonce {
            guard !nonce.isEmpty, license.nonce == nonce else { throw Failure.nonce }
            // A new unpredictable nonce, checked within the request deadline, permits
            // recovery from a wrong device clock. Cached envelopes never use this path.
            guard trustFreshServerTime || abs(now.timeIntervalSince1970 - license.ts / 1000) <= 300 else {
                throw Failure.timestamp
            }
        }
        return license
    }
}


/// Separate from the grant: a durable request barrier survives failed cache deletion
/// and crashes while a server decision is in flight. Missing state requires online migration.
struct DeviceAuthorizationSecurityState: Codable, Equatable {
    var serverAnchor: TimeInterval
    var wallAnchor: TimeInterval
    var trustedHighwater: TimeInterval
    var uptime: TimeInterval
    var bootID: String
    var allowedEnvelopeDigest: String?
    var requiresOnline: Bool

    static func digest(_ envelope: Data) -> String {
        SHA256.hash(data: envelope).map { String(format: "%02x", $0) }.joined()
    }

    static func anchored(serverTime: TimeInterval, wallTime: Date, uptime: TimeInterval,
                         bootID: String, envelope: Data?) -> Self {
        Self(serverAnchor: serverTime, wallAnchor: wallTime.timeIntervalSince1970,
             trustedHighwater: serverTime, uptime: uptime, bootID: bootID,
             allowedEnvelopeDigest: envelope.map(digest), requiresOnline: envelope == nil)
    }

    mutating func observe(wallTime: Date, uptime currentUptime: TimeInterval, bootID currentBoot: String) throws -> Date {
        guard serverAnchor.isFinite, wallAnchor.isFinite, trustedHighwater.isFinite, uptime.isFinite,
              currentUptime.isFinite, serverAnchor > 0, trustedHighwater >= serverAnchor else {
            throw DeviceAuthorizationPersistenceFailure.invalidState
        }
        let floor = trustedHighwater + (bootID == currentBoot ? max(0, currentUptime - uptime) : 0)
        let projected = serverAnchor + wallTime.timeIntervalSince1970 - wallAnchor
        guard projected.isFinite, projected + 120 >= floor else { throw DeviceAuthorizationPersistenceFailure.clockRollback }
        trustedHighwater = max(floor, projected)
        uptime = currentUptime
        bootID = currentBoot
        return Date(timeIntervalSince1970: trustedHighwater)
    }
}

enum DeviceAuthorizationPersistenceFailure: Error { case unavailable, invalidState, clockRollback, onlineRequired }



/// Supplies an automatic UDID candidate for the setup authorization request.
/// Bundle metadata is not proof of this device's identity or of VIP access. Only
/// the UDID is read: keys, URLs, freeMode and other authorization settings are
/// deliberately ignored. A signed server response must still be verified, and
/// the paired device's real UDID must match before opening the command gate.
enum DeviceAuthorizationIdentity {
    static let maximumFileSize = 1_048_576

    static func candidate(bundle: Bundle = .main) -> String? {
        if let data = boundedRead(bundle.url(forResource: "wowvip", withExtension: "plist")),
           let udid = udidFromWowVIPPlist(data) {
            return udid
        }
        guard let data = boundedRead(bundle.url(forResource: "embedded", withExtension: "mobileprovision")) else {
            return nil
        }
        return udidFromMobileProvision(data)
    }

    /// Pure parsing entry point; a valid per-device signing hint takes priority.
    static func candidate(wowVIPPlist: Data?, mobileProvision: Data?) -> String? {
        if let wowVIPPlist, let udid = udidFromWowVIPPlist(wowVIPPlist) { return udid }
        return mobileProvision.flatMap(udidFromMobileProvision)
    }

    static func udidFromWowVIPPlist(_ data: Data) -> String? {
        guard let object = dictionary(from: data), let value = object["udid"] as? String else { return nil }
        return validatedUDID(value)
    }

    /// Extracts the XML plist carried inside a provisioning profile's CMS data.
    /// This does not authenticate the CMS signature. A profile lists devices
    /// allowed to install an app, not necessarily the device currently running it.
    /// Multiple devices (including duplicates) are ambiguous and never guessed.
    static func udidFromMobileProvision(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumFileSize else { return nil }
        let opening = Data("<plist".utf8)
        let closing = Data("</plist>".utf8)
        guard let start = data.range(of: opening),
              let end = data.range(of: closing, in: start.upperBound..<data.endIndex),
              data.range(of: opening, in: start.upperBound..<data.endIndex) == nil,
              data.range(of: closing, in: end.upperBound..<data.endIndex) == nil,
              let object = dictionary(from: Data(data[start.lowerBound..<end.upperBound])),
              let devices = object["ProvisionedDevices"] as? [String], devices.count == 1 else { return nil }
        return validatedUDID(devices[0])
    }

    /// Accepts only Apple's legacy 40-hex and modern 8-hex–16-hex UDID shapes.
    static func validatedUDID(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        let hex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if bytes.count == 40, bytes.allSatisfy(hex) { return value.lowercased() }
        if bytes.count == 25, bytes[8] == 45,
           bytes[..<8].allSatisfy(hex), bytes[9...].allSatisfy(hex) { return value.lowercased() }
        return nil
    }

    private static func dictionary(from data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maximumFileSize else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private static func boundedRead(_ url: URL?) -> Data? {
        guard let url, let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumFileSize + 1),
              !data.isEmpty, data.count <= maximumFileSize else { return nil }
        return data
    }
}
