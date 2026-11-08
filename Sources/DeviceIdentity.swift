import Foundation
@_implementationOnly import idevice

/// Reads only the actual connection target's lockdown UniqueDeviceID. Pairing
/// record contents and the launcher's own local identifiers are not identity proof.
enum DeviceIdentityReader {
    static func udid(over tunnel: DeviceTunnel) throws -> String {
        var client: OpaquePointer?
        defer { if let client { lockdownd_client_free(client) } }
        do {
            try IdeviceFFI.check("Failed to connect to device identity service") {
                lockdownd_connect_rsd(tunnel.adapter, tunnel.handshake, &client)
            }
            guard let client else { throw StikJITError.offlineDeviceBinding(.identityUnavailable) }
            var node: plist_t?
            defer { if let node { plist_free(node) } }
            try IdeviceFFI.check("Failed to read UniqueDeviceID from the connected device") {
                "UniqueDeviceID".withCString { lockdownd_get_value(client, $0, nil, &node) }
            }
            return try udid(from: node)
        } catch let error as StikJITError {
            if case .offlineDeviceBinding = error { throw error }
            throw StikJITError.offlineDeviceBinding(.identityUnavailable)
        }
    }

    /// plist_ffi supplies borrowed UTF-8 bytes and length, not a guaranteed
    /// NUL-terminated C string. Only the owning plist node is freed.
    static func udid(from node: plist_t?) throws -> String {
        guard let node, plist_get_node_type(node) == PLIST_STRING else {
            throw StikJITError.offlineDeviceBinding(.invalidDeviceIdentifier)
        }
        var length: UInt64 = 0
        guard let bytes = plist_get_string_ptr(node, &length), length == 40 || length == 25,
              let text = String(data: Data(bytes: bytes, count: Int(length)), encoding: .utf8) else {
            throw StikJITError.offlineDeviceBinding(.invalidDeviceIdentifier)
        }
        do { return try OfflineDeviceBinding.normalizedUDID(text) }
        catch { throw StikJITError.offlineDeviceBinding(.invalidDeviceIdentifier) }
    }
}
