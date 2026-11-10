import Foundation
import Network

enum LocationNetworkState: Equatable {
    case checking
    case wifi
    case cellular
    case unavailable

    init(isSatisfied: Bool, usesWiFi: Bool, usesCellular: Bool) {
        if !isSatisfied {
            self = .unavailable
        } else if usesWiFi {
            // Personal Hotspot is Wi-Fi too, even when the path is expensive.
            self = .wifi
        } else if usesCellular {
            self = .cellular
        } else {
            self = .unavailable
        }
    }

    init(path: NWPath) {
        self.init(isSatisfied: path.status == .satisfied,
                  usesWiFi: path.usesInterfaceType(.wifi),
                  usesCellular: path.usesInterfaceType(.cellular))
    }

    var isReady: Bool { self == .wifi }

    var blockingMessage: String? {
        switch self {
        case .wifi: nil
        case .checking: "正在检测网络，请稍后重试。".localized
        case .cellular: "当前正在使用流量，无法模拟定位。请先连接 Wi-Fi 或其他设备的热点。".localized
        case .unavailable: "模拟定位需要 Wi-Fi 或热点，请先连接 Wi-Fi 或其他设备的热点。".localized
        }
    }
}

/// Network callbacks and location commands run on different queues. Check again
/// at the command boundary so queued sends cannot bypass a network change.
final class LocationNetworkGate: @unchecked Sendable {
    static let shared = LocationNetworkGate()
    static let blockedStatus: Int32 = 87
    private let lock = NSLock()
    private var value: LocationNetworkState = .checking

    var state: LocationNetworkState {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ state: LocationNetworkState) {
        lock.lock(); defer { lock.unlock() }
        value = state
    }

    static func message(for code: Int32) -> String? {
        guard code == blockedStatus else { return nil }
        return shared.state.blockingMessage ?? LocationNetworkState.unavailable.blockingMessage
    }
}
