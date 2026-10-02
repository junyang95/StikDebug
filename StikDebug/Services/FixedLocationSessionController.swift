import Combine
import CoreLocation
import Foundation

@MainActor
final class FixedLocationSessionController: ObservableObject {
    static let shared = FixedLocationSessionController()

    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private var resendTimer: DispatchSourceTimer?
    private var hasKeepAliveLease = false
    private let commandGeneration = FixedLocationCommandGeneration()
    private var isForeground = true

    private init() {}

    var resendInterval: TimeInterval {
        isForeground ? 1 : 3
    }

    func start(_ coordinate: CLLocationCoordinate2D, isForeground: Bool) {
        guard !DeveloperConnectionGate.isBlocked, VipLocationGate.shared.allows() else { return }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        self.coordinate = coordinate
        self.isForeground = isForeground
        acquireKeepAliveIfNeeded()
        schedule(sendImmediately: false)
    }

    /// Preserve the last WGS-84 position without an initial resend gap.
    func hold(_ coordinate: CLLocationCoordinate2D) {
        start(coordinate, isForeground: isForeground)
        schedule(sendImmediately: true)
    }

    func updateForegroundState(_ isForeground: Bool) {
        guard self.isForeground != isForeground else { return }
        self.isForeground = isForeground
        guard coordinate != nil else { return }
        schedule(sendImmediately: isForeground)
    }

    func stop() {
        commandGeneration.invalidate()
        resendTimer?.cancel()
        resendTimer = nil
        coordinate = nil
        releaseKeepAliveIfNeeded()
    }

    private func schedule(sendImmediately: Bool) {
        guard let coordinate else { return }
        resendTimer?.cancel()

        let interval = resendInterval
        let ip = DeviceConnectionContext.targetIPAddress
        let pairingPath = PairingFileStore.prepareURL().path
        let generation = commandGeneration.invalidate()
        let commandGeneration = commandGeneration
        let send: @Sendable () -> Void = {
            guard commandGeneration.isCurrent(generation) else { return }
            let jittered = MovementMath.offset(
                coordinate,
                eastMeters: Double.random(in: -1.5...1.5),
                northMeters: Double.random(in: -1.5...1.5)
            )
            _ = simulate_location(ip, jittered.latitude, jittered.longitude, pairingPath)
        }

        if sendImmediately {
            LocationSimulationCommandQueue.shared.async(execute: send)
        }
        let timer = DispatchSource.makeTimerSource(queue: LocationSimulationCommandQueue.shared)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(isForeground ? 200 : 750)
        )
        timer.setEventHandler(handler: send)
        resendTimer = timer
        timer.resume()
    }

    private func acquireKeepAliveIfNeeded() {
        guard !hasKeepAliveLease else { return }
        hasKeepAliveLease = true
        BackgroundLocationManager.shared.requestStart()
        BackgroundAudioManager.shared.requestStart()
    }

    private func releaseKeepAliveIfNeeded() {
        guard hasKeepAliveLease else { return }
        hasKeepAliveLease = false
        BackgroundLocationManager.shared.requestStop()
        BackgroundAudioManager.shared.requestStop()
    }
}

private final class FixedLocationCommandGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    @discardableResult func invalidate() -> UUID {
        lock.lock(); defer { lock.unlock() }
        value = UUID()
        return value
    }
    func isCurrent(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.value == value
    }
}
