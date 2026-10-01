import Combine
import Foundation

struct LauncherScript: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isBundled: Bool
}

/// Bundled scripts stay immutable; imports and edits live in protected app storage.
@MainActor
final class ScriptLibrary: ObservableObject {
    static let maximumScriptBytes = 1_048_576
    private static let maximumCustomScripts = 100
    private static let bundledNames = ["universal.js", "legacy.js", "Geode.js", "maciOS.js"]

    @Published private(set) var items: [LauncherScript] = []
    @Published private(set) var defaultScriptID: String
    @Published private(set) var favoriteBundleIDs: Set<String>
    @Published private(set) var recentBundleIDs: [String]
    @Published private(set) var errorMessage: String?
    @Published private var assignments: [String: String]

    private let defaults: UserDefaults
    private let directory: URL
    private let bundle: Bundle

    init(defaults: UserDefaults = .standard, directory: URL? = nil, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JITLauncher/Scripts", isDirectory: true)
        defaultScriptID = defaults.string(forKey: "launcher.scripts.default") ?? "bundled:universal.js"
        favoriteBundleIDs = Set(defaults.stringArray(forKey: "launcher.apps.favorites") ?? [])
        var recent: [String] = []
        for id in defaults.stringArray(forKey: "launcher.apps.recent") ?? [] where !id.isEmpty && !recent.contains(id) {
            recent.append(id)
            if recent.count == 12 { break }
        }
        recentBundleIDs = recent
        assignments = defaults.dictionary(forKey: "launcher.scripts.assignments") as? [String: String] ?? [:]
        reload()
    }

    func reload() {
        items = Self.bundledNames.map { LauncherScript(id: "bundled:\($0)", name: $0, isBundled: true) }
        do {
            try prepareDirectory()
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            let custom = urls.compactMap { url -> LauncherScript? in
                guard Self.validFileName(url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return LauncherScript(id: "custom:\(url.lastPathComponent)", name: url.lastPathComponent, isBundled: false)
            }
            items += custom.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
            if !items.contains(where: { $0.id == defaultScriptID }) {
                defaultScriptID = "bundled:universal.js"
                defaults.set(defaultScriptID, forKey: "launcher.scripts.default")
            }
            let validIDs = Set(items.map(\.id))
            assignments = assignments.filter { validIDs.contains($0.value) }
            defaults.set(assignments, forKey: "launcher.scripts.assignments")
        } catch {
            errorMessage = Self.localized("scripts.error.storage") + "\n" + error.localizedDescription
        }
    }

    func assignedScriptID(for bundleID: String) -> String? { assignments[bundleID] }

    func selectedScript(for app: LauncherApplication) -> LauncherScript {
        if let id = assignments[app.bundleIdentifier], let script = items.first(where: { $0.id == id }) {
            return script
        }
        if let name = Self.automaticName(for: app.name), let script = items.first(where: { $0.id == "bundled:\(name)" }) {
            return script
        }
        return items.first(where: { $0.id == defaultScriptID }) ??
            LauncherScript(id: "bundled:universal.js", name: "universal.js", isBundled: true)
    }

    func scriptData(for app: LauncherApplication) throws -> (data: Data, name: String) {
        let script = selectedScript(for: app)
        let data = try readData(script)
        return (data, script.name)
    }

    func assign(_ scriptID: String?, to bundleID: String) {
        if let scriptID, items.contains(where: { $0.id == scriptID }) {
            assignments[bundleID] = scriptID
        } else {
            assignments.removeValue(forKey: bundleID)
        }
        defaults.set(assignments, forKey: "launcher.scripts.assignments")
    }

    func setDefault(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        defaultScriptID = id
        defaults.set(id, forKey: "launcher.scripts.default")
    }

    func isFavorite(_ bundleID: String) -> Bool { favoriteBundleIDs.contains(bundleID) }
    func toggleFavorite(_ bundleID: String) {
        if favoriteBundleIDs.contains(bundleID) { favoriteBundleIDs.remove(bundleID) }
        else { favoriteBundleIDs.insert(bundleID) }
        defaults.set(favoriteBundleIDs.sorted(), forKey: "launcher.apps.favorites")
    }
    func recordLaunch(_ bundleID: String) {
        recentBundleIDs.removeAll { $0 == bundleID }
        recentBundleIDs.insert(bundleID, at: 0)
        recentBundleIDs = Array(recentBundleIDs.prefix(12))
        defaults.set(recentBundleIDs, forKey: "launcher.apps.recent")
    }

    func content(of script: LauncherScript) throws -> String {
        let data = try readData(script)
        guard let text = String(data: data, encoding: .utf8) else { throw LibraryError.invalidEncoding }
        return text
    }

    func save(_ script: LauncherScript, content: String) throws {
        guard !script.isBundled, items.contains(script) else { throw LibraryError.readOnly }
        let data = Data(content.utf8)
        try validate(data)
        try write(data, named: script.name, replacing: true)
    }

    @discardableResult
    func create(name: String) throws -> LauncherScript {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = trimmed.lowercased().hasSuffix(".js") ? trimmed : trimmed + ".js"
        guard !trimmed.isEmpty, Self.validFileName(filename) else { throw LibraryError.invalidName }
        try write(Data("// JIT script\n".utf8), named: filename, replacing: false)
        reload()
        return LauncherScript(id: "custom:\(filename)", name: filename, isBundled: false)
    }

    @discardableResult
    func importScript(from url: URL) throws -> LauncherScript {
        guard Self.validFileName(url.lastPathComponent) else { throw LibraryError.invalidName }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try boundedData(at: url)
        try write(data, named: url.lastPathComponent, replacing: false)
        reload()
        return LauncherScript(id: "custom:\(url.lastPathComponent)", name: url.lastPathComponent, isBundled: false)
    }

    func delete(_ script: LauncherScript) throws {
        guard !script.isBundled, items.contains(script), Self.validFileName(script.name) else { throw LibraryError.readOnly }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(script.name))
        assignments = assignments.filter { $0.value != script.id }
        defaults.set(assignments, forKey: "launcher.scripts.assignments")
        reload()
    }

