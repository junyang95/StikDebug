import CryptoKit
import Foundation

/// Errors contain only a localizable category, never device identifiers or server data.
enum WowDeviceAccessError: Error, LocalizedError, Equatable, Sendable {
    case banned, notRegistered, serverUnsupported, invalidResponse
    case networkUnavailable, deviceUnavailable, cancelled

    var localizationKey: String {
        switch self {
        case .banned: return "access.error.banned"
        case .notRegistered: return "access.error.not_registered"
        case .serverUnsupported: return "access.error.server_unsupported"
        case .invalidResponse: return "access.error.invalid_response"
        case .networkUnavailable: return "access.error.network_unavailable"
        case .deviceUnavailable: return "access.error.device_unavailable"
        case .cancelled: return "access.error.cancelled"
        }
    }

    var errorDescription: String? {
        NSLocalizedString(localizationKey, tableName: "WowAccess", comment: "")
    }
}

/// Admission is registration plus a fresh authenticated non-ban verdict. VIP
/// membership and VIP expiry are intentionally not admission requirements.
enum WowDeviceAccess {
    static let maximumResponseBytes = 1_048_576
    static let maximumClockSkew: TimeInterval = 300
    static let publicKeyBase64 = "BFBKnwXkljQY3olaB7UmLcaKQWqsQ2EjxBJEXYvEnzbWaHTZrI8OiaaLG+WYbC7FT8SUBLMQs6EAVHfT48+JsdE="
    static var publicKey: Data { Data(base64Encoded: publicKeyBase64)! }

    // An actual UDID must come from the paired device, not a text field or URL.
    // This check bounds header values without requiring one specific hardware era.
    static func validateDeviceIdentifier(_ udid: String) throws {
        guard !udid.isEmpty, udid.utf8.count <= 128,
              udid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 }) else {
            throw WowDeviceAccessError.deviceUnavailable
        }
    }

    static func verifyRegistration(_ data: Data, udid: String) throws {
        try validateDeviceIdentifier(udid)
        let response: Registration = try decode(data)
        switch response.code {
        case 1, 2: throw WowDeviceAccessError.notRegistered
        case 0:
            guard let returned = response.data?.device else { throw WowDeviceAccessError.serverUnsupported }
            guard !returned.isEmpty, returned.caseInsensitiveCompare(udid) == .orderedSame else {
                throw WowDeviceAccessError.invalidResponse
            }
        default: throw WowDeviceAccessError.invalidResponse
        }
    }

    static func verifyLicense(_ data: Data, udid: String, nonce: String,
                              now: Date = Date(), publicKey: Data = publicKey) throws {
        try validateDeviceIdentifier(udid)
        guard !nonce.isEmpty, nonce.utf8.count <= 128 else { throw WowDeviceAccessError.invalidResponse }
        let envelope: Envelope = try decode(data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signatureBytes = Data(base64Encoded: envelope.sig),
              !payload.isEmpty, payload.count <= maximumResponseBytes,
              !signatureBytes.isEmpty, signatureBytes.count <= 80 else {
            throw WowDeviceAccessError.invalidResponse
        }
        do {
            let key = try P256.Signing.PublicKey(x963Representation: publicKey)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureBytes)
            guard key.isValidSignature(signature, for: payload) else { throw WowDeviceAccessError.invalidResponse }
        } catch { throw WowDeviceAccessError.invalidResponse }

        let license: License = try decode(payload)
        guard !license.udid.isEmpty, license.udid.caseInsensitiveCompare(udid) == .orderedSame,
              license.nonce == nonce, license.ts.isFinite, license.ts > 0,
              license.expireAt.isFinite, license.expireAt >= 0,
              now.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince1970 - license.ts / 1000) <= maximumClockSkew else {
            throw WowDeviceAccessError.invalidResponse
        }
        guard ["VALID", "EXPIRED", "UNKNOWN", "BANNED"].contains(license.status) else {
            throw WowDeviceAccessError.serverUnsupported
        }
        guard !license.isBanned, license.status != "BANNED" else { throw WowDeviceAccessError.banned }
        // `UNKNOWN` also covers registered, ordinary devices. Registration must
        // have succeeded separately; never infer it from this signed response.
        // `isVip` and `expireAt` are decoded strictly, but do not grant/deny use.
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumResponseBytes else { throw WowDeviceAccessError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch DecodingError.keyNotFound { throw WowDeviceAccessError.serverUnsupported }
        catch { throw WowDeviceAccessError.invalidResponse }
    }

    private struct Registration: Decodable {
        let code: Int
        let data: RegisteredDevice?
    }
    private struct RegisteredDevice: Decodable { let device: String }
    private struct Envelope: Decodable {
        let payload: String
        let sig: String
        // The response's `pub` is not a trust anchor and is never decoded.
    }
    private struct License: Decodable {
        let udid: String
        let status: String
        let isVip: Bool
        let isBanned: Bool
        let expireAt: Double
        let nonce: String
        let ts: Double
    }
}
