import Foundation
import Network
import idevice

enum PreflightKind: String, CaseIterable, Identifiable {
    case wifi
    case vpnRoute
    case pairing
    case ddi
    case coreDeviceTunnel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi 网络".localized
        case .vpnRoute: "内置 VPN 路由".localized
        case .pairing: "设备配对文件".localized
        case .coreDeviceTunnel: "CoreDevice 隧道".localized
        case .ddi: "Developer Disk Image"
        }
    }

    var systemImage: String {
        switch self {
        case .wifi: "wifi"
        case .vpnRoute: "network.badge.shield.half.filled"
        case .pairing: "checkmark.shield"
        case .coreDeviceTunnel: "point.3.connected.trianglepath.dotted"
        case .ddi: "externaldrive.badge.checkmark"
        }
    }
}

enum PreflightStatus: Equatable {
    case unknown
    case checking
    case ready(String)
    case warning(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }

    var message: String {
        switch self {
        case .unknown: "尚未检查".localized
        case .checking: "正在检查…".localized
        case .ready(let message), .warning(let message), .failed(let message): message
        }
    }
}

struct PreflightItem: Identifiable, Equatable {
    let kind: PreflightKind
    var status: PreflightStatus
    var id: String { kind.id }
}

@MainActor
final class EnvironmentPreflightService: ObservableObject {
    static let shared = EnvironmentPreflightService()

    @Published private(set) var items = PreflightKind.allCases.map {
        PreflightItem(kind: $0, status: .unknown)
    }
    /// DDI 文件是否缺失。以前界面靠匹配中文提示文案来判断，文案一翻译就失效，
    /// 改成由服务直接给出状态。
    @Published private(set) var ddiFilesMissing = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastCheckedAt: Date?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.pikminhelper.preflight.network")
    private var latestPath: NWPath?
    private var pairingMonitorTask: Task<Void, Never>?
    private var pairingNotificationObserver: NSObjectProtocol?
    private var lastPairingSignature = PairingFileStore.stateSignature()

    var blockingItems: [PreflightItem] {
        items.filter { item in
            switch item.kind {
            case .wifi:
                return false
            case .vpnRoute, .pairing, .coreDeviceTunnel, .ddi:
                return !item.status.isReady
            }
        }
    }

