import CoreLocation
import Foundation
import HealthKit
import Network
import NetworkExtension

enum PermissionKind: String, CaseIterable, Identifiable {
    case vpn
    case healthSteps
    case network
    case locationAlways

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vpn: "VPN 配置权限".localized
        case .healthSteps: "健康步数权限".localized
        case .network: "网络连通性".localized
        case .locationAlways: "位置始终允许".localized
        }
    }

    var systemImage: String {
        switch self {
        case .vpn: "shield.lefthalf.filled"
        case .healthSteps: "heart.text.square"
        case .network: "antenna.radiowaves.left.and.right"
        case .locationAlways: "location.circle"
        }
    }
}

struct PermissionItem: Identifiable, Equatable {
    let kind: PermissionKind
    var status: PreflightStatus
    var id: String { kind.id }
}

@MainActor
final class PermissionChecklistService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PermissionChecklistService()

    @Published private(set) var items = PermissionKind.allCases.map {
        PermissionItem(kind: $0, status: .unknown)
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastCheckedAt: Date?

    private let healthStore = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let locationManager = CLLocationManager()
    private let pathMonitor = Network.NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.pikminhelper.permissions.network")
    private var latestPath: Network.NWPath?

    private var providerBundleIdentifier: String {
        let hostIdentifier = Bundle.main.bundleIdentifier ?? "com.jy.stikdebug.pikmin"
        return "\(hostIdentifier).networkextension"
    }

    var blockingItems: [PermissionItem] {
        items.filter { item in
            switch item.kind {
            case .network:
                return false
            case .vpn, .healthSteps, .locationAlways:
                return !item.status.isReady
            }
        }
    }

    var allRequiredGranted: Bool {
        blockingItems.isEmpty
    }

    var canRequestLocationPromptNow: Bool {
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            true
        default:
            false
        }
    }

    var canRequestHealthPromptNow: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return healthStore.authorizationStatus(for: stepType) != .sharingDenied
    }

    override private init() {
        super.init()
        locationManager.delegate = self
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.latestPath = path
                self?.updateNetworkStatus(path)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        set(.checking, for: .vpn)
        set(.checking, for: .healthSteps)
        set(.checking, for: .locationAlways)
        if let latestPath {
            updateNetworkStatus(latestPath)
        } else {
            set(.warning("等待系统返回网络状态；Wi‑Fi/蜂窝不是单独授权项".localized), for: .network)
        }

        set(await vpnConfigurationStatus(), for: .vpn)
        set(healthAuthorizationStatus(), for: .healthSteps)
        set(locationAuthorizationStatus(), for: .locationAlways)

        lastCheckedAt = Date()
        isRefreshing = false
    }

    func requestVPNPermission() async {
        await EmbeddedVPNService.shared.connect()
        await refresh()
    }

    func requestHealthPermission() async {
        _ = await HealthStepService.shared.requestAuthorization()
        await refresh()
    }

    func requestLocationAlwaysPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        set(locationAuthorizationStatus(), for: .locationAlways)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.set(self.locationAuthorizationStatus(), for: .locationAlways)
        }
    }

    private func vpnConfigurationStatus() async -> PreflightStatus {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first(where: { manager in
                guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
            }) else {
                return .failed("尚未添加本 App 的 VPN 配置；首次连接时需同意系统弹窗".localized)
            }

            guard manager.isEnabled else {
                return .failed("VPN 配置存在但未启用".localized)
            }

            if manager.connection.status == .connected {
                return .ready("VPN 配置已授权并已连接".localized)
            }
            return .ready("VPN 配置已授权；当前未连接".localized)
        } catch {
            return .failed(String(format: "无法读取 VPN 配置：%@".localized, error.localizedDescription))
        }
    }

    private func healthAuthorizationStatus() -> PreflightStatus {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .failed("当前设备不支持 HealthKit".localized)
        }

        switch healthStore.authorizationStatus(for: stepType) {
        case .sharingAuthorized:
            return .ready("已允许写入步数；读权限由系统隐私保护，无法直接查询".localized)
        case .sharingDenied:
            return .failed("已拒绝步数写入，请到系统健康权限中打开".localized)
        case .notDetermined:
            return .failed("尚未请求健康步数权限".localized)
        @unknown default:
            return .warning("系统返回未知 HealthKit 授权状态".localized)
        }
    }

    private func locationAuthorizationStatus() -> PreflightStatus {
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            return .ready("已允许始终访问位置".localized)
        case .authorizedWhenInUse:
            return .warning("仅允许使用期间；后台行走保活需要始终允许".localized)
        case .notDetermined:
            return .failed("尚未请求位置权限".localized)
        case .denied:
            return .failed("已拒绝位置权限，请到系统设置中改为始终允许".localized)
        case .restricted:
            return .failed("位置权限受系统限制".localized)
        @unknown default:
            return .warning("系统返回未知位置授权状态".localized)
        }
    }

    private func updateNetworkStatus(_ path: Network.NWPath) {
        guard path.status == .satisfied else {
            set(.failed("当前没有可用网络".localized), for: .network)
            return
        }

        let interface = if path.usesInterfaceType(.wifi) {
            "Wi‑Fi"
        } else if path.usesInterfaceType(.cellular) {
            "蜂窝网络".localized
        } else if path.usesInterfaceType(.wiredEthernet) {
            "有线网络".localized
        } else {
            "其他网络".localized
        }

        set(.ready(String(format: "网络可用：%@。普通 Wi‑Fi/蜂窝访问不是用户授权项".localized, interface)), for: .network)
    }

    private func set(_ status: PreflightStatus, for kind: PermissionKind) {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[index].status = status
    }
}
