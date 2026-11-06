import Foundation

struct LauncherJITConfiguration: Sendable {
    let data: Data
    let name: String
    let requiresScript: Bool
}

/// Hardware capability and the application's allocator protocol are separate.
/// Amethyst's iOS 26+ mirrored allocator needs Universal JIT breakpoint service
/// even without TXM. Do not infer this requirement for every universal.js user.
enum LauncherJITCompatibility {
    static func usesAmethystProtocol(_ app: LauncherApplication) -> Bool {
        let identifier = app.bundleIdentifier.lowercased()
        // The remastered build identifies itself as Air. Allow the suffixes
        // added by signing tools, without matching com.air-devs.airplane.
        if identifier == "com.air-devs.air" || identifier.hasPrefix("com.air-devs.air.") ||
            identifier.hasPrefix("com.air-devs.air-") { return true }
        let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["amethyst", "amethyst ios remastered", "amethyst remastered",
                "amethyst ios myremastered", "angelauraamethyst"].contains(name)
    }

    static func requiresScript(_ app: LauncherApplication, osMajorVersion: Int) -> Bool {
        osMajorVersion >= 26 && usesAmethystProtocol(app)
    }
}
