import Combine
import Foundation
import NetworkExtension
import UIKit
#if !targetEnvironment(simulator)
import StikJIT
#endif

struct LauncherProcess: Identifiable, Sendable {
    let id: Int32
    let name: String
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var developerModeConfirmed = false {
        didSet {
            defaults.set(developerModeConfirmed, forKey: "developerModeConfirmed")
            if !developerModeConfirmed { invalidatePreparation() }
        }
    }
    @Published private(set) var pairingFileName: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isPrepared = false
    @Published private(set) var progressKey = "progress.idle"
    @Published private(set) var progressFraction: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?
    @Published private(set) var processes: [LauncherProcess] = []
    @Published var targetPID = ""

    @Published private(set) var applications: [LauncherApplication] = []
    @Published private(set) var applicationError: String?
    @Published private(set) var deviceDetails: [String: String] = [:]
    @Published private(set) var profiles: [LauncherProfile] = []
    @Published private(set) var operationLog: [String] = []
    @Published private(set) var locationIsSimulated = false
    let scripts = ScriptLibrary()
    let console = LauncherConsole()

    let vpn = LocalVPNManager()
    let pairing = OnDevicePairingManager()
    private let defaults: UserDefaults
    private let store: PairingRecordStore
    private let cacheDirectory: URL
    private let worker = DispatchQueue(label: "com.stik.JITLauncher.device", qos: .userInitiated)
    private var observation: AnyCancellable?
    private var preparationGeneration = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var operationExpired = false
    private var operationID: UUID?
    private var requestedApplication: (String, Bool)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JITLauncher", isDirectory: true)
        store = PairingRecordStore(directory: library.appendingPathComponent("Pairing", isDirectory: true))
        cacheDirectory = library.appendingPathComponent("DeviceSupport", isDirectory: true)
        developerModeConfirmed = defaults.bool(forKey: "developerModeConfirmed")
        locationIsSimulated = defaults.bool(forKey: "locationIsSimulated")
        pairingFileName = store.hasRecord ? (defaults.string(forKey: "pairingFileName") ?? "pairing.plist") : nil
        observation = vpn.$status.removeDuplicates().sink { [weak self] status in
            guard status != .connected else { return }
            self?.invalidatePreparation()
        }
        pairing.canStart = { [weak self] in
            guard let self else { return false }
            return !self.isBusy && !self.vpn.isBusy && !self.console.isRunning && !self.locationIsSimulated
        }
        pairing.didComplete = { [weak self] url, hostAltIRK in
            guard let self else { return }
            try self.store.importRecord(from: url, hostAltIRK: hostAltIRK) { record in
                #if !targetEnvironment(simulator)
                try StikJIT.validatePairingFile(at: record)
                #endif
            }
            self.defaults.set("pairing.plist", forKey: "pairingFileName")
            self.pairingFileName = "pairing.plist"
            self.developerModeConfirmed = true
            self.invalidatePreparation()
            self.successMessage = self.localized("pairing.on_device.complete")
        }
    }

    func refreshState() async {
        if !store.hasRecord {
            pairingFileName = nil
            invalidatePreparation()
        }
        await vpn.refresh()
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
        applicationError = nil
    }

    func importPairingFile(from url: URL) {
        guard !locationIsSimulated else { errorMessage = localized("error.restore_location_first"); return }
        guard !isBusy, !pairing.isRunning, !console.isRunning else { return }
        clearMessages()
        do {
            try store.importRecord(from: url) { record in
                #if targetEnvironment(simulator)
                // A preview must not claim that a record was validated by the device-only FFI.
                throw LauncherOperationError.deviceRequired
                #else
                try StikJIT.validatePairingFile(at: record)
                #endif
            }
            pairingFileName = url.lastPathComponent
            defaults.set(url.lastPathComponent, forKey: "pairingFileName")
            invalidatePreparation()
            successMessage = localized("success.pairing_imported")
        } catch PairingRecordStore.StoreError.tooLarge {
            errorMessage = localized("error.pairing_too_large")
        } catch PairingRecordStore.StoreError.invalidPropertyList {
            errorMessage = localized("error.invalid_pairing")
        } catch LauncherOperationError.deviceRequired {
            errorMessage = localized("error.device_required")
        } catch {
            errorMessage = message("error.invalid_pairing", error)
        }
    }

    func removePairingFile() {
        guard !locationIsSimulated else { errorMessage = localized("error.restore_location_first"); return }
        guard !isBusy, !pairing.isRunning, !console.isRunning else { return }
        clearMessages()
        do {
            try store.removeRecord()
            defaults.removeObject(forKey: "pairingFileName")
            pairingFileName = nil
            invalidatePreparation()
        } catch { errorMessage = message("error.storage", error) }
    }

    func prepareDevice() {
        guard preflight() else { return }
        isPrepared = false
        let record = store.fileURL
        let cache = cacheDirectory
        perform(progress: "progress.checking_device", failure: "error.preparation_failed") { report in
            try LauncherEngine.prepare(record: record, cache: cache, report: report)
            return .prepared
        }
    }

    func refreshProcesses() {
        guard preflight(requirePreparation: true) else { return }
        let record = store.fileURL
        let ownPID = ProcessInfo.processInfo.processIdentifier
        perform(progress: "progress.loading_processes", failure: "error.processes_failed") { _ in
            .processes(try LauncherEngine.processes(record: record).filter { $0.id != ownPID })
        }
    }

    func enableJIT() {
        guard preflight(requirePreparation: true) else { return }
        let pid: Int32
        do {
            pid = try TargetPIDValidator.validate(targetPID, ownPID: ProcessInfo.processInfo.processIdentifier)
        } catch TargetPIDValidator.ValidationError.ownProcess {
            errorMessage = localized("error.self_pid")
            return
        } catch {
            errorMessage = localized("error.invalid_pid")
            return
        }
        let data: Data
        do {
            let app = LauncherApplication(bundleIdentifier: "manual.pid", name: "", isDebuggable: true, iconPNG: nil)
            data = try scripts.scriptData(for: app).data
        } catch { errorMessage = error.localizedDescription; return }
        let record = store.fileURL
        let cache = cacheDirectory
        perform(progress: "progress.enabling_jit", failure: "error.jit_failed") { report in
            try LauncherEngine.enable(pid: pid, record: record, cache: cache, script: data, report: report)
            return .enabled
        }
    }

    func executeExternal(_ request: LauncherExternalRequest) {
        guard !isBusy, !pairing.isRunning else {
            errorMessage = localized("error.operation_busy")
            return
        }
        guard preflight(requirePreparation: true) else { return }
        switch request {
        case .enableJIT(let bundleID), .launch(let bundleID):
            let enable = { if case .enableJIT = request { return true }; return false }()
            requestedApplication = (bundleID, enable)
            refreshApplications()
        case .terminate(let pid):
            terminateProcess(LauncherProcess(id: pid, name: "PID \(pid)"))
        }
    }

    func refreshApplications() {
        guard preflight() else { return }
        let record = store.fileURL
        let ownBundle = Bundle.main.bundleIdentifier
        perform(progress: "progress.loading_apps", failure: "error.apps_failed") { _ in
            .applications(try LauncherEngine.applications(record: record).filter { $0.bundleIdentifier != ownBundle })
        }
    }

    func launchApplication(_ app: LauncherApplication, enableJIT: Bool) {
        guard preflight(requirePreparation: true) else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            errorMessage = localized("error.self_pid"); return
        }
        if enableJIT && !app.isDebuggable {
            errorMessage = localized("error.app_not_debuggable"); return
        }
        let script: Data?
        do { script = enableJIT ? try scripts.scriptData(for: app).data : nil }
        catch { errorMessage = error.localizedDescription; return }
        let record = store.fileURL
        let cache = cacheDirectory
        perform(progress: enableJIT ? "progress.enabling_jit" : "progress.launching_app", failure: "error.launch_failed") { report in
            let pid = try LauncherEngine.launch(app.bundleIdentifier, record: record, suspended: enableJIT)
            if let script {
                do { try LauncherEngine.enable(pid: pid, record: record, cache: cache, script: script, report: report) }
                catch {
                    // A failed script must not leave a newly suspended target unusable.
                    try? LauncherEngine.resume(pid, record: record)
                    throw error
                }
            }
            return .launched(app.bundleIdentifier, pid, enableJIT)
        }
    }

    func refreshDeviceDetails() {
        guard preflight() else { return }
        let record = store.fileURL
        perform(progress: "progress.device_details", failure: "error.tool_failed") { _ in
            .details(try LauncherEngine.details(record: record))
        }
    }

    func refreshProfiles() {
        guard preflight() else { return }
        let record = store.fileURL
        perform(progress: "progress.profiles", failure: "error.tool_failed") { _ in
            .profiles(try LauncherEngine.profiles(record: record))
        }
    }

    func importProfile(from url: URL) {
        guard preflight() else { return }
        let data: Data
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            data = try Data(contentsOf: url)
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        } catch { errorMessage = error.localizedDescription; return }
        let record = store.fileURL
        perform(progress: "progress.profiles", failure: "error.tool_failed") { _ in
            try LauncherEngine.installProfile(data, record: record)
            return .profiles(try LauncherEngine.profiles(record: record))
        }
    }

    func removeProfile(_ profile: LauncherProfile) {
        guard preflight() else { return }
        let record = store.fileURL
        perform(progress: "progress.profiles", failure: "error.tool_failed") { _ in
            try LauncherEngine.removeProfile(profile.id, record: record)
            return .profiles(try LauncherEngine.profiles(record: record))
        }
    }

    func terminateProcess(_ process: LauncherProcess) {
        guard preflight(requirePreparation: true) else { return }
        guard process.id > 0, process.id != ProcessInfo.processInfo.processIdentifier else {
            errorMessage = localized("error.self_pid"); return
        }
        let record = store.fileURL
        let ownPID = ProcessInfo.processInfo.processIdentifier
        perform(progress: "progress.process_control", failure: "error.tool_failed") { _ in
            try LauncherEngine.terminate(process.id, record: record)
            return .processes(try LauncherEngine.processes(record: record).filter { $0.id != ownPID })
        }
    }

    func simulateLocation(latitude: String, longitude: String) {
        guard preflight() else { return }
        guard let point = LauncherInput.coordinate(latitude, longitude) else {
            errorMessage = localized("error.coordinates"); return
        }
        let record = store.fileURL
        // The service can apply location before a timeout is observed. Preserve
        // restoration credentials even when its acknowledgement is lost.
        locationIsSimulated = true
        defaults.set(true, forKey: "locationIsSimulated")
        perform(progress: "progress.location", failure: "error.tool_failed") { _ in
            try LauncherEngine.setLocation(point.0, point.1, record: record)
            return .location(true)
        }
    }

    func restoreLocation() {
        guard preflight() else { return }
        let record = store.fileURL
        perform(progress: "progress.location", failure: "error.tool_failed") { _ in
            try LauncherEngine.clearLocation(record: record)
            return .location(false)
        }
    }

    func startConsole() {
        guard preflight() else { return }
        console.start(pairingFile: store.fileURL)
    }

    func clearOperationLog() { operationLog.removeAll() }
    private func appendLog(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        operationLog.append("[\(time)] " + String(text.prefix(4096)))
        if operationLog.count > 500 { operationLog.removeFirst(operationLog.count - 500) }
    }

    private func preflight(requirePreparation: Bool = false) -> Bool {
        guard !isBusy, !pairing.isRunning else { return false }
        clearMessages()
        #if targetEnvironment(simulator)
        errorMessage = localized("error.device_required")
        return false
        #else
        guard developerModeConfirmed else {
            errorMessage = localized("error.developer_mode")
            return false
        }
        guard store.hasRecord else {
            errorMessage = localized("error.pairing_required")
            return false
        }
        guard vpn.isConnected else {
            errorMessage = localized("error.vpn_required")
            return false
        }
        guard !requirePreparation || isPrepared else {
            errorMessage = localized("error.prepare_required")
            return false
        }
        return true
        #endif
    }

    private func invalidatePreparation() {
        preparationGeneration += 1
        isPrepared = false
        processes = []
        deviceDetails = [:]
        profiles = []
        console.stop()
        requestedApplication = nil
        targetPID = ""
        successMessage = nil
        if !isBusy { progressKey = "progress.idle" }
    }

    private func perform(progress: String, failure: String,
                         work: @escaping (@escaping LauncherEngine.Report) throws -> LauncherResult) {
        isBusy = true
        progressKey = progress
        progressFraction = nil
        operationExpired = false
        appendLog(localized(progress))
        let generation = preparationGeneration
        let operation = UUID()
        operationID = operation
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JIT operation") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.operationID == operation else { return }
                self.operationExpired = true
                self.invalidatePreparation()
                self.errorMessage = self.localized("error.background_expired")
                self.endBackgroundTask()
                // The FFI is blocking. Keep isBusy until it returns to prevent overlapping sessions.
            }
        }
        worker.async { [weak self] in
            let result = Result {
                try work { key, fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.operationID == operation, !self.operationExpired,
                              generation == self.preparationGeneration else { return }
                        if key.hasPrefix("log:") {
                            self.appendLog(String(key.dropFirst(4)))
                        } else {
                            self.progressKey = key
                            self.progressFraction = fraction
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operationID == operation else { return }
                self.endBackgroundTask()
                self.operationID = nil
                self.isBusy = false
                self.progressFraction = nil
                // Record completed device side effects even when the UI session
                // became stale while the blocking service call was returning.
                if case .success(.location(let simulated)) = result {
                    self.locationIsSimulated = simulated
                    self.defaults.set(simulated, forKey: "locationIsSimulated")
                }
                guard !self.operationExpired else { self.progressKey = "progress.idle"; return }
                guard generation == self.preparationGeneration, self.vpn.isConnected else {
                    self.errorMessage = self.localized("error.prepare_required")
                    self.progressKey = "progress.idle"
                    return
                }
                switch result {
                case .success(.prepared):
                    self.isPrepared = true
                    self.progressKey = "progress.ready"
                    self.refreshApplications()
                case .success(.applications(let applications)):
                    self.applications = applications
                    self.applicationError = nil
                    self.progressKey = "progress.ready"
                    if let request = self.requestedApplication {
                        self.requestedApplication = nil
                        if let app = applications.first(where: { $0.bundleIdentifier == request.0 }) {
                            self.launchApplication(app, enableJIT: request.1)
                        } else { self.errorMessage = self.localized("error.app_not_found") }
                    }
                case .success(.launched(let bundleID, let pid, let enabled)):
                    self.scripts.recordLaunch(bundleID)
                    self.targetPID = String(pid)
                    self.successMessage = self.localized(enabled ? "success.jit_enabled" : "success.app_launched")
                    self.appendLog(self.successMessage! + " " + bundleID)
                    self.progressKey = "progress.ready"
                case .success(.details(let details)):
                    self.deviceDetails = details
                    self.progressKey = "progress.ready"
                case .success(.profiles(let profiles)):
                    self.profiles = profiles
                    self.progressKey = "progress.ready"
                case .success(.location(let simulated)):
                    self.locationIsSimulated = simulated
                    self.defaults.set(simulated, forKey: "locationIsSimulated")
                    self.successMessage = self.localized(simulated ? "success.location_set" : "success.location_reset")
                    self.progressKey = "progress.ready"
                case .success(.processes(let processes)):
                    self.processes = processes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    self.progressKey = "progress.ready"
                case .success(.enabled):
                    self.successMessage = self.localized("success.jit_enabled")
                    self.progressKey = "progress.ready"
                case .failure(let error):
                    if failure == "error.preparation_failed" { self.isPrepared = false }
                    self.progressKey = self.isPrepared ? "progress.ready" : "progress.idle"
                    self.errorMessage = self.message(failure, error)
                    if failure == "error.apps_failed" {
                        self.applicationError = self.errorMessage
                        self.requestedApplication = nil
                    }
                    self.appendLog(self.errorMessage!)
                }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    private func message(_ key: String, _ error: Error) -> String {
        localized(key) + "\n" + error.localizedDescription
    }
}

private enum LauncherResult {
    case prepared, processes([LauncherProcess]), enabled
    case applications([LauncherApplication]), launched(String, Int32, Bool)
    case details([String: String]), profiles([LauncherProfile]), location(Bool)
}
private enum LauncherOperationError: Error { case deviceRequired }

/// All synchronous framework calls are executed by the model's single serial queue.
private enum LauncherEngine {
    typealias Report = (String, Double?) -> Void

    static func prepare(record: URL, cache: URL, report: @escaping Report) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        let result = StikJIT.prepareDevice(pairingFile: record, paths: .default(in: cache)) {
            reportStage($0, report: report)
        }
        switch result {
        case .ready: return
        case .unreachable(let reason), .preparationFailed(let reason):
            throw NSError(domain: "JITLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        @unknown default:
            throw NSError(domain: "JITLauncher", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("error.preparation_failed", comment: "")])
        }
        #endif
    }

    static func processes(record: URL) throws -> [LauncherProcess] {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        return try StikJIT.runningProcesses(pairingFile: record).map { LauncherProcess(id: $0.pid, name: $0.name) }
        #endif
    }

    static func enable(pid: Int32, record: URL, cache: URL, script: Data, report: @escaping Report) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.enableJIT(targetPID: pid, pairingFile: record, ddiPaths: .default(in: cache),
                             script: .customBase64(script.base64EncodedString()),
                             preparationProgress: { reportStage($0, report: report) },
                             progress: { report("log:" + $0, nil) })
        #endif
    }

    static func applications(record: URL) throws -> [LauncherApplication] {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        return try StikJIT.installedApplications(pairingFile: record).map {
            LauncherApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.name,
                                isDebuggable: $0.isDebuggable, iconPNG: $0.iconPNG)
        }
        #endif
    }

    static func launch(_ bundleID: String, record: URL, suspended: Bool) throws -> Int32 {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        return try StikJIT.launchApplication(bundleIdentifier: bundleID, pairingFile: record, startSuspended: suspended)
        #endif
    }

    static func resume(_ pid: Int32, record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.resumeProcess(pid: pid, pairingFile: record)
        #endif
    }

    static func terminate(_ pid: Int32, record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.terminateProcess(pid: pid, pairingFile: record)
        #endif
    }

    static func details(record: URL) throws -> [String: String] {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        return try StikJIT.deviceDetails(pairingFile: record)
        #endif
    }

    static func profiles(record: URL) throws -> [LauncherProfile] {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        return try StikJIT.provisioningProfiles(pairingFile: record).map {
            LauncherProfile(id: $0.id, name: $0.name, appIdentifier: $0.appIdentifier,
                            expirationDate: $0.expirationDate, data: $0.data)
        }
        #endif
    }

    static func installProfile(_ data: Data, record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.installProfile(data: data, pairingFile: record)
        #endif
    }

    static func removeProfile(_ identifier: String, record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.removeProfile(identifier: identifier, pairingFile: record)
        #endif
    }

    static func setLocation(_ latitude: Double, _ longitude: Double, record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.setSimulatedLocation(latitude: latitude, longitude: longitude, pairingFile: record)
        #endif
    }

    static func clearLocation(record: URL) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.clearSimulatedLocation(pairingFile: record)
        #endif
    }

    #if !targetEnvironment(simulator)
    private static func reportStage(_ stage: StikJIT.PreparationStage, report: Report) {
        switch stage {
        case .checkingReachability: report("progress.checking_device", nil)
        case .checkingDDI: report("progress.checking_ddi", nil)
        case .downloadingDDI(let fraction, _): report("progress.downloading_ddi", fraction)
        case .mountingDDI(let fraction): report("progress.mounting_ddi", fraction)
        case .verifyingDDI: report("progress.verifying_ddi", nil)
        case .ready: report("progress.ready", nil)
        @unknown default: report("progress.checking_device", nil)
        }
    }
    #endif
}