    var canStartSession: Bool {
        blockingItems.isEmpty
    }

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.latestPath = path
                self.updateWiFiStatus(path)
                // 网络路径变化很频繁（VPN 连接/重连时尤甚）。完整探测很重
                // （2.5s TCP 探测 + 建隧道 FFI），这里做节流：距上次检查不足 12 秒就跳过，
                // 只保留上面轻量的 Wi‑Fi 状态更新，避免反复重活导致发热。
                guard let last = self.lastCheckedAt, Date().timeIntervalSince(last) > 12 else { return }
                await self.refresh()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        pairingNotificationObserver = NotificationCenter.default.addObserver(
            forName: PairingFileStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterPairingFileChange()
            }
        }
        startPairingFileMonitor()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for kind in PreflightKind.allCases {
            set(.checking, for: kind)
        }

        if let latestPath {
            updateWiFiStatus(latestPath)
        } else {
            set(.warning("等待系统返回网络状态".localized), for: .wifi)
        }

        let pairingResult = await Task.detached(priority: .userInitiated) {
            Self.validatePairingFile()
        }.value
        set(pairingResult, for: .pairing)

        let missingDDIFiles = Self.missingDDIFiles()
        ddiFilesMissing = !missingDDIFiles.isEmpty
        if missingDDIFiles.isEmpty {
            set(.warning("DDI 文件可用，等待 CoreDevice/RSD 后挂载".localized), for: .ddi)
        } else {
            set(.failed(String(format: "缺少 DDI 文件：%@".localized, missingDDIFiles.joined(separator: ", "))), for: .ddi)
        }

        let routeReachable = await Self.probeLocalDevRoute()
        let vpnConnected = EmbeddedVPNService.shared.status.isConnected
        LogManager.shared.addLog(
            message: "内置 VPN 路由探测 \(DeviceConnectionContext.targetIPAddress):49152 → \(routeReachable ? "可达" : "不可达")（VPN \(vpnConnected ? "已连接" : "未连接")）",
            type: routeReachable ? .info : .warning
        )
        let routeFailureMessage = vpnConnected
            // 隧道已连上却探测不到，问题在设备端开发服务，而不是「没连 VPN」。
            // 别再提示「请连接内置 VPN」——那正是让用户困惑的地方。
            // 实测：关闭开发者模式再重新打开（会重启）最有效，把它放在最前面引导。
            ? "隧道已连接，但访问不到设备开发服务(:49152)。多数可通过「关闭开发者模式再重新打开（会重启）」修复；也可能是 pairing file 不是本机生成".localized
            : "无法访问目标地址，请先连接内置 VPN".localized
        set(
            routeReachable
                ? .ready(String(format: "已连接到 %@:49152".localized, DeviceConnectionContext.targetIPAddress))
                : .failed(routeFailureMessage),
            for: .vpnRoute
        )

        guard pairingResult.isReady, routeReachable else {
            set(.failed("需先完成 pairing file 并连接内置 VPN 路由".localized), for: .coreDeviceTunnel)
            finishRefresh()
            return
        }

        guard missingDDIFiles.isEmpty else {
            set(.failed("DDI 文件缺失，先下载 DDI".localized), for: .coreDeviceTunnel)
            finishRefresh()
            return
        }

        let tunnelResult = await Task.detached(priority: .userInitiated) {
            () -> Result<Void, Error> in
            do {
                try JITEnableContext.shared.startTunnel()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch tunnelResult {
        case .success:
            set(.ready("CoreDevice/RSD 握手成功".localized), for: .coreDeviceTunnel)
        case .failure(let error):
            LogManager.shared.addErrorLog("CoreDevice/RSD 隧道建立失败：\(error.localizedDescription)")
            set(.failed(error.localizedDescription), for: .coreDeviceTunnel)
            set(.failed("CoreDevice 隧道不可用".localized), for: .ddi)
            finishRefresh()
            return
        }

        let ddiResult = await Task.detached(priority: .userInitiated) {
            checkMountStatus()
        }.value
        switch ddiResult {
        case .mounted:
            set(.ready("DDI 已挂载".localized), for: .ddi)
        case .notMounted:
            set(.warning("DDI 文件可用，但尚未挂载".localized), for: .ddi)
        case .unreachable:
            set(.failed("无法读取设备端 DDI 状态".localized), for: .ddi)
        }

        finishRefresh()
    }

    private func startPairingFileMonitor() {
        pairingMonitorTask?.cancel()
        pairingMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshAfterPairingFileChange()
            }
        }
    }

    private func refreshAfterPairingFileChange() async {
        let beforeMigrationSignature = PairingFileStore.stateSignature()
        guard beforeMigrationSignature != lastPairingSignature else { return }

        _ = PairingFileStore.prepareURL()
        lastPairingSignature = PairingFileStore.stateSignature()
        await refresh()
    }

    func connectAndMount() {
        startTunnelInBackground(showErrorUI: true)
        Task {
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
                if canStartSession { break }
            }
        }
    }

    private func updateWiFiStatus(_ path: NWPath) {
        if path.status != .satisfied {
            set(.failed("当前没有可用网络".localized), for: .wifi)
        } else if path.usesInterfaceType(.wifi) {
            set(.ready("Wi-Fi 已连接".localized), for: .wifi)
        } else {
            set(.warning("未检测到 Wi-Fi；若 VPN 隧道可用仍可继续".localized), for: .wifi)
        }
    }

    private func finishRefresh() {
        lastCheckedAt = Date()
        isRefreshing = false
    }

    private func set(_ status: PreflightStatus, for kind: PreflightKind) {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[index].status = status
    }

    nonisolated private static func validatePairingFile() -> PreflightStatus {
        let url = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failed("尚未导入 pairing file".localized)
        }

        var handle: OpaquePointer?
        let error = url.path.withCString { rp_pairing_file_read($0, &handle) }
        if let error {
            idevice_error_free(error)
            return .failed("pairing file 无法解析".localized)
        }
        guard let handle else {
            return .failed("pairing file 内容无效".localized)
        }
        rp_pairing_file_free(handle)
        return .ready("pairing file 可读取".localized)
    }

    nonisolated private static func probeLocalDevRoute() async -> Bool {
        await withCheckedContinuation { continuation in
            let probe = RouteProbe(
                host: NWEndpoint.Host(DeviceConnectionContext.targetIPAddress),
                port: 49152,
                completion: { continuation.resume(returning: $0) }
            )
            probe.start()
        }
    }

    nonisolated private static func missingDDIFiles() -> [String] {
        let requiredFiles = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]
        return requiredFiles.filter { name in
            !FileManager.default.fileExists(
                atPath: URL.documentsDirectory
                    .appendingPathComponent("DDI")
                    .appendingPathComponent(name)
                    .path
            )
        }
    }
}

private final class RouteProbe {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.pikminhelper.preflight.route-probe")
    private let completion: (Bool) -> Void
    private let lock = NSLock()
    private var completed = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, completion: @escaping (Bool) -> Void) {
        connection = NWConnection(host: host, port: port, using: .tcp)
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finish(false)
        }
    }

    private func finish(_ result: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}
