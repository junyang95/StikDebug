// Metadata interpretation adapted from StikDebug Device/IdeviceFFIBridge.swift
// at 4bdfc92 (AGPL-3.0). See ThirdParty/StikDebug for license/provenance.
import Foundation

/// Pure metadata parsing, kept separate from transport/FFI for host-side tests.
enum DeviceMetadata {
    static let maximumProfileSize = 16 * 1024 * 1024

    static func application(_ value: [String: Any]) -> StikJIT.InstalledApplication? {
        guard let identifier = value["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        let candidates = [value["CFBundleDisplayName"] as? String, value["CFBundleName"] as? String, identifier]
        let name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? identifier
        let entitlements = value["Entitlements"] as? [String: Any]
        let debuggable = (entitlements?["get-task-allow"] as? Bool) ?? false
        return .init(bundleIdentifier: identifier, name: name, isDebuggable: debuggable)
    }

    /// Reads the metadata embedded in a provisioning profile, not its signature.
    /// A displayed name/expiry does not imply that the profile is trusted.
    static func profile(_ data: Data) throws -> StikJIT.ProvisioningProfile {
        guard !data.isEmpty, data.count <= maximumProfileSize else { throw failure("Provisioning profile is empty or too large") }
        var plistData = data
        if let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) {
            plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        }
        guard let dictionary = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let id = dictionary["UUID"] as? String, UUID(uuidString: id) != nil else {
            throw failure("Provisioning profile contains no valid UUID")
        }
        let entitlements = dictionary["Entitlements"] as? [String: Any]
        let appIdentifier = (entitlements?["application-identifier"] as? String)
            ?? (entitlements?["com.apple.application-identifier"] as? String) ?? ""
        return .init(id: id, name: dictionary["Name"] as? String ?? id,
                     appIdentifier: appIdentifier, expirationDate: dictionary["ExpirationDate"] as? Date, data: data)
    }

    static func displayValue(_ value: Any) -> String {
        if let data = value as? Data { return "\(data.count) bytes" }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let array = value as? [Any] { return array.map(displayValue).joined(separator: ", ") }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\($0): \(displayValue(dictionary[$0]!))" }.joined(separator: "; ")
        }
        return String(describing: value)
    }

    private static func failure(_ message: String) -> StikJITError { .device(code: -1, subCode: 0, message: message) }
}
