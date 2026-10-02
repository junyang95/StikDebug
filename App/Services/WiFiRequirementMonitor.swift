import Combine
import Foundation
import Network

/// A usable Wi-Fi path is required for the device connection. A cellular or
/// VPN-only path is insufficient, even when it provides internet access.
enum WiFiRequirementState: Equatable, Sendable {
    case checking
    case available
    case unavailable

    var isAvailable: Bool { self == .available }

    static func evaluate(isSatisfied: Bool, usesWiFi: Bool) -> Self {
        isSatisfied && usesWiFi ? .available : .unavailable
    }
}

/// This small adapter also permits deterministic tests of stale OS callbacks.
protocol WiFiPathMonitoring: AnyObject {
    func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (WiFiRequirementState) -> Void)
    func cancel()
}

private final class SystemWiFiPathMonitor: WiFiPathMonitoring {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

    func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (WiFiRequirementState) -> Void) {
        monitor.pathUpdateHandler = { path in
            onUpdate(.evaluate(
                isSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi)
            ))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

@MainActor
final class WiFiRequirementMonitor: ObservableObject {
    @Published private(set) var state: WiFiRequirementState = .checking

    var isAvailable: Bool { state.isAvailable }

    private let queue = DispatchQueue(label: "com.stik.StikPair.wifi-requirement")
    private let makeMonitor: () -> WiFiPathMonitoring
    private var monitor: WiFiPathMonitoring?
    private var generation: UInt64 = 0

    init(makeMonitor: @escaping () -> WiFiPathMonitoring = { SystemWiFiPathMonitor() }) {
        self.makeMonitor = makeMonitor
        refresh()
    }

    deinit {
        monitor?.cancel()
    }

    /// Refresh on foreground entry. Discard the previous answer immediately so
    /// an old Wi-Fi path cannot admit work before the first fresh OS update.
    func refresh() {
        stop()
        let currentGeneration = generation
        let nextMonitor = makeMonitor()
        monitor = nextMonitor
        nextMonitor.start(queue: queue) { [weak self] nextState in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, self.monitor != nil else { return }
                self.state = nextState
            }
        }
    }

    /// Call when the owner suspends monitoring. Previously queued callbacks may
    /// still arrive, but their generation can no longer update the state.
    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        state = .checking
    }
}
