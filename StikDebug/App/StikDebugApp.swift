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
    @State private var startupDecisionMade = false
    @State private var showStartupPairingGuide = false
    @State private var presentedPairingGuideThisLaunch = false
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
            MainTabView()
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
                .sheet(isPresented: $showStartupPairingGuide, onDismiss: {
                    Task { await prepareEnvironment() }
                }) {
                    OnDevicePairingView()
                        .environmentObject(onDevicePairing)
                        .environmentObject(preflight)
                        .environmentObject(vpn)
                        .environmentObject(localization)
                        .environment(\.locale, localization.locale)
                }
                .task {
                    guard !isTesting,
                          !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
                    // Restore entitlement locally before VPN, HealthKit or other network work.
                    VipAuthorizationService.shared.restoreCachedAuthorization()
                    let pairingURL = PairingFileStore.prepareURL()
                    let hasPairing = PairingFileStore.isValidPairingFile(at: pairingURL)
                    if PairingGuidePolicy.shouldPresent(
                        isSupported: onDevicePairing.isSupported,
                        hasValidPairing: hasPairing,
                        presentedThisLaunch: presentedPairingGuideThisLaunch
                    ) {
                        presentedPairingGuideThisLaunch = true
                        showStartupPairingGuide = true
                        startupDecisionMade = true
                        return
                    }
                    startupDecisionMade = true
                    await prepareEnvironment()
                }
                .onChange(of: onDevicePairing.phase) { _, phase in
                    if phase == .succeeded, !showStartupPairingGuide {
                        Task { await prepareEnvironment() }
                    }
                }
                .onChange(of: vpn.status) { _, status in
                    guard status.isConnected, !isTesting, startupDecisionMade,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    VipAuthorizationService.shared.connectionDidBecomeAvailable()
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if !isTesting, !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                        WLOCUSBDebugBridge.shared.setActive(phase == .active)
                    }
                    #endif
                    FixedLocationSessionController.shared.updateForegroundState(phase == .active)
                    guard phase == .active, !isTesting, startupDecisionMade,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    Task {
                        // Returning from a permission prompt/settings must not lose a retry.
                        VipAuthorizationService.shared.connectionDidBecomeAvailable()
                        await VipAuthorizationService.shared.refresh()
                    }
                    Task {
                        session.refreshAfterForeground()
                        await prepareEnvironment()
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    @MainActor
    private func prepareEnvironment() async {
        guard !isTesting, !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
        VipAuthorizationService.shared.startMonitoring()
        await vpn.load()
        #if DEBUG
        WLOCUSBDebugBridge.shared.setActive(scenePhase == .active)
        #endif
        if UserDefaults.standard.bool(forKey: "autoConnectEmbeddedVPN"), !vpn.status.isConnected {
            await vpn.connect()
        }
        Task { await VipAuthorizationService.shared.refresh(force: true) }
        await permissions.refresh()
        await preflight.refresh()
        await health.refreshToday()
    }

}
