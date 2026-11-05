import Foundation

/// Supplies an automatic UDID candidate for the setup authorization request.
/// Bundle metadata is not proof of this device's identity or of VIP access. Only
/// the UDID is read: keys, URLs, freeMode and other authorization settings are
/// deliberately ignored. A signed server response must still be verified, and
/// the paired device's real UDID must match before opening the command gate.
enum VipSetupIdentity {
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
