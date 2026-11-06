import CryptoKit
import Foundation

/// Errors contain only a localizable category, never device identifiers or server data.
enum WowDeviceAccessError: Error, LocalizedError, Equatable, Sendable {
    case banned, notRegistered, serverUnsupported, invalidResponse
    case networkUnavailable, deviceUnavailable, cancelled
    case identityMismatch, persistenceUnavailable, clockRollback

    var localizationKey: String {
        switch self {
        case .banned: return "access.error.banned"
        case .notRegistered: return "access.error.not_registered"
        case .serverUnsupported: return "access.error.server_unsupported"
        case .invalidResponse: return "access.error.invalid_response"
        case .networkUnavailable: return "access.error.network_unavailable"
        case .deviceUnavailable: return "access.error.device_unavailable"
        case .cancelled: return "access.error.cancelled"
        case .identityMismatch: return "access.error.identity_mismatch"
        case .persistenceUnavailable: return "access.error.persistence_unavailable"
        case .clockRollback: return "access.error.clock_rollback"
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
    static let publicKeyBase64 = DeviceAuthorizationVerifier.publicKeyBase64
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

    static func verifiedLicense(_ data: Data, udid: String, nonce: String?,
                                now: Date = Date(), publicKey: Data = publicKey) throws -> SignedDeviceLicense {
        try validateDeviceIdentifier(udid)
        if let nonce, nonce.isEmpty || nonce.utf8.count > 128 { throw WowDeviceAccessError.invalidResponse }
        let license: SignedDeviceLicense
        do {
            license = try DeviceAuthorizationVerifier.verify(data, udid: udid, nonce: nonce, now: now,
                publicKey: publicKey, trustFreshServerTime: nonce != nil)
        } catch { throw WowDeviceAccessError.invalidResponse }
        guard !license.isBanned, license.status != "BANNED" else { throw WowDeviceAccessError.banned }
        guard ["VALID", "EXPIRED", "UNKNOWN"].contains(license.status), let registered = license.isRegistered else {
            throw WowDeviceAccessError.serverUnsupported
        }
        guard registered else { throw WowDeviceAccessError.notRegistered }
        return license
    }

    static func verifyLicense(_ data: Data, udid: String, nonce: String,
                              now: Date = Date(), publicKey: Data = publicKey) throws {
        _ = try verifiedLicense(data, udid: udid, nonce: nonce, now: now, publicKey: publicKey)
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
}
