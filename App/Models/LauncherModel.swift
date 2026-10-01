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

    let vpn = LocalVPNManager()
    private let defaults: UserDefaults
    private let store: PairingRecordStore
    private let cacheDirectory: URL
    private let worker = DispatchQueue(label: "com.stik.JITLauncher.device", qos: .userInitiated)
    private var observation: AnyCancellable?
    private var preparationGeneration = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var operationExpired = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JITLauncher", isDirectory: true)
        store = PairingRecordStore(directory: library.appendingPathComponent("Pairing", isDirectory: true))
        cacheDirectory = library.appendingPathComponent("DeviceSupport", isDirectory: true)
        developerModeConfirmed = defaults.bool(forKey: "developerModeConfirmed")
        pairingFileName = store.hasRecord ? (defaults.string(forKey: "pairingFileName") ?? "pairing.plist") : nil
        observation = vpn.$status.removeDuplicates().sink { [weak self] status in
            guard status != .connected else { return }
            self?.invalidatePreparation()
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
    }

    func importPairingFile(from url: URL) {
        guard !isBusy else { return }
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
        guard !isBusy else { return }
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
        let record = store.fileURL
        let cache = cacheDirectory
        perform(progress: "progress.enabling_jit", failure: "error.jit_failed") { report in
            try LauncherEngine.enable(pid: pid, record: record, cache: cache, report: report)
            return .enabled
        }
    }

    private func preflight(requirePreparation: Bool = false) -> Bool {
        guard !isBusy else { return false }
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
        let generation = preparationGeneration
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JIT operation") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
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
                        guard let self, !self.operationExpired,
                              generation == self.preparationGeneration else { return }
                        self.progressKey = key
                        self.progressFraction = fraction
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.endBackgroundTask()
                self.isBusy = false
                self.progressFraction = nil
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
                case .success(.processes(let processes)):
                    self.processes = processes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    self.progressKey = "progress.ready"
                case .success(.enabled):
                    self.successMessage = self.localized("success.jit_enabled")
                    self.progressKey = "progress.ready"
                case .failure(let error):
                    self.isPrepared = false
                    self.progressKey = "progress.idle"
                    self.errorMessage = self.message(failure, error)
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

private enum LauncherResult { case prepared, processes([LauncherProcess]), enabled }
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

    static func enable(pid: Int32, record: URL, cache: URL, report: @escaping Report) throws {
        #if targetEnvironment(simulator)
        throw LauncherOperationError.deviceRequired
        #else
        try StikJIT.enableJIT(targetPID: pid, pairingFile: record, ddiPaths: .default(in: cache),
                             script: .universal,
                             preparationProgress: { reportStage($0, report: report) },
                             progress: { _ in report("progress.enabling_jit", nil) })
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
