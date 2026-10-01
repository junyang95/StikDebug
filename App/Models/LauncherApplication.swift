import Foundation

struct LauncherApplication: Identifiable, Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let isDebuggable: Bool
    let iconPNG: Data?

    var id: String { bundleIdentifier }
}
