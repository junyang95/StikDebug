import CryptoKit
import Foundation

struct VipLicense: Decodable, Equatable {
    let udid: String
    let status: String
    let isVip: Bool
    let isBanned: Bool
    let expireAt: Double
    let nonce: String
    let ts: Double

    var validUntil: Date {
        let graceEnd = ts / 1000 + 7 * 86400
        return Date(timeIntervalSince1970: expireAt > 0 ? min(expireAt / 1000, graceEnd) : graceEnd)
    }

    func permitsUse(at now: Date) -> Bool {
        status == "VALID" && isVip && !isBanned
            && ts.isFinite && expireAt.isFinite && ts > 0 && expireAt >= 0
            && now.timeIntervalSince1970 >= ts / 1000 - 300
            && now < validUntil
    }
}

enum VipLicenseVerifier {
    // Public key retrieved over HTTPS from the production license service.
    // Never trust the envelope's `pub` or a replaceable wowvip.plist as a trust anchor.
    static let publicKeyBase64 = "BFBKnwXkljQY3olaB7UmLcaKQWqsQ2EjxBJEXYvEnzbWaHTZrI8OiaaLG+WYbC7FT8SUBLMQs6EAVHfT48+JsdE="

    enum Failure: Error { case malformed, signature, identity, nonce, timestamp }
    private struct Envelope: Decodable { let payload: String; let sig: String }

    static func verify(
        _ data: Data, udid: String, nonce: String?, now: Date = Date(),
        publicKey: Data = Data(base64Encoded: publicKeyBase64)!,
        trustFreshServerTime: Bool = false
    ) throws -> VipLicense {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.sig) else { throw Failure.malformed }
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(sig, for: payload) else { throw Failure.signature }
        let license = try JSONDecoder().decode(VipLicense.self, from: payload)
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

/// Enforced by the device command layer, including timer resends. UI is not the gate.
final class VipLocationGate: @unchecked Sendable {
    static let shared = VipLocationGate()
    private let lock = NSLock()
    private var license: VipLicense?
    private var uptimeDeadline: TimeInterval = 0
    private var trustedTime: TimeInterval = 0
    private var observationUptime: TimeInterval = 0
    private var wallOffset: TimeInterval = 0

    func update(_ license: VipLicense?, now: Date = Date(), wallNow: Date? = nil,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        let deadline = uptime + max(0, license?.validUntil.timeIntervalSince(now) ?? 0)
        // Re-reading the same cache cannot refill its remaining monotonic lifetime.
        uptimeDeadline = self.license == license ? min(uptimeDeadline, deadline) : deadline
        self.license = license
        trustedTime = now.timeIntervalSince1970
        observationUptime = uptime
        wallOffset = trustedTime - (wallNow ?? now).timeIntervalSince1970
    }

    func allows(udid: String? = nil, now: Date = Date(),
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let floor = trustedTime + max(0, uptime - observationUptime)
        let projected = now.timeIntervalSince1970 + wallOffset
        guard let license, projected + 120 >= floor,
              license.permitsUse(at: Date(timeIntervalSince1970: max(projected, floor))),
              uptime < uptimeDeadline else { return false }
        return udid.map { license.udid.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }
}
