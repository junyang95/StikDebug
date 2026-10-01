import Foundation
@_implementationOnly import idevice

/// Read only the fields the application list needs. Installation-proxy records
/// also contain unrelated device metadata that may not round-trip through
/// Foundation's binary property-list decoder. One such field must not prevent
/// otherwise valid applications from appearing in the list.
enum InstalledApplicationReader {
    static func applications(count: Int, entry: (Int) -> plist_t?) throws -> [StikJIT.InstalledApplication] {
        guard (0...100_000).contains(count) else {
            throw failure("The device returned an invalid application count")
        }
        var applications: [String: StikJIT.InstalledApplication] = [:]
        for index in 0..<count {
            guard let app = application(entry(index)) else { continue }
            applications[app.bundleIdentifier] = app
        }
        // An empty database is valid. A nonempty but entirely unreadable reply
        // is a failure, not a successful refresh with zero installed apps.
        guard count == 0 || !applications.isEmpty else {
            throw failure("The device returned \(count) application records, but none contained a readable application identifier")
        }
        return applications.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }

    static func application(_ node: plist_t?) -> StikJIT.InstalledApplication? {
        guard let node, plist_get_node_type(node) == PLIST_DICT,
              let identifier = string(item(node, "CFBundleIdentifier"), maximumBytes: 1024),
              !identifier.isEmpty,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var fields: [String: Any] = ["CFBundleIdentifier": identifier]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = string(item(node, key), maximumBytes: 16_384) { fields[key] = value }
        }
        if let entitlements = item(node, "Entitlements"), plist_get_node_type(entitlements) == PLIST_DICT {
            fields["Entitlements"] = ["get-task-allow": boolean(item(entitlements, "get-task-allow"))]
        }
        return DeviceMetadata.application(fields)
    }

    private static func item(_ dictionary: plist_t, _ key: String) -> plist_t? {
        key.withCString { plist_dict_get_item(dictionary, $0) }
    }

    private static func string(_ node: plist_t?, maximumBytes: UInt64) -> String? {
        guard let node, plist_get_node_type(node) == PLIST_STRING else { return nil }
        var length: UInt64 = 0
        guard let bytes = plist_get_string_ptr(node, &length), length <= maximumBytes else { return nil }
        // Copy while the parent record is alive; never keep a borrowed C pointer.
        guard let value = String(data: Data(bytes: bytes, count: Int(length)), encoding: .utf8),
              !value.contains("\0") else { return nil }
        return value
    }

    private static func boolean(_ node: plist_t?) -> Bool {
        guard let node else { return false }
        switch plist_get_node_type(node) {
        case PLIST_BOOLEAN:
            var value: UInt8 = 0
            plist_get_bool_val(node, &value)
            return value != 0
        case PLIST_INT:
            var value: UInt64 = 0
            plist_get_uint_val(node, &value)
            return value == 1
        default:
            // Missing, malformed and textual entitlements never grant debugging.
            return false
        }
    }

    private static func failure(_ message: String) -> StikJITError {
        .device(code: -1, subCode: 0, message: message)
    }
}
