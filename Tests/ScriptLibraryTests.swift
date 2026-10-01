import Foundation

/// Host tests exercise the production script library, real files, and isolated
/// preferences. They make no claim about script execution or device-side JIT.
@main
@MainActor
enum ScriptLibraryTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw Failure(description: "\(message): operation unexpectedly succeeded")
    }

    static func application(_ name: String, id: String = "example.test") -> LauncherApplication {
        LauncherApplication(bundleIdentifier: id, name: name, isDebuggable: true, iconPNG: nil)
    }

    static func withLibrary(_ body: (ScriptLibrary, URL, URL, UserDefaults, Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptLibraryTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("StoredScripts", isDirectory: true)
        let domain = "com.stik.script-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain),
              CommandLine.arguments.count == 3,
              let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
            throw Failure(description: "Missing isolated preferences or fixture resource bundle")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let library = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
        try expect(library.errorMessage == nil, "Initial storage preparation failed: \(library.errorMessage ?? "")")
        try body(library, root, directory, defaults, bundle)
    }

    static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func write(_ data: Data, named filename: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Bundled app mappings load all four exact resource files", {
                try withLibrary { library, _, _, _, _ in
                    try expect(Set(library.items.map(\.name)) == ["universal.js", "legacy.js", "Geode.js", "maciOS.js"], "Bundled catalog is incomplete")
                    let mappings = [
                        "Amethyst": "universal.js", "MeloNX": "universal.js", "XeniOS": "universal.js",
                        "MeloCafé": "universal.js", "Manic EMU": "universal.js", "DukeX": "universal.js",
                        "TachyonU": "universal.js", "touchHLE": "universal.js", "HyperHLE": "universal.js",
                        "Applesauce": "universal.js", "RPCS3": "universal.js", "AetherPS4": "universal.js",
                        "Geode": "Geode.js", "UTM": "legacy.js", "DolphiniOS": "legacy.js",
                        "Flycast": "legacy.js", "ARMSX2 iOS": "legacy.js", "maciOS": "maciOS.js",
                        "Unknown app": "universal.js"
                    ]
                    let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
                    for (appName, filename) in mappings {
                        let result = try library.scriptData(for: application(appName))
                        try expect(result.name == filename, "Wrong mapping for \(appName): \(result.name)")
                        try expect(result.data == Data(contentsOf: sourceDirectory.appendingPathComponent(filename)), "Bundled bytes changed for \(filename)")
                    }
                }
            }),
            ("Explicit assignment overrides named mappings and default only supplies fallback", {
                try withLibrary { library, _, _, _, _ in
                    library.setDefault("bundled:maciOS.js")
                    let unknown = application("New Emulator", id: "external.identifier")
                    let geode = application("Geode", id: "example.geode")
                    try expect(library.selectedScript(for: unknown).name == "maciOS.js", "External app did not get configured default")
                    try expect(library.selectedScript(for: geode).name == "Geode.js", "Configured default displaced known mapping")
                    library.assign("bundled:legacy.js", to: geode.id)
                    try expect(library.selectedScript(for: geode).name == "legacy.js", "Manual assignment did not win")
                    library.assign(nil, to: geode.id)
                    try expect(library.selectedScript(for: geode).name == "Geode.js", "Reset did not restore automatic mapping")
                    library.setDefault("custom:missing.js")
                    try expect(library.defaultScriptID == "bundled:maciOS.js", "Invalid default was persisted")
                }
            }),
            ("Custom content, default, assignments, favorites and recent history survive reload", {
                try withLibrary { library, _, directory, defaults, bundle in
                    let script = try library.create(name: "  自定义脚本  ")
                    let source = "console.log('繁體與简体');\n"
                    try library.save(script, content: source)
                    library.setDefault(script.id)
                    library.assign(script.id, to: "example.emulator")
                    library.toggleFavorite("example.emulator")
                    library.recordLaunch("example.other")
                    library.recordLaunch("example.emulator")
                    let restored = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
                    try expect(restored.defaultScriptID == script.id, "Default script was not persisted")
                    try expect(restored.assignedScriptID(for: "example.emulator") == script.id, "Assignment was not persisted")
                    try expect(restored.isFavorite("example.emulator"), "Favorite was not persisted")
                    try expect(restored.recentBundleIDs == ["example.emulator", "example.other"], "Launch order was not persisted")
                    try expect(try restored.content(of: script) == source, "Custom UTF-8 source was not preserved")
                    let result = try restored.scriptData(for: application("Geode", id: "example.emulator"))
                    try expect(result.name == "自定义脚本.js" && result.data == Data(source.utf8), "Assigned external filename/source did not reach execution API")
                }
            }),
            ("Import stores a private independent copy and preserves the external file", {
                try withLibrary { library, root, directory, _, _ in
                    let bytes = Data("console.log('original');\n".utf8)
                    let url = try write(bytes, named: "imported.js", in: root)
                    let imported = try library.importScript(from: url)
                    try expect(try Data(contentsOf: url) == bytes, "Import altered external bytes")
                    try expect(try permissions(directory) == 0o700, "Script directory is not owner-only")
                    let stored = directory.appendingPathComponent(imported.name)
                    try expect(try permissions(stored) == 0o600, "Imported file is not owner-only")
                    try Data("changed externally".utf8).write(to: url)
                    try expect(try library.content(of: imported) == String(decoding: bytes, as: UTF8.self), "Stored script aliases its external source")
                    try library.save(imported, content: "console.log('edited');")
                    try expect(try permissions(stored) == 0o600, "Edited file lost private permissions")
                }
            }),
            ("Import rejects malformed UTF-8, binary content, wrong types and oversized files", {
                try withLibrary { library, root, directory, _, _ in
                    let invalid: [(String, Data)] = [
                        ("invalid.js", Data([0xC3, 0x28])),
                        ("binary.js", Data([0x61, 0, 0x62])),
                        ("wrong.txt", Data("console.log('not js');".utf8)),
                        ("oversize.js", Data(repeating: 0x20, count: ScriptLibrary.maximumScriptBytes + 1))
                    ]
                    for (name, data) in invalid {
                        let input = try write(data, named: name, in: root)
                        try expectFailure("Invalid import \(name)") { _ = try library.importScript(from: input) }
                        try expect(try Data(contentsOf: input) == data, "Rejected import mutated external input")
                    }
                    try expect(library.items.count == 4, "Rejected import appeared in catalog")
                    try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Rejected import left a file behind")
                }
            }),
            ("Exact size boundary imports and excessive edits preserve the last saved source", {
                try withLibrary { library, root, _, _, _ in
                    let allowed = Data(repeating: 0x20, count: ScriptLibrary.maximumScriptBytes)
                    let input = try write(allowed, named: "boundary.js", in: root)
                    let script = try library.importScript(from: input)
                    try expect(try library.content(of: script).utf8.count == allowed.count, "Maximum allowed script was truncated")
                    try expectFailure("Oversized edit") {
                        try library.save(script, content: String(repeating: "x", count: ScriptLibrary.maximumScriptBytes + 1))
                    }
                    try expectFailure("Binary edit") { try library.save(script, content: "old\0new") }
                    try expect(try library.content(of: script) == String(decoding: allowed, as: UTF8.self), "Rejected edit replaced valid source")
                }
            }),
            ("Duplicate names cannot overwrite custom scripts or shadow bundled scripts", {
                try withLibrary { library, root, _, _, _ in
                    let script = try library.create(name: "existing")
                    try library.save(script, content: "const saved = true;")
                    let duplicate = try write(Data("replacement".utf8), named: "EXISTING.JS", in: root)
                    try expectFailure("Case-insensitive duplicate") { _ = try library.importScript(from: duplicate) }
                    try expectFailure("Duplicate create") { _ = try library.create(name: "existing.js") }
                    let bundledName = try write(Data("replacement".utf8), named: "Geode.js", in: root)
                    try expectFailure("Bundled filename shadowing") { _ = try library.importScript(from: bundledName) }
                    try expect(try library.content(of: script) == "const saved = true;", "Duplicate import replaced original source")
                }
            }),
            ("Traversal names and symbolic links cannot escape private storage", {
                try withLibrary { library, root, directory, _, _ in
                    for name in ["../escape.js", "folder/file.js", "folder\\file.js", ".hidden.js", "bad\nname.js", "", ".js"] {
                        try expectFailure("Unsafe name \(name)") { _ = try library.create(name: name) }
                    }
                    let outside = try write(Data("outside".utf8), named: "outside.js", in: root)
                    let link = root.appendingPathComponent("linked.js")
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                    try expectFailure("Symlink import") { _ = try library.importScript(from: link) }
                    let script = try library.create(name: "replaceable.js")
                    let stored = directory.appendingPathComponent(script.name)
                    try FileManager.default.removeItem(at: stored)
                    try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: outside)
                    try expectFailure("Symlink edit") { try library.save(script, content: "overwrite") }
                    try expectFailure("Symlink read") { _ = try library.content(of: script) }
                    library.reload()
                    try expect(!library.items.contains(script), "Private symlink appeared in script catalog")
                    try expect(try Data(contentsOf: outside) == Data("outside".utf8), "Symlink operation modified external file")
                }
            }),
            ("Bundled scripts cannot be modified or removed", {
                try withLibrary { library, _, _, _, _ in
                    for script in library.items {
                        let before = try library.content(of: script)
                        try expectFailure("Edit bundled script") { try library.save(script, content: "changed") }
                        try expectFailure("Delete bundled script") { try library.delete(script) }
                        try expect(try library.content(of: script) == before, "Bundled source changed")
                    }
                }
            }),
            ("Deleting a custom script resets references and preserves unrelated favorites", {
                try withLibrary { library, _, directory, defaults, bundle in
                    let script = try library.create(name: "assigned")
                    library.setDefault(script.id)
                    library.assign(script.id, to: "example.geode")
                    library.toggleFavorite("example.geode")
                    library.recordLaunch("example.geode")
                    try library.delete(script)
                    let restored = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
                    try expect(restored.defaultScriptID == "bundled:universal.js", "Deleted default was not reset")
                    try expect(restored.assignedScriptID(for: "example.geode") == nil, "Deleted assignment survived restart")
                    try expect(restored.selectedScript(for: application("Geode", id: "example.geode")).name == "Geode.js", "Automatic mapping was not restored")
                    try expect(restored.isFavorite("example.geode") && restored.recentBundleIDs == ["example.geode"], "Deleting script removed app preferences")
                    try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(script.name).path), "Deleted custom file remains")
                }
            }),
            ("Missing scripts are not silently executed and stale assignments recover", {
                try withLibrary { library, _, directory, defaults, bundle in
                    let script = try library.create(name: "vanishing")
                    library.assign(script.id, to: "example.app")
                    library.setDefault(script.id)
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(script.name))
                    try expectFailure("Missing assigned source") { _ = try library.scriptData(for: application("Unknown", id: "example.app")) }
                    let restored = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
                    try expect(restored.assignedScriptID(for: "example.app") == nil, "Missing assignment persisted after refresh")
                    try expect(restored.defaultScriptID == "bundled:universal.js", "Missing default persisted after refresh")
                }
            }),
            ("Recent history is unique, ordered, bounded and repaired on restoration", {
                try withLibrary { library, _, directory, defaults, bundle in
                    for index in 0..<20 { library.recordLaunch("example.\(index)") }
                    library.recordLaunch("example.15")
                    try expect(library.recentBundleIDs.count == 12, "Recent history limit was not enforced")
                    try expect(library.recentBundleIDs.first == "example.15", "Most recent app was not promoted")
                    try expect(Set(library.recentBundleIDs).count == 12, "Recent list contains duplicate app IDs")
                    defaults.set(["example.a", "example.a", "", "example.b"], forKey: "launcher.apps.recent")
                    let restored = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
                    try expect(restored.recentBundleIDs == ["example.a", "example.b"], "Malformed stored recents were not repaired")
                    library.toggleFavorite("example.favorite")
                    library.toggleFavorite("example.favorite")
                    let unfavorited = ScriptLibrary(defaults: defaults, directory: directory, bundle: bundle)
                    try expect(!unfavorited.isFavorite("example.favorite"), "Removing a favorite was not persisted")
                }
            }),
            ("Custom script count is bounded without damaging the existing library", {
                try withLibrary { library, _, _, _, _ in
                    for index in 0..<100 { _ = try library.create(name: "script-\(index)") }
                    try expectFailure("101st custom script") { _ = try library.create(name: "overflow") }
                    try expect(library.items.filter { !$0.isBundled }.count == 100, "Script count changed after rejected creation")
                }
            })
        ]
        var failures = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) script library tests passed")
        if failures > 0 { exit(1) }
    }
}
