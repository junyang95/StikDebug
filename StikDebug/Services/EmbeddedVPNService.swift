import Combine
import Foundation
import NetworkExtension

enum EmbeddedVPNStatus: Equatable {
    case loading
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(String)

    var title: String {
        switch self {
        case .loading: "正在读取…".localized
        case .disconnected: "未连接".localized
        case .connecting: "正在连接…".localized
        case .connected: "已连接".localized
        case .disconnecting: "正在断开…".localized
        case .failed(let message): String(format: "失败：%@".localized, message)
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

@MainActor
final class EmbeddedVPNService: ObservableObject {
    static let shared = EmbeddedVPNService()

    @Published private(set) var status: EmbeddedVPNStatus = .loading
    @Published private(set) var mode: EmbeddedVPNMode = .developerLoopback
    @Published private(set) var probeSnapshot: ProbeSnapshot?
    @Published private(set) var isTransitioning = false
    @Published private(set) var lastProbeError: String?
    @Published private(set) var selfTestResult: String?
    @Published private(set) var isSelfTesting = false
    @Published private(set) var experimentPending = UserDefaults.standard.object(forKey: DeveloperConnectionGate.experimentKey) != nil
    private var selfTestSession: URLSession?
    private var generation: UInt64 = 0
    private let restoreOnDemandKey = "wlocProbeRestoreOnDemand"
    #if DEBUG
    private(set) var debugSelfTest: ProbeDebugSelfTest?
    #endif

    var isExperimentEnabled: Bool { experimentPending || mode == .wlocProbe }
    var modeTitle: String {
        if mode == .wlocProbe { return "WLOC 透传实验".localized }
        if experimentPending { return "实验待停止或恢复".localized }
        return "本机开发连接".localized
    }

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private var providerBundleIdentifier: String {
        let hostIdentifier = Bundle.main.bundleIdentifier ?? "com.jy.stikdebug.pikmin"
        return "\(hostIdentifier).networkextension"
    }

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let self else { return }
                // 系统里其它 VPN App 的状态变化也会广播这个通知；只认自己隧道的连接，
                // 否则别的 VPN 一开关，本 App 显示的 VPN 状态就会被带偏。
                guard let ours = self.manager?.connection, connection === ours else { return }
                self.apply(connection.status)
                if !self.isTransitioning { await self.refreshProbeStatus() }
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func load() async {
        guard !isTransitioning else { return }
        let revision = generation
        do {
            let loaded = try await loadMatchingManager()
            guard !isTransitioning, revision == generation else { return }
            manager = loaded
            apply(manager?.connection.status ?? .disconnected)
            await refreshProbeStatus()
        } catch {
            guard !isTransitioning, revision == generation else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func connect() async {
        guard !isTransitioning, !isExperimentEnabled, !DeveloperConnectionGate.isBlocked else { return }
        isTransitioning = true
        generation &+= 1
        defer { isTransitioning = false }
        status = .connecting
        LogManager.shared.addInfoLog("请求连接内置 VPN")
        do {
            let manager = try await configuredManager()
            self.manager = manager
            try manager.connection.startVPNTunnel(options: [
                "TunnelDeviceIP": "10.7.0.0" as NSString,
                "TunnelFakeIP": "10.7.0.1" as NSString,
                "TunnelSubnetMask": "255.255.255.0" as NSString
            ])
            apply(manager.connection.status)
        } catch {
            LogManager.shared.addErrorLog(String(format: "连接内置 VPN 失败：%@".localized, error.localizedDescription))
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        guard !isTransitioning else { return }
        if isExperimentEnabled {
            Task { await stopProbe() }
            return
        }
        LogManager.shared.addInfoLog("请求断开内置 VPN")
        manager?.connection.stopVPNTunnel()
        apply(manager?.connection.status ?? .disconnected)
    }

    func startProbe() async {
        guard !isTransitioning, !isExperimentEnabled else { return }
        guard !WalkingSessionController.shared.isActive,
              !OnDevicePairingService.shared.isBusy,
              FixedLocationSessionController.shared.coordinate == nil,
              DeveloperConnectionGate.beginProbe() else {
            lastProbeError = "请先停止定点、摇杆或路线，并使用恢复真实定位；有命令执行中时请稍后重试。".localized
            return
        }
        isTransitioning = true
        generation &+= 1
        lastProbeError = nil
        selfTestResult = nil
        #if DEBUG
        debugSelfTest = nil
        #endif
        defer { isTransitioning = false }
        do {
            // Drain an already-running preflight; its subsequent stages see the gate and stop.
            let deadline = Date().addingTimeInterval(15)
            while EnvironmentPreflightService.shared.isRefreshing {
                guard Date() < deadline else { throw ProbeServiceError.preflightBusy }
                try await Task.sleep(for: .milliseconds(100))
            }
            let manager = try await configuredManager()
            self.manager = manager
            let restoreConnection = manager.connection.status == .connected || manager.connection.status == .connecting
            UserDefaults.standard.set(restoreConnection, forKey: DeveloperConnectionGate.experimentKey)
            UserDefaults.standard.set(manager.isOnDemandEnabled, forKey: restoreOnDemandKey)
            experimentPending = true
            try await stopAndWait(manager)
            manager.isOnDemandEnabled = false
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try await startAndWait(manager, mode: .wlocProbe)
            let snapshot = try await sendProbeCommand(.status)
            guard snapshot.mode == .wlocProbe, snapshot.listening else { throw ProbeServiceError.notReady }
            mode = snapshot.mode
            probeSnapshot = snapshot
        } catch {
            lastProbeError = error.localizedDescription
            if experimentPending {
                // Leave the gate closed if rollback itself fails; the user can retry Stop safely.
                do { try await restoreAfterProbe() }
                catch { lastProbeError = "实验启动失败，恢复隧道也失败。请重试停止测试。".localized }
            } else {
                DeveloperConnectionGate.setBlocked(false)
            }
        }
    }

    func stopProbe() async {
        guard !isTransitioning, isExperimentEnabled else { return }
        isTransitioning = true
        generation &+= 1
        selfTestSession?.invalidateAndCancel()
        lastProbeError = nil
        defer { isTransitioning = false }
        do { try await restoreAfterProbe() }
        catch { lastProbeError = "停止或恢复隧道失败，请重试；必要时先在系统设置中关闭本 App 的 VPN。".localized }
    }

    private func restoreAfterProbe() async throws {
        guard let manager else { throw ProbeServiceError.notReady }
        try await stopAndWait(manager)
        let restoreConnection = UserDefaults.standard.bool(forKey: DeveloperConnectionGate.experimentKey)
        manager.isOnDemandEnabled = UserDefaults.standard.bool(forKey: restoreOnDemandKey)
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if restoreConnection { try await startAndWait(manager, mode: .developerLoopback) }
        mode = .developerLoopback
        probeSnapshot?.listening = false
        probeSnapshot?.port = nil
        UserDefaults.standard.removeObject(forKey: DeveloperConnectionGate.experimentKey)
        UserDefaults.standard.removeObject(forKey: restoreOnDemandKey)
        experimentPending = false
        DeveloperConnectionGate.setBlocked(false)
    }

    private func stopAndWait(_ manager: NETunnelProviderManager) async throws {
        if manager.connection.status != .disconnected && manager.connection.status != .invalid {
            manager.connection.stopVPNTunnel()
            let deadline = Date().addingTimeInterval(15)
            while manager.connection.status != .disconnected && manager.connection.status != .invalid {
                guard Date() < deadline else { throw ProbeServiceError.timeout }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        apply(manager.connection.status)
    }

    private func startAndWait(_ manager: NETunnelProviderManager, mode: EmbeddedVPNMode) async throws {
        try manager.connection.startVPNTunnel(options: [
            "Mode": mode.rawValue as NSString,
            "TunnelDeviceIP": "10.7.0.0" as NSString,
            "TunnelFakeIP": "10.7.0.1" as NSString,
            "TunnelSubnetMask": "255.255.255.0" as NSString
        ])
        let deadline = Date().addingTimeInterval(15)
        while manager.connection.status != .connected {
            guard Date() < deadline else { throw ProbeServiceError.timeout }
            try await Task.sleep(for: .milliseconds(150))
        }
        apply(manager.connection.status)
    }

    func refreshProbeStatus() async {
        guard !isTransitioning, status.isConnected else { return }
        let revision = generation
        let connection = manager?.connection
        do {
            let snapshot = try await sendProbeCommand(.status)
            guard !isTransitioning, revision == generation, connection === manager?.connection, status.isConnected else { return }
            mode = snapshot.mode
            if mode == .wlocProbe {
                acceptProbeSnapshot(snapshot)
                // Covers app relaunch while the extension remained alive.
                if !experimentPending {
                    UserDefaults.standard.set(false, forKey: DeveloperConnectionGate.experimentKey)
                    experimentPending = true
                }
            }
            DeveloperConnectionGate.setBlocked(isExperimentEnabled)
        } catch {
            if !isTransitioning, revision == generation, isExperimentEnabled {
                lastProbeError = "无法读取扩展状态，请刷新或停止测试。".localized
            }
        }
    }

    func resetProbeStatistics() async {
        guard !isTransitioning, !isSelfTesting, mode == .wlocProbe, status.isConnected else { return }
        let revision = generation
        do {
            let snapshot = try await sendProbeCommand(.reset)
            guard !isTransitioning, revision == generation else { return }
            acceptProbeSnapshot(snapshot)
            selfTestResult = nil
            #if DEBUG
            debugSelfTest = nil
            #endif
            lastProbeError = nil
        } catch {
            if !isTransitioning, revision == generation { lastProbeError = error.localizedDescription }
        }
    }

    func runProbeSelfTest() async {
        guard !isTransitioning, !isSelfTesting, mode == .wlocProbe, status.isConnected else { return }
        isSelfTesting = true
        let revision = generation
        selfTestResult = "正在通过系统代理设置发起 HTTPS 请求…".localized
        #if DEBUG
        debugSelfTest = ProbeDebugSelfTest(outcome: .running)
        ProbeDebugLog.emit(debugRecord(event: .selfTest))
        #endif
        defer { isSelfTesting = false; selfTestSession = nil }
        do {
            let before = try await sendProbeCommand(.reset)
            // Stop can complete while provider IPC is suspended. Never launch a late request
            // after the user has left the experiment.
            guard isExperimentEnabled, !isTransitioning, revision == generation else { return }
            acceptProbeSnapshot(before)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            // No explicit proxy override: this checks NEProxySettings, not merely the listener.
            // Default server-trust validation remains enabled. Redirects are rejected by the delegate.
            let delegate = ProbeSelfTestDelegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            selfTestSession = session
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://gs-loc.apple.com/")!)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await session.data(for: request)
            let after = try await sendProbeCommand(.status)
            guard isExperimentEnabled, !isTransitioning, revision == generation, before.sessionID == after.sessionID else { return }
            acceptProbeSnapshot(after)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if delegate.usedProxy, after.totalConnections > 0, after.uploadedBytes > 0, after.downloadedBytes > 0 {
                selfTestResult = String(format: "HTTPS 请求与代理双向数据均已观察到（HTTP %d）。请清空记录后再打开地图；这不是定位成功证明。".localized, httpStatus)
                #if DEBUG
                debugSelfTest = ProbeDebugSelfTest(outcome: .passed, httpStatus: httpStatus, usedProxy: delegate.usedProxy)
                #endif
            } else {
                selfTestResult = "HTTPS 请求完成，但未观察到代理双向数据，不能确认请求经过本机代理。".localized
                #if DEBUG
                debugSelfTest = ProbeDebugSelfTest(outcome: .unconfirmed, httpStatus: httpStatus, usedProxy: delegate.usedProxy)
                #endif
            }
            #if DEBUG
            ProbeDebugLog.emit(debugRecord(event: .selfTest))
            #endif
        } catch {
            if isExperimentEnabled, !isTransitioning, revision == generation {
                selfTestResult = "自测未通过：".localized + error.localizedDescription
                await refreshProbeStatus()
                #if DEBUG
                let nsError = error as NSError
                debugSelfTest = ProbeDebugSelfTest(outcome: .failed,
                    urlErrorCode: nsError.domain == NSURLErrorDomain ? nsError.code : nil)
                ProbeDebugLog.emit(debugRecord(event: .selfTest))
                #endif
            }
        }
    }

    #if DEBUG
    func debugRecord(event: ProbeDebugRecord.Event) -> ProbeDebugRecord {
        let vpnState: ProbeDebugRecord.VPNState = switch status {
        case .loading: .loading
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .failed: .failed
        }
        let snapshot = mode == .wlocProbe && status.isConnected ? probeSnapshot.map(ProbeDebugSnapshot.init) : nil
        return ProbeDebugRecord(source: .app, event: event, snapshot: snapshot,
                                selfTest: debugSelfTest, vpnState: vpnState,
                                experimentEnabled: isExperimentEnabled)
    }
    #endif

    private func acceptProbeSnapshot(_ snapshot: ProbeSnapshot) {
        // A poll issued before Reset may reply after it. Do not resurrect cleared observations.
        if let current = probeSnapshot, current.sessionID == snapshot.sessionID,
           current.resetAt > snapshot.resetAt { return }
        probeSnapshot = snapshot
    }

    private func sendProbeCommand(_ command: ProbeCommand) async throws -> ProbeSnapshot {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { throw ProbeServiceError.notReady }
        let data = try JSONEncoder().encode(command)
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ProbeReply(continuation)
            reply.timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { reply.finish(.failure(ProbeServiceError.timeout)) }
            }
            do {
                try session.sendProviderMessage(data) { response in
                    Task { @MainActor in
                        guard let response else { reply.finish(.failure(ProbeServiceError.notReady)); return }
                        reply.finish(Result { try JSONDecoder().decode(ProbeSnapshot.self, from: response) })
                    }
                }
            } catch { reply.finish(.failure(error)) }
        }
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        if let manager {
            try await manager.loadFromPreferences()
            return manager
        }
        if let existing = try await loadMatchingManager() {
            try await existing.loadFromPreferences()
            return existing
        }

        let manager = NETunnelProviderManager()
        manager.localizedDescription = "StikDebug 本地隧道".localized
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = "仅限设备本地开发连接".localized
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    private func loadMatchingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { manager in
            guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
        }
    }

    private func apply(_ vpnStatus: NEVPNStatus) {
        let newStatus: EmbeddedVPNStatus = switch vpnStatus {
        case .invalid, .disconnected: .disconnected
        case .connecting, .reasserting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        @unknown default: .disconnected
        }
        if newStatus != status {
            LogManager.shared.addInfoLog("内置 VPN 状态：\(newStatus.title)")
        }
        status = newStatus
    }
}

private enum ProbeServiceError: LocalizedError {
    case timeout, notReady, preflightBusy
    var errorDescription: String? {
        switch self {
        case .timeout: "等待网络扩展超时。".localized
        case .notReady: "本机代理尚未就绪，请重试连接。".localized
        case .preflightBusy: "开发环境检查尚未结束，请稍后重试。".localized
        }
    }
}

@MainActor
private final class ProbeReply {
    private var continuation: CheckedContinuation<ProbeSnapshot, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<ProbeSnapshot, Error>) { self.continuation = continuation }
    func finish(_ result: Result<ProbeSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

private final class ProbeSelfTestDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var proxyObserved = false
    var usedProxy: Bool {
        lock.lock(); defer { lock.unlock() }
        return proxyObserved
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        proxyObserved = metrics.transactionMetrics.contains { $0.isProxyConnection }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
