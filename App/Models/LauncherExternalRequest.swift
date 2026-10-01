import Foundation

/// External links request an action; the root view always asks before execution.
enum LauncherExternalRequest: Equatable, Sendable {
    case enableJIT(String), launch(String), terminate(Int32)

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["jitlauncher", "stikpair"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let action = parts.host, let items = parts.queryItems, items.count == 1,
              let value = items[0].value, !value.contains("\0") else { return nil }
        if action == "kill-process", items[0].name == "pid",
           value.utf8.allSatisfy({ (48...57).contains($0) }), let pid = Int32(value), pid > 0 {
            self = .terminate(pid); return
        }
        guard items[0].name == "bundle-id", !value.isEmpty, value.utf8.count <= 255,
              value.contains("."), value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        switch action {
        case "enable-jit": self = .enableJIT(value)
        case "launch-app": self = .launch(value)
        default: return nil
        }
    }

    var target: String {
        switch self {
        case .enableJIT(let value), .launch(let value): return value
        case .terminate(let pid): return "PID \(pid)"
        }
    }
    var actionKey: String {
        switch self {
        case .enableJIT: return "external.jit"
        case .launch: return "external.launch"
        case .terminate: return "external.terminate"
        }
    }
}
