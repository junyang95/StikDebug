import Foundation

// Supply only the namespace; the production models and parsers compile unchanged.
public enum StikJIT {}

@main
enum DeviceMetadataTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            count += 1
        }
        func rejects(_ data: Data, _ name: String) {
            do { _ = try DeviceMetadata.profile(data); preconditionFailure(name) }
            catch { count += 1 }
        }
        check(DeviceMetadata.application(["CFBundleName": "Missing ID"]) == nil, "Missing identifiers are excluded")
        let app = DeviceMetadata.application([
            "CFBundleIdentifier": "org.example.test", "CFBundleDisplayName": "  测试  ",
            "Entitlements": ["get-task-allow": true]
        ])!
        check(app.name == "测试" && app.isDebuggable, "Display name and real debug entitlement")
        let noEntitlement = DeviceMetadata.application(["CFBundleIdentifier": "org.example.debuggable", "CFBundleName": "JIT App"])!
        check(!noEntitlement.isDebuggable, "Names never imply debugger permission")
        let stringEntitlement = DeviceMetadata.application(["CFBundleIdentifier": "x", "Entitlements": ["get-task-allow": "true"]])!
        check(!stringEntitlement.isDebuggable, "Text is not a Boolean entitlement")
        let fallback = DeviceMetadata.application(["CFBundleIdentifier": "org.example.app", "CFBundleDisplayName": " ", "CFBundleName": "Fallback"])!
        check(fallback.name == "Fallback", "Blank display names fall back")
        let id = "019D5B47-7EC0-49D2-B245-939A25AE9D3E"
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata: [String: Any] = ["UUID": id, "Name": "Test profile", "ExpirationDate": expiry,
                                       "Entitlements": ["application-identifier": "TEAM.org.example.app"]]
        let xml = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        let wrapped = Data([0x30, 0x82, 0x0, 0xff]) + xml + Data([0x00, 0xfe, 0xff])
        let parsed = try DeviceMetadata.profile(wrapped)
        check(parsed.id == id && parsed.appIdentifier == "TEAM.org.example.app", "Extract metadata inside CMS envelope")
        check(parsed.expirationDate == expiry && parsed.data == wrapped, "Preserve signed bytes and expiration")
        let binary = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        let binaryProfile = try DeviceMetadata.profile(binary)
        check(binaryProfile.id == id, "Plain binary plist supported")
        rejects(Data(), "Reject empty input")
        rejects(Data(repeating: 0, count: DeviceMetadata.maximumProfileSize + 1), "Reject oversized input")
        rejects(try PropertyListSerialization.data(fromPropertyList: ["UUID": "../bad"], format: .xml, options: 0), "Reject invalid profile ID")
        rejects(Data("garbage <?xml broken </plist>".utf8), "Reject malformed metadata")
        check(DeviceMetadata.displayValue(Data([1, 2, 3])) == "3 bytes", "Raw device blobs are summarized")
        print("\(count) device metadata tests passed")
    }
}
