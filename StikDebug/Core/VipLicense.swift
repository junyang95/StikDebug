import CryptoKit
import Foundation

struct VipLicense: Decodable {
    let udid: String
    let status: String
    let isVip: Bool
    let isBanned: Bool
    let expireAt: Double
    let nonce: String
    let ts: Double

    var validUntil: Date {
        let graceEnd = ts / 1000 + 3 * 86400
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
        publicKey: Data = Data(base64Encoded: publicKeyBase64)!
    ) throws -> VipLicense {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.sig) else { throw Failure.malformed }
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(sig, for: payload) else { throw Failure.signature }
        let license = try JSONDecoder().decode(VipLicense.self, from: payload)
        guard !udid.isEmpty, license.udid.caseInsensitiveCompare(udid) == .orderedSame else {
            throw Failure.identity
        }
        if let nonce {
            guard !nonce.isEmpty, license.nonce == nonce else { throw Failure.nonce }
            guard abs(now.timeIntervalSince1970 - license.ts / 1000) <= 300 else {
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

    func update(_ license: VipLicense?, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        self.license = license
        uptimeDeadline = ProcessInfo.processInfo.systemUptime + max(0, license?.validUntil.timeIntervalSince(now) ?? 0)
    }

    func allows(udid: String? = nil, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let license, license.permitsUse(at: now),
              ProcessInfo.processInfo.systemUptime < uptimeDeadline else { return false }
        return udid.map { license.udid.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }
}
