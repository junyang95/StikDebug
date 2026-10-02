import Foundation

private final class FakeWiFiPathMonitor: WiFiPathMonitoring {
    private(set) var started = false
    private(set) var cancelled = false
    private var onUpdate: (@Sendable (WiFiRequirementState) -> Void)?

    func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (WiFiRequirementState) -> Void) {
        started = true
        self.onUpdate = onUpdate
    }

    func cancel() { cancelled = true }

    // Intentionally deliver even after cancellation, as an already queued OS
    // callback can outlive the monitor that produced it.
    func send(_ state: WiFiRequirementState) { onUpdate?(state) }
}

@main
enum WiFiRequirementTests {
    @MainActor
    static func main() async {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        expect(!WiFiRequirementState.checking.isAvailable, "Unknown state must block device work")
        expect(!WiFiRequirementState.unavailable.isAvailable, "Unavailable Wi-Fi must block device work")
        expect(WiFiRequirementState.available.isAvailable, "A verified usable Wi-Fi path permits work")
        expect(WiFiRequirementState.evaluate(isSatisfied: true, usesWiFi: false) == .unavailable,
               "Cellular, Ethernet, and VPN-only connectivity must not satisfy Wi-Fi")
        expect(WiFiRequirementState.evaluate(isSatisfied: false, usesWiFi: true) == .unavailable,
               "An unusable Wi-Fi interface must not satisfy Wi-Fi")
        expect(WiFiRequirementState.evaluate(isSatisfied: false, usesWiFi: false) == .unavailable,
               "Offline state must not satisfy Wi-Fi")
        expect(WiFiRequirementState.evaluate(isSatisfied: true, usesWiFi: true) == .available,
               "Wi-Fi readiness requires both a usable path and the Wi-Fi interface")

        var drivers: [FakeWiFiPathMonitor] = []
        var monitor: WiFiRequirementMonitor? = WiFiRequirementMonitor {
            let driver = FakeWiFiPathMonitor()
            drivers.append(driver)
            return driver
        }
        expect(drivers.count == 1 && drivers[0].started, "Initialization starts Wi-Fi observation")
        expect(monitor?.state == .checking, "Initialization fails closed before the first callback")
        drivers[0].send(.available)
        await settleCallbacks()
        expect(monitor?.isAvailable == true, "Usable Wi-Fi publishes availability")

        monitor?.refresh()
        expect(drivers[0].cancelled, "Refresh cancels the old OS monitor")
        expect(drivers.count == 2 && drivers[1].started, "Refresh creates a fresh monitor")
        expect(monitor?.state == .checking, "Refresh discards stale availability immediately")
        drivers[0].send(.available)
        await settleCallbacks()
        expect(monitor?.state == .checking, "A stale available callback cannot unlock work")
        drivers[1].send(.unavailable)
        await settleCallbacks()
        expect(monitor?.state == .unavailable, "The new unavailable answer is published")
        drivers[0].send(.available)
        await settleCallbacks()
        expect(monitor?.state == .unavailable, "Old-generation availability cannot override current state")
        drivers[1].send(.available)
        await settleCallbacks()
        expect(monitor?.isAvailable == true, "Wi-Fi recovery unlocks work")
        drivers[1].send(.unavailable)
        await settleCallbacks()
        expect(monitor?.isAvailable == false, "Wi-Fi loss locks work again")

        monitor?.stop()
        expect(drivers[1].cancelled && monitor?.state == .checking, "Stopping cancels observation and invalidates state")
        drivers[1].send(.available)
        await settleCallbacks()
        expect(monitor?.state == .checking, "A stopped monitor ignores late callbacks")
        monitor?.refresh()
        expect(drivers.count == 3 && drivers[2].started, "A stopped monitor can be restarted")
        expect(monitor?.state == .checking, "Restart also fails closed")
        monitor = nil
        expect(drivers[2].cancelled, "Releasing the owner cancels observation")

        print("\(checks) Wi-Fi requirement checks passed")
    }

    private static func settleCallbacks() async {
        // Let the driver's callback cross onto the main actor. This does not
        // depend on the host computer's current network configuration.
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
