import SwiftUI

@main
struct JITLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup {
            LauncherRootView(model: model)
        }
    }
}
