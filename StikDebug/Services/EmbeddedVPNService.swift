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
    @Published private(set) var certificateInfo: WLOCCertificateInfo?
    @Published private(set) var isCertificateBusy = false
    @Published private(set) var certificateError: String?
    @Published private(set) var certificateSystemTrusted: Bool?
    @Published private(set) var certificateCheckedAt: Date?
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

    @discardableResult
    func resetProbeStatistics() async -> Bool {
        guard !isTransitioning, !isSelfTesting, mode == .wlocProbe, status.isConnected else { return false }
        let revision = generation
        do {
            let snapshot = try await sendProbeCommand(.reset)
            guard !isTransitioning, revision == generation else { return false }
            acceptProbeSnapshot(snapshot)
            selfTestResult = nil
            #if DEBUG
            debugSelfTest = nil
            #endif
            lastProbeError = nil
            return true
        } catch {
            if !isTransitioning, revision == generation { lastProbeError = error.localizedDescription }
            return false
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
    func performDebugCommand(_ command: ProbeDebugCommand) async -> ProbeDebugRecord {
        var result: ProbeDebugRecord.Result = .ok
        if isTransitioning || isSelfTesting || isCertificateBusy {
            result = .busy
        } else {
            await load()
            // Recheck after suspension: a user action may have started meanwhile.
            if isTransitioning || isSelfTesting || isCertificateBusy { result = .busy }
            else {
                switch command.action {
                case .status:
                    if status.isConnected {
                        do {
                            let revision = generation
                            let snapshot = try await sendProbeCommand(.status)
                            guard revision == generation, !isTransitioning, status.isConnected else {
                                var record = debugRecord(event: .command)
                                record.requestID = command.id
                                record.result = .busy
                                return record
                            }
                            var record = debugRecord(event: .command)
                            record.snapshot = ProbeDebugSnapshot(snapshot)
                            record.requestID = command.id
                            record.result = .ok
                            return record
                        } catch { result = .unavailable }
                    } else if status != .disconnected { result = .unavailable }
                case .reset:
                    guard mode == .wlocProbe, status.isConnected else {
                        var record = debugRecord(event: .command)
                        record.requestID = command.id
                        record.result = .unavailable
                        return record
                    }
                    result = await resetProbeStatistics() ? .ok : .failed
                case .selfTest:
                    if mode == .wlocProbe, status.isConnected {
                        await runProbeSelfTest()
                        result = debugSelfTest?.outcome == .passed ? .ok : .failed
                    } else { result = .unavailable }
                case .stop:
                    // Idempotent: never disconnect an ordinary developer tunnel.
                    if isExperimentEnabled { await stopProbe() }
                    result = !isExperimentEnabled && lastProbeError == nil ? .ok : .failed
                case .certificateStatus, .certificateVerify:
                    guard status.isConnected else {
                        var record = debugRecord(event: .command)
                        record.requestID = command.id
                        record.result = .unavailable
                        return record
                    }
                    let revision = generation
                    await performCertificateCommand(command.action == .certificateStatus ? .status : .verifyTrust)
                    var record = debugRecord(event: .command)
                    record.requestID = command.id
                    guard revision == generation, !isTransitioning, status.isConnected else {
                        record.result = .busy
                        return record
                    }
                    record.result = certificateError == nil ? .ok : .failed
                    if certificateError == nil {
                        record.certificate = ProbeDebugCertificate(prepared: certificateInfo != nil,
                            fingerprintSHA256: certificateInfo?.fingerprintSHA256,
                            notAfter: certificateInfo?.notAfter.timeIntervalSince1970,
                            systemTrusted: certificateSystemTrusted,
                            checkedAt: certificateCheckedAt?.timeIntervalSince1970)
                    }
                    return record
                }
            }
        }
        var record = debugRecord(event: .command)
        record.requestID = command.id
        record.result = result
        return record
    }

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
        try await sendProviderCommand(command, timeoutSeconds: 3)
    }

    /// Public CA metadata only. Does not enable interception or change VPN mode.
    @discardableResult
    func performCertificateCommand(_ command: WLOCCertificateCommand) async -> URL? {
        guard !isCertificateBusy, !isTransitioning, status.isConnected else { return nil }
        isCertificateBusy = true
        certificateError = nil
        // Trust may have changed in Settings. A fresh status/check must never retain stale success.
        if command != .download {
            certificateSystemTrusted = nil
            certificateCheckedAt = nil
        }
        let revision = generation
        let connection = manager?.connection
        defer { isCertificateBusy = false }
        do {
            let reply: WLOCCertificateReply = try await sendProviderCommand(command, timeoutSeconds: 10)
            guard !isTransitioning, revision == generation,
                  connection === manager?.connection, status.isConnected else { return nil }
            if let error = reply.error {
                certificateError = error
                certificateSystemTrusted = nil
                certificateCheckedAt = nil
                return nil
            }
            if certificateInfo?.fingerprintSHA256 != reply.info?.fingerprintSHA256 {
                certificateSystemTrusted = nil
                certificateCheckedAt = nil
            }
            certificateInfo = reply.info
            if command == .verifyTrust {
                certificateSystemTrusted = reply.systemTrusted
                certificateCheckedAt = reply.checkedAt
            }
            // Only accept a local HTTP profile handoff. Never open arbitrary provider URLs.
            if let url = reply.downloadURL {
                guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                      url.user == nil, url.password == nil, url.query == nil,
                      url.fragment == nil, url.lastPathComponent == "StikDebug-WLOC.mobileconfig" else {
                    certificateError = "扩展返回了无效的本机下载地址。".localized
                    return nil
                }
                return url
            }
        } catch {
            if !isTransitioning, revision == generation {
                certificateError = error.localizedDescription
                certificateSystemTrusted = nil
                certificateCheckedAt = nil
            }
        }
        return nil
    }

    private func sendProviderCommand<Command: Encodable, Reply: Decodable>(
        _ command: Command, timeoutSeconds: Int
    ) async throws -> Reply {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { throw ProbeServiceError.notReady }
        let data = try JSONEncoder().encode(command)
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ProviderReply(continuation)
            reply.timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if !Task.isCancelled { reply.finish(.failure(ProbeServiceError.timeout)) }
            }
            do {
                try session.sendProviderMessage(data) { response in
                    Task { @MainActor in
                        guard let response else { reply.finish(.failure(ProbeServiceError.notReady)); return }
                        guard response.count <= 64 * 1024 else {
                            reply.finish(.failure(ProbeServiceError.notReady)); return
                        }
                        reply.finish(Result { try JSONDecoder().decode(Reply.self, from: response) })
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
        if !newStatus.isConnected {
            certificateSystemTrusted = nil
            certificateCheckedAt = nil
        }
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
private final class ProviderReply<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
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
