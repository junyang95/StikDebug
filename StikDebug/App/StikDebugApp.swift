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
    @State private var hasStartedDeviceSetup = false
    @State private var setupNavigationRevision = 0
    @State private var startupDecisionMade = false
    @State private var showStartupPairingGuide = false
    @State private var presentedPairingGuideThisLaunch = false
    @State private var isPreparingEnvironment = false
    @State private var environmentGeneration = 0
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
            MainTabView(setupNavigationRevision: setupNavigationRevision)
                .environmentObject(session)
                .environmentObject(preflight)
                .environmentObject(permissions)
                .environmentObject(health)
                .environmentObject(vpn)
                .environmentObject(onDevicePairing)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .environment(\.deviceSetupEnabled, canPrepareEnvironment && !showStartupPairingGuide)
                .environment(\.beginDeviceSetup, beginDeviceSetup)
                // 重建整棵树，让已经渲染出来的文案按新语言重新查表。
                .id(localization.language)
                .sheet(isPresented: $showStartupPairingGuide, onDismiss: {
                    Task { await advanceSetup() }
                }) {
                    OnDevicePairingView()
                        .environmentObject(onDevicePairing)
                        .environmentObject(preflight)
                        .environmentObject(vpn)
                        .environmentObject(localization)
                        .environment(\.locale, localization.locale)
                }
                .onChange(of: onDevicePairing.phase) { _, phase in
                    if phase == .succeeded, canPrepareEnvironment, !showStartupPairingGuide {
                        Task { await advanceSetup() }
                    }
                }
                .onChange(of: vpn.status) { _, status in
                    guard status.isConnected, canPrepareEnvironment, startupDecisionMade,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    Task { await preflight.refresh() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { environmentGeneration += 1 }
                    #if DEBUG
                    if !automaticWorkDisabled {
                        WLOCUSBDebugBridge.shared.setActive(phase == .active && canPrepareEnvironment)
                    }
                    #endif
                    FixedLocationSessionController.shared.updateForegroundState(phase == .active)
                    guard phase == .active, canPrepareEnvironment,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    Task {
                        session.refreshAfterForeground()
                        await advanceSetup()
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    private var canPrepareEnvironment: Bool {
        hasStartedDeviceSetup && !automaticWorkDisabled
    }

    @MainActor
    private func beginDeviceSetup() {
        hasStartedDeviceSetup = true
        setupNavigationRevision += 1
        // UI tests follow the same navigation without starting device or permission work.
        guard !automaticWorkDisabled else { return }
        preflight.setDeviceSetupEnabled(true)
        Task { await advanceSetup() }
    }

    private var automaticWorkDisabled: Bool {
        isTesting || ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    @MainActor
    private func advanceSetup() async {
        guard canPrepareEnvironment, !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
        if !startupDecisionMade {
            startupDecisionMade = true
            let pairingURL = PairingFileStore.prepareURL()
            let hasPairing = PairingFileStore.isValidPairingFile(at: pairingURL)
            if PairingGuidePolicy.shouldPresent(
                isSupported: onDevicePairing.isSupported,
                hasValidPairing: hasPairing,
                presentedThisLaunch: presentedPairingGuideThisLaunch
            ) {
                presentedPairingGuideThisLaunch = true
                showStartupPairingGuide = true
                return
            }
        }
        await prepareEnvironment()
    }

    @MainActor
    private func prepareEnvironment() async {
        guard canPrepareEnvironment, !showStartupPairingGuide,
              !onDevicePairing.isBusy, !isPreparingEnvironment else { return }
        isPreparingEnvironment = true
        let generation = environmentGeneration
        defer {
            isPreparingEnvironment = false
            // A foreground return may arrive while an older preparation is unwinding.
            if generation != environmentGeneration, canPrepareEnvironment, scenePhase == .active {
                Task { await advanceSetup() }
            }
        }
        await vpn.load()
        guard mayContinuePreparation(generation) else { return }
        #if DEBUG
        WLOCUSBDebugBridge.shared.setActive(scenePhase == .active)
        #endif
        if UserDefaults.standard.bool(forKey: "autoConnectEmbeddedVPN"), !vpn.status.isConnected {
            await vpn.connect()
        }
        guard mayContinuePreparation(generation) else { return }
        await permissions.refresh()
        guard mayContinuePreparation(generation) else { return }
        await preflight.refresh()
        guard mayContinuePreparation(generation) else { return }
        await health.refreshToday()
    }

    @MainActor
    private func mayContinuePreparation(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == environmentGeneration && canPrepareEnvironment
            && scenePhase != .background && !showStartupPairingGuide && !onDevicePairing.isBusy
    }
}
