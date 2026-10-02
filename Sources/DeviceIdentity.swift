import Foundation
@_implementationOnly import idevice

#if !DEVICE_IDENTITY_READER_TESTING
extension StikJIT {
    /// Reads UniqueDeviceID from the connected device's lockdown service and
    /// returns legacy 40-hex IDs in lowercase and modern 8-hex/16-hex IDs in
    /// uppercase, matching the authorization service's identifier format.
    /// The pairing record is
    /// only a connection credential; its own contents are never identity proof.
    /// This operation blocks and must be called off the main thread.
    public static func deviceUDID(pairingFile: URL, configuration: Configuration = .default) throws -> String {
        try DeviceTools.withTunnel(pairingFile, configuration) { tunnel in
            try DeviceTools.withClient("device identity service", connect: {
                lockdownd_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
            }, free: lockdownd_client_free) { client in
                var value: plist_t?
                defer { if let value { plist_free(value) } }
                try IdeviceFFI.check("Failed to read UniqueDeviceID from the connected device") {
                    "UniqueDeviceID".withCString { lockdownd_get_value(client, $0, nil, &value) }
                }
                return try DeviceIdentityReader.udid(from: value)
            }
        }
    }
}
#endif

/// Typed, bounded access avoids serializing unrelated device metadata through
/// Foundation. plist_ffi 0.1.6 returns a borrowed UTF-8 byte pointer and length,
/// not a guaranteed NUL-terminated C string. Only the owning plist is freed.
enum DeviceIdentityReader {
    static func udid(from node: plist_t?) throws -> String {
        guard let node, plist_get_node_type(node) == PLIST_STRING else {
            throw failure("The connected device did not return a string UniqueDeviceID")
        }
        var length: UInt64 = 0
        guard let bytes = plist_get_string_ptr(node, &length), length == 40 || length == 25 else {
            throw failure("The connected device returned an invalid UniqueDeviceID length")
        }
        let data = Data(bytes: bytes, count: Int(length))
        let valid: Bool
        if length == 40 {
            valid = data.allSatisfy(isASCIIHex)
        } else {
            valid = data.enumerated().allSatisfy { index, byte in
                index == 8 ? byte == 0x2D : isASCIIHex(byte)
            }
        }
        guard valid, let text = String(data: data, encoding: .utf8) else {
            throw failure("The connected device returned an invalid UniqueDeviceID format")
        }
        return length == 40 ? text.lowercased() : text.uppercased()
    }

    private static func isASCIIHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func failure(_ message: String) -> StikJITError {
        .device(code: -1, subCode: 0, message: message)
    }
}
