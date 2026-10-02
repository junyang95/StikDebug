import Foundation
@_implementationOnly import idevice

@main
enum DeviceIdentityTests {
    static func main() throws {
        var checks = 0
        func accepts(_ source: String, _ expected: String) throws {
            let node = source.withCString { plist_new_string($0) }!
            defer { plist_free(node) }
            let actual = try DeviceIdentityReader.udid(from: node)
            precondition(actual == expected, "Unexpected UDID normalization")
            // Reading repeatedly must not consume the borrowed string or owner.
            let repeated = try DeviceIdentityReader.udid(from: node)
            precondition(repeated == expected)
            checks += 1
        }
        func rejects(_ node: plist_t?, _ description: String) {
            do { _ = try DeviceIdentityReader.udid(from: node); preconditionFailure(description) }
            catch { checks += 1 }
        }
        func rejectsString(_ text: String) {
            let node = text.withCString { plist_new_string($0) }!
            defer { plist_free(node) }
            rejects(node, "Invalid UDID was accepted")
        }
        let legacy = "0123456789abcdef0123456789abcdef01234567"
        try accepts(legacy, legacy)
        try accepts(legacy.uppercased(), legacy)
        try accepts("00008110-000e35e026a2801e", "00008110-000E35E026A2801E")
        try accepts("aBcD1234-aBcD1234aBcD1234", "ABCD1234-ABCD1234ABCD1234")
        for invalid in ["", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
                        "00008110000E35E026A2801E", "0000811-0000E35E026A2801E",
                        "000081100-00E35E026A2801E", "00008110_000E35E026A2801E",
                        "00008110-000E35E026A2801G", "00008110-000E35E026A2801 ",
                        " " + legacy, legacy + "\n", "00008110-000E35E026A2801é",
                        String(repeating: "Ａ", count: 40), "00008110-000E35E0-6A2801E"] {
            rejectsString(invalid)
        }
        rejects(nil, "Missing value must not authorize")
        let numeric = plist_new_uint(1234)!
        rejects(numeric, "Numeric identity must not authorize")
        plist_free(numeric)
        let boolean = plist_new_bool(1)!
        rejects(boolean, "Boolean identity must not authorize")
        plist_free(boolean)
        let dictionary = plist_new_dict()!
        // A record claiming an identity must not be treated as a lockdown value.
        legacy.withCString { plist_dict_set_item(dictionary, "UniqueDeviceID", plist_new_string($0)) }
        rejects(dictionary, "Claimed dictionary identity is not a service response")
        plist_free(dictionary)
        let array = plist_new_array()!
        rejects(array, "Array identity must not authorize")
        plist_free(array)
        print("\(checks) device identity tests passed")
    }
}
