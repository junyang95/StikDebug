import SwiftData
import SwiftUI

@main
struct StikDebugApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = WalkingSessionController.shared
    @StateObject private var preflight = EnvironmentPreflightService.shared
    @StateObject private var permissions = PermissionChecklistService.shared
    @StateObject private var health = HealthStepService.shared
    @StateObject private var vpn = EmbeddedVPNService.shared
    @StateObject private var localization = LocalizationManager.shared

    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(session)
                .environmentObject(preflight)
                .environmentObject(permissions)
                .environmentObject(health)
                .environmentObject(vpn)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                // 重建整棵树，让已经渲染出来的文案按新语言重新查表。
                .id(localization.language)
                .task {
                    guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
                    await vpn.load()
                    if UserDefaults.standard.bool(forKey: "autoConnectEmbeddedVPN"),
                       !vpn.status.isConnected {
                        await vpn.connect()
                    }
                    try? await DeveloperDiskImageService.shared.downloadMissingFiles()
                    await permissions.refresh()
                    await preflight.refresh()
                    await health.refreshToday()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await vpn.load()
                        await permissions.refresh()
                        await preflight.refresh()
                        await health.refreshToday()
                    }
                }
        }
        .modelContainer(for: WalkingSessionRecord.self)
    }
}
