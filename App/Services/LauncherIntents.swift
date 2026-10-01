import AppIntents
import Combine
import Foundation

@MainActor
final class LauncherActionRouter: ObservableObject {
    static let shared = LauncherActionRouter()
    @Published var request: LauncherExternalRequest?
}

struct EnableApplicationJITIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable app JIT"
    static var description = IntentDescription("Open JIT Launcher and confirm a JIT request for an installed app.")
    static var openAppWhenRun = true
    @Parameter(title: "App Bundle ID") var bundleIdentifier: String
    @MainActor func perform() async throws -> some IntentResult {
        var url = URLComponents()
        url.scheme = "jitlauncher"; url.host = "enable-jit"
        url.queryItems = [URLQueryItem(name: "bundle-id", value: bundleIdentifier)]
        guard let value = url.url, let request = LauncherExternalRequest(url: value) else {
            throw IntentError.invalidBundleIdentifier
        }
        LauncherActionRouter.shared.request = request
        return .result()
    }
    enum IntentError: Error { case invalidBundleIdentifier }
}
