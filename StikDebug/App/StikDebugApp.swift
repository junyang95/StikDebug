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
    @StateObject private var onDevicePairing = OnDevicePairingService.shared
    @StateObject private var localization = LocalizationManager.shared
    @AppStorage(SetupGate.completedKey) private var setupCompleted = false
    @AppStorage(SetupGate.forceShowKey) private var forceShowSetup = false
    private let isTesting: Bool
    private let modelContainer: ModelContainer

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        isTesting = testing
        modelContainer = try! ModelContainer(
            for: WalkingSessionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: testing)
        )
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if shouldPresentSetup {
                    FirstRunSetupView {
                        SetupGate.markComplete()
                        setupCompleted = true
                        forceShowSetup = false
                    }
                } else {
                    MainTabView()
                }
            }
                .environmentObject(session)
                .environmentObject(preflight)
                .environmentObject(permissions)
                .environmentObject(health)
                .environmentObject(vpn)
                .environmentObject(onDevicePairing)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                // 重建整棵树，让已经渲染出来的文案按新语言重新查表。
                .id(localization.language)
                .task {
                    guard !isTesting,
                          !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
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
        .modelContainer(modelContainer)
    }

    private var shouldPresentSetup: Bool {
        let pairingFileExists = FileManager.default.fileExists(
            atPath: PairingFileStore.prepareURL().path
        )
        return SetupGate.shouldPresent(
            completed: setupCompleted,
            forceShow: forceShowSetup,
            pairingFileExists: pairingFileExists
        )
    }
}
