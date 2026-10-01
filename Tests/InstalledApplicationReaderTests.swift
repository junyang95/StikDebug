import Foundation
@_implementationOnly import idevice

public enum StikJIT {}

@main
enum InstalledApplicationReaderTests {
    static func main() throws {
        var checks = 0
        var roots: [plist_t] = []
        defer { roots.forEach(plist_free) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func string(_ value: String) -> plist_t? { value.withCString(plist_new_string) }
        func set(_ root: plist_t, _ key: String, _ value: plist_t?) {
            key.withCString { plist_dict_set_item(root, $0, value) }
        }
        func app(_ id: String = "org.example.app", _ name: String = "测试 App") -> plist_t {
            let node = plist_new_dict()!
            roots.append(node)
            set(node, "CFBundleIdentifier", string(id))
            set(node, "CFBundleDisplayName", string(name))
            return node
        }
        func entitlement(_ node: plist_t, _ value: plist_t?) {
            let dictionary = plist_new_dict()!
            set(dictionary, "get-task-allow", value)
            set(node, "Entitlements", dictionary)
        }
        func rejects(_ count: Int, entries: [plist_t?], _ message: String) {
            do {
                _ = try InstalledApplicationReader.applications(count: count) { entries[$0] }
                preconditionFailure(message)
            } catch { checks += 1 }
        }

        let normal = app()
        entitlement(normal, plist_new_bool(1))
        let read = InstalledApplicationReader.application(normal)!
        check(read.name == "测试 App" && read.bundleIdentifier == "org.example.app" && read.isDebuggable,
              "Read actual C dictionary fields, UTF-8 name and boolean entitlement")
        // These fields are intentionally irrelevant to an app row. The reader
        // must not serialize/traverse them, regardless of Foundation support.
        set(normal, "UnusedNull", plist_new_null())
        set(normal, "UnusedUID", plist_new_uid(UInt64.max))
        set(normal, "UnusedReal", plist_new_real(.nan))
        check(InstalledApplicationReader.application(normal)?.isDebuggable == true,
              "Unrelated metadata does not affect required fields")

        // Reproduce the old failure at the real C/Foundation boundary: a valid
        // app with an irrelevant deeply nested value serializes successfully,
        // but Foundation rejects the complete property list with Cocoa 3840.
        // This is a regression fixture, not a claim about the user's metadata.
        let deeplyNested = app("org.example.deep", "Deep metadata")
        entitlement(deeplyNested, plist_new_bool(1))
        var nested = plist_new_null()!
        for _ in 0..<512 {
            let parent = plist_new_array()!
            plist_array_append_item(parent, nested)
            nested = parent
        }
        set(deeplyNested, "UnusedMetadata", nested)
        var binary: UnsafeMutablePointer<CChar>?
        var binaryLength: UInt32 = 0
        let conversion = plist_to_bin(deeplyNested, &binary, &binaryLength)
        defer { if let binary { plist_mem_free(binary) } }
        check(conversion == PLIST_ERR_SUCCESS && binary != nil && binaryLength > 0,
              "C library can serialize the valid deep metadata fixture")
        do {
            _ = try PropertyListSerialization.propertyList(from: Data(bytes: binary!, count: Int(binaryLength)), format: nil)
            preconditionFailure("The old Foundation round-trip must reproduce the reported format error")
        } catch {
            check((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 3840,
                  "Old decoding path reproduces Cocoa data-format error")
        }
        let recovered = InstalledApplicationReader.application(deeplyNested)
        check(recovered?.bundleIdentifier == "org.example.deep" && recovered?.isDebuggable == true,
              "Required C fields remain readable despite the old serialization failure")

        let fallback = app("org.example.fallback", " \n ")
        set(fallback, "CFBundleName", string("  備用名稱  "))
        check(InstalledApplicationReader.application(fallback)?.name == "備用名稱", "Trim and use fallback name")
        set(fallback, "CFBundleDisplayName", plist_new_dict())
        check(InstalledApplicationReader.application(fallback)?.name == "備用名稱", "Wrong display-name type falls back")
        set(fallback, "CFBundleName", plist_new_bool(1))
        check(InstalledApplicationReader.application(fallback)?.name == "org.example.fallback", "Wrong names fall back to identifier")
        set(fallback, "CFBundleDisplayName", string(String(repeating: "x", count: 16_385)))
        check(InstalledApplicationReader.application(fallback)?.name == "org.example.fallback", "Bound optional strings")

        let numeric = app("org.example.numeric")
        entitlement(numeric, plist_new_uint(1))
        check(InstalledApplicationReader.application(numeric)?.isDebuggable == true, "Integer one entitlement")
        for value in [plist_new_uint(0), plist_new_uint(2), plist_new_bool(0), string("true"), plist_new_null()] {
            entitlement(numeric, value)
            check(InstalledApplicationReader.application(numeric)?.isDebuggable == false, "Unsupported entitlement cannot grant debugging")
        }
        set(numeric, "Entitlements", string("not a dictionary"))
        check(InstalledApplicationReader.application(numeric)?.isDebuggable == false, "Wrong entitlements container")

        check(InstalledApplicationReader.application(nil) == nil, "Null record")
        let scalar = plist_new_array()!
        roots.append(scalar)
        check(InstalledApplicationReader.application(scalar) == nil, "Non-dictionary record")
        let missing = plist_new_dict()!
        roots.append(missing)
        check(InstalledApplicationReader.application(missing) == nil, "Missing identifier")
        set(missing, "CFBundleIdentifier", plist_new_uint(10))
        check(InstalledApplicationReader.application(missing) == nil, "Wrong identifier type")
        for identifier in ["", "  ", " org.example.test", String(repeating: "a", count: 1025)] {
            check(InstalledApplicationReader.application(app(identifier)) == nil, "Invalid identifier is rejected")
        }

        let entries: [plist_t?] = [nil, scalar, missing, normal, fallback, deeplyNested]
        let result = try InstalledApplicationReader.applications(count: entries.count) { entries[$0] }
        check(Set(result.map(\.bundleIdentifier)) == ["org.example.app", "org.example.fallback", "org.example.deep"], "Bad records cannot abort valid application rows")
        let repeated: [plist_t?] = [normal, normal]
        let unique = try InstalledApplicationReader.applications(count: repeated.count) { repeated[$0] }
        check(unique.count == 1, "Duplicate application identifiers are coalesced")
        let empty = try InstalledApplicationReader.applications(count: 0) { _ in preconditionFailure() }
        check(empty.isEmpty, "An empty database remains a valid empty list")
        rejects(3, entries: [nil, missing, scalar], "An entirely invalid reply must not report success")
        rejects(-1, entries: [], "Reject negative count before dereferencing")
        rejects(100_001, entries: [], "Reject excessive count before dereferencing")
        print("\(checks) installed application reader tests passed")
    }
}
