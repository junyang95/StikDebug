import CryptoKit
import Foundation

// Shared verbatim with JITLauncher. This core has no network, clock, VIP state,
// persistent permit, device reader, or configurable production trust anchor.
public enum OfflineDeviceBindingError: Error, Equatable, Sendable {
    case missingCredential
    case invalidCredential
    case invalidSignature
    case unsupportedCredential
    case wrongProduct
    case invalidDeviceIdentifier
    case deviceMismatch
}

public struct OfflineDeviceCredential: Equatable, Sendable {
    public let product: String
    public let udid: String

    fileprivate init(product: String, udid: String) {
        self.product = product
        self.udid = udid
    }

    public func validate(actualUDID: String) throws {
        guard try OfflineDeviceBinding.normalizedUDID(actualUDID) == udid else {
            throw OfflineDeviceBindingError.deviceMismatch
        }
    }
}

public enum OfflineDeviceBinding {
    // Public trust anchor retained from the previously pinned native clients.
    // The corresponding private key stays on the signing server. Never accept
    // an envelope/Info.plist/user-defaults public key as a replacement.
    public static let publicKeyBase64 = "BFBKnwXkljQY3olaB7UmLcaKQWqsQ2EjxBJEXYvEnzbWaHTZrI8OiaaLG+WYbC7FT8SUBLMQs6EAVHfT48+JsdE="
    public static let keyID = "9a6a40f263ac458839e9a4fe6973cee315e10111e1ffd30425788491deefe607"
    static let maximumEnvelopeBytes = 16_384
    static let maximumPayloadBytes = 1_024
    private static let products: Set<String> = ["jit-launcher", "pikmin-helper"]
    private static var trustedPublicKey: Data { Data(base64Encoded: publicKeyBase64)! }

    public static func credential(in bundle: Bundle = .main, expectedProduct: String) throws -> OfflineDeviceCredential {
        try _credential(at: bundle.url(forResource: "wowdevice", withExtension: "plist"),
                        expectedProduct: expectedProduct, trustedPublicKey: trustedPublicKey)
    }

    public static func verify(_ envelopeData: Data, expectedProduct: String) throws -> OfflineDeviceCredential {
        try _verify(envelopeData, expectedProduct: expectedProduct, trustedPublicKey: trustedPublicKey)
    }

    public static func normalizedUDID(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        let valid: Bool
        switch bytes.count {
        case 40:
            valid = bytes.allSatisfy(isHex)
        case 25:
            valid = bytes[8] == 45 && bytes.enumerated().allSatisfy { $0.offset == 8 || isHex($0.element) }
        default:
            valid = false
        }
        guard valid else { throw OfflineDeviceBindingError.invalidDeviceIdentifier }
        return value.lowercased()
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    // Internal dependency injection is for host tests only. Public entry points
    // always use the compiled trust anchor above.
    static func _credential(at url: URL?, expectedProduct: String, trustedPublicKey: Data) throws -> OfflineDeviceCredential {
        guard let url else { throw OfflineDeviceBindingError.missingCredential }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0, size.int64Value <= Int64(maximumEnvelopeBytes) else {
                throw OfflineDeviceBindingError.invalidCredential
            }
            data = try Data(contentsOf: url)
        } catch let error as OfflineDeviceBindingError {
            throw error
        } catch {
            throw OfflineDeviceBindingError.invalidCredential
        }
        return try _verify(data, expectedProduct: expectedProduct, trustedPublicKey: trustedPublicKey)
    }

    static func _verify(_ envelopeData: Data, expectedProduct: String, trustedPublicKey: Data) throws -> OfflineDeviceCredential {
        guard !envelopeData.isEmpty, envelopeData.count <= maximumEnvelopeBytes,
              let envelope = try? PropertyListSerialization.propertyList(from: envelopeData, options: [], format: nil) as? [String: Any],
              Set(envelope.keys) == ["payload", "sig"],
              let payloadBase64 = envelope["payload"] as? String,
              let signatureBase64 = envelope["sig"] as? String,
              let payload = Data(base64Encoded: payloadBase64),
              !payload.isEmpty, payload.count <= maximumPayloadBytes,
              let signature = Data(base64Encoded: signatureBase64),
              !signature.isEmpty, signature.count <= 80 else {
            throw OfflineDeviceBindingError.invalidCredential
        }
        guard let key = try? P256.Signing.PublicKey(x963Representation: trustedPublicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              key.isValidSignature(sig, for: payload) else {
            throw OfflineDeviceBindingError.invalidSignature
        }

        // Parse only the exact signed bytes. Re-serializing JSON before checking
        // the signature would break Java/Swift interoperability.
        guard let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              Set(fields.keys) == ["schema", "purpose", "product", "udid"],
              let version = fields["schema"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: version.objCType)),
              let body = try? JSONDecoder().decode(Payload.self, from: payload) else {
            throw OfflineDeviceBindingError.invalidCredential
        }
        guard body.schema == 1, body.purpose == "wow.offline-device-binding" else {
            throw OfflineDeviceBindingError.unsupportedCredential
        }
        guard products.contains(expectedProduct), body.product == expectedProduct else {
            throw OfflineDeviceBindingError.wrongProduct
        }
        let udid = try normalizedUDID(body.udid)
        guard body.udid == udid else { throw OfflineDeviceBindingError.invalidCredential }
        return OfflineDeviceCredential(product: body.product, udid: udid)
    }

    private struct Payload: Decodable {
        let schema: Int
        let purpose: String
        let product: String
        let udid: String
    }
}