    private func readData(_ script: LauncherScript) throws -> Data {
        guard items.contains(script), Self.validFileName(script.name) else { throw LibraryError.missing }
        if script.isBundled {
            let base = String(script.name.dropLast(3))
            guard let url = bundle.url(forResource: base, withExtension: "js", subdirectory: "ScriptResources") ??
                    bundle.url(forResource: base, withExtension: "js") else { throw LibraryError.missing }
            return try boundedData(at: url)
        }
        return try boundedData(at: directory.appendingPathComponent(script.name))
    }

    private func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidName }
        guard let size = values.fileSize, size <= Self.maximumScriptBytes else { throw LibraryError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumScriptBytes + 1) ?? Data()
        try validate(data)
        return data
    }

    private func validate(_ data: Data) throws {
        guard data.count <= Self.maximumScriptBytes else { throw LibraryError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else { throw LibraryError.invalidEncoding }
    }

    private func write(_ data: Data, named name: String, replacing: Bool) throws {
        guard Self.validFileName(name) else { throw LibraryError.invalidName }
        try validate(data)
        try prepareDirectory()
        let output = directory.appendingPathComponent(name)
        if !replacing {
            guard !FileManager.default.fileExists(atPath: output.path),
                  !items.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw LibraryError.alreadyExists
            }
            guard items.filter({ !$0.isBundled }).count < Self.maximumCustomScripts else { throw LibraryError.tooMany }
        } else {
            let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidName }
        }
        try data.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name != ".js" && !name.hasPrefix(".") &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
        !name.contains("\n") && !name.contains("\r") && URL(fileURLWithPath: name).pathExtension.lowercased() == "js"
    }

    private static func automaticName(for appName: String) -> String? {
        switch appName {
        case "Amethyst", "MeloNX", "XeniOS", "MeloCafé", "Manic EMU", "DukeX", "TachyonU", "touchHLE", "HyperHLE", "Applesauce", "RPCS3", "AetherPS4": return "universal.js"
        case "Geode": return "Geode.js"
        case "UTM", "DolphiniOS", "Flycast", "ARMSX2 iOS": return "legacy.js"
        case "maciOS": return "maciOS.js"
        default: return nil
        }
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Library", comment: "")
    }

    private enum LibraryError: String, LocalizedError {
        case invalidName = "scripts.error.name"
        case tooLarge = "scripts.error.size"
        case invalidEncoding = "scripts.error.encoding"
        case readOnly = "scripts.error.read_only"
        case alreadyExists = "scripts.error.exists"
        case tooMany = "scripts.error.count"
        case missing = "scripts.error.missing"

        var errorDescription: String? { NSLocalizedString(rawValue, tableName: "Library", comment: "") }
    }
}
