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
                if let ours = self.manager?.connection, connection !== ours { return }
                self.apply(connection.status)
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func load() async {
        do {
            manager = try await loadMatchingManager()
            apply(manager?.connection.status ?? .disconnected)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func connect() async {
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
        LogManager.shared.addInfoLog("请求断开内置 VPN")
        manager?.connection.stopVPNTunnel()
        apply(manager?.connection.status ?? .disconnected)
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
        manager.localizedDescription = "Pikmin Helper 本地隧道".localized
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
