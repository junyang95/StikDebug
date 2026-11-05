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
    @StateObject private var authorization = VipAuthorizationService.shared
    @State private var startupStarted = false
    @State private var startupDecisionMade = false
    @State private var showVIPSetup = false
    @State private var isVIPSheetPresented = false
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
            MainTabView()
                .environmentObject(session)
                .environmentObject(preflight)
                .environmentObject(permissions)
                .environmentObject(health)
                .environmentObject(vpn)
                .environmentObject(onDevicePairing)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .environment(\.deviceSetupEnabled, canPrepareEnvironment && !automaticWorkDisabled
                             && !isVIPSheetPresented && !showStartupPairingGuide)
                .environment(\.beginDeviceSetup, beginDeviceSetup)
                // 重建整棵树，让已经渲染出来的文案按新语言重新查表。
                .id(localization.language)
                .sheet(isPresented: vipSheetPresentation, onDismiss: {
                    isVIPSheetPresented = false
                    if canPrepareEnvironment {
                        Task { await advanceSetup() }
                    } else {
                        authorization.cancelVerification()
                    }
                }) {
                    VipSetupView(authorization: authorization,
                                 restoreLocation: restoreLocationAction,
                                 verify: beginDeviceSetup,
                                 close: dismissVIPSetup)
                        .environment(\.locale, localization.locale)
                }
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
                .task {
                    guard !automaticWorkDisabled, !startupStarted else { return }
                    startupStarted = true
                    // Browsing is passive. Only the explicit setup button starts verification.
                    authorization.restoreCachedAuthorization()
                }
                .onChange(of: canPrepareEnvironment) { _, enabled in
                    if enabled {
                        if isVIPSheetPresented {
                            showVIPSetup = false
                        } else {
                            Task { await advanceSetup() }
                        }
                    } else {
                        environmentGeneration += 1
                        startupDecisionMade = false
                        showStartupPairingGuide = false
                        #if DEBUG
                        if !automaticWorkDisabled { WLOCUSBDebugBridge.shared.setActive(false) }
                        #endif
                    }
                }
                .onChange(of: onDevicePairing.phase) { _, phase in
                    if phase == .succeeded, canPrepareEnvironment, !showStartupPairingGuide {
                        Task { await advanceSetup() }
                    }
                }
                .onChange(of: vpn.status) { _, status in
                    guard status.isConnected, !automaticWorkDisabled, canPrepareEnvironment, startupDecisionMade,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    authorization.connectionDidBecomeAvailable()
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if !automaticWorkDisabled {
                        WLOCUSBDebugBridge.shared.setActive(phase == .active && canPrepareEnvironment)
                    }
                    #endif
                    FixedLocationSessionController.shared.updateForegroundState(phase == .active)
                    guard phase == .active, !automaticWorkDisabled, startupStarted, authorization.hasStartedSetup,
                          !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
                    Task {
                        // Returning from a permission prompt/settings must not lose a retry.
                        authorization.connectionDidBecomeAvailable()
                        await authorization.refresh()
                        guard canPrepareEnvironment else { return }
                        session.refreshAfterForeground()
                        await advanceSetup()
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    private var hasPassedVIPStep: Bool {
        authorization.isSetupVerified || authorization.isAuthorized
    }

    private var canPrepareEnvironment: Bool {
        authorization.hasStartedSetup && hasPassedVIPStep
    }

    /// A swipe dismissal withdraws the request just like the explicit close button.
    /// Programmatic dismissal after verification preserves the completed first step.
    private var vipSheetPresentation: Binding<Bool> {
        Binding(get: { showVIPSetup }, set: { presented in
            if !presented { authorization.cancelVerification() }
            showVIPSetup = presented
        })
    }

    private func dismissVIPSetup() {
        authorization.cancelVerification()
        showVIPSetup = false
    }

    @MainActor
    private func beginDeviceSetup() {
        guard !automaticWorkDisabled else {
            // UI tests exercise presentation without contacting production services.
            isVIPSheetPresented = true
            showVIPSetup = true
            return
        }
        if authorization.isChecking {
            authorization.cancelVerification()
            return
        }
        startupStarted = true
        authorization.startSetup()
        if canPrepareEnvironment {
            Task { await advanceSetup() }
        } else {
            isVIPSheetPresented = true
            showVIPSetup = true
        }
    }

    /// Revocation must not hide the command that clears an existing simulated location.
    /// This explicit recovery action does not start setup or request new permissions.
    private var restoreLocationAction: (() async -> String?)? {
        guard FileManager.default.fileExists(atPath: PairingFileStore.url.path) else { return nil }
        return {
            await session.restoreRealLocation()
            return session.lastError
        }
    }

    private var automaticWorkDisabled: Bool {
        isTesting || ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    @MainActor
    private func advanceSetup() async {
        guard !automaticWorkDisabled, startupStarted, canPrepareEnvironment,
              !isVIPSheetPresented, !showStartupPairingGuide, !onDevicePairing.isBusy else { return }
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
        guard !automaticWorkDisabled, canPrepareEnvironment, !isVIPSheetPresented, !showStartupPairingGuide,
              !onDevicePairing.isBusy, !isPreparingEnvironment else { return }
        isPreparingEnvironment = true
        let generation = environmentGeneration
        defer {
            isPreparingEnvironment = false
            // A renewed grant may have arrived while a previous preparation was suspended.
            if generation != environmentGeneration, canPrepareEnvironment {
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
        if vpn.status.isConnected { authorization.connectionDidBecomeAvailable() }
        await permissions.refresh()
        guard mayContinuePreparation(generation) else { return }
        await preflight.refresh()
        guard mayContinuePreparation(generation) else { return }
        await health.refreshToday()
    }

    @MainActor
    private func mayContinuePreparation(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == environmentGeneration && canPrepareEnvironment
            && !isVIPSheetPresented && !showStartupPairingGuide && !onDevicePairing.isBusy
    }
}
