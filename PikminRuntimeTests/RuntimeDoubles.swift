import CoreLocation
import Foundation

// Host doubles replace device/HealthKit/ActivityKit I/O. The controllers are copied verbatim.
extension String { var localized: String { self } }
enum DeveloperConnectionGate { static var isBlocked: Bool { false } }
enum DeviceConnectionContext { static let targetIPAddress = "127.0.0.1" }
enum PairingFileStore { static let url = URL(fileURLWithPath: "/tmp/test-pairing"); static func prepareURL() -> URL { url }; static let didChangeNotification = Notification.Name("PairingChanged"); static func stateSignature() -> String { "test-pairing" } }
enum LocationSimulationCommandQueue { static let shared = DispatchQueue(label: "test.location") }
enum LocationSimulationStatus { static let unauthorized: Int32 = 13 }
@MainActor final class EnvironmentPreflightService { static let shared = EnvironmentPreflightService(); var canStartSession = true }
final class BackgroundAudioManager { static let shared = BackgroundAudioManager(); var leases = 0; func requestStart() { leases += 1 }; func requestStop() { leases -= 1 } }
final class BackgroundLocationManager { static let shared = BackgroundLocationManager(); var leases = 0; func requestStart() { leases += 1 }; func requestStop() { leases -= 1 } }
@MainActor final class HealthStepService {
    static let shared = HealthStepService()
    var authorize: (() async -> Bool)?
    var write: (() async -> Bool)?
    func requestAuthorization() async -> Bool { await authorize?() ?? true }
    func writeSteps(_ count: Int, from: Date, to: Date, sessionID: UUID) async -> Bool { await write?() ?? true }
}
@MainActor final class LiveActivityManager {
    static let shared = LiveActivityManager()
    func start(config: WalkingSessionConfig, coordinate: CLLocationCoordinate2D, phase: WalkingSessionPhase) async {}
    func end(phase: WalkingSessionPhase, steps: Int, distanceMeters: Double, speedKilometersPerHour: Double, coordinate: CLLocationCoordinate2D?) async {}
    func update(phase: WalkingSessionPhase, steps: Int, distanceMeters: Double, speedKilometersPerHour: Double, coordinate: CLLocationCoordinate2D, force: Bool) async {}
}
@MainActor final class SessionNotificationService {
    static let shared = SessionNotificationService()
    func requestAuthorizationIfNeeded() {}; func notifyConnectionDropped() {}; func notifyReconnected() {}; func notifyReconnectFailed() {}
}
@MainActor final class EmbeddedVPNService {
    struct Status { var isConnected = true }
    static let shared = EmbeddedVPNService(); var status = Status()
    func connect() async {}
}
enum RecentLocationStore { static func record(_ p: CLLocationCoordinate2D, name: String) {} }
final class LogManager { static let shared = LogManager(); func addInfoLog(_ s: String) {}; func addErrorLog(_ s: String) {} }
final class DeviceCommands: @unchecked Sendable {
    static let shared = DeviceCommands()
    private let lock = NSLock()
    private var commands: [String] = []
    func append(_ command: String) { lock.lock(); defer { lock.unlock() }; commands.append(command) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return commands }
    func reset() { lock.lock(); defer { lock.unlock() }; commands = [] }
}
func simulate_location(_ ip: String, _ lat: Double, _ lon: Double, _ pairing: String) -> Int32 {
    guard VipLocationGate.shared.allows() else { return 13 }
    DeviceCommands.shared.append("set")
    return 0
}
func clear_simulated_location(_ ip: String, _ pairing: String) -> Int32 { DeviceCommands.shared.append("clear"); return 0 }

func readAuthorizationDeviceUDID(deviceIP: String, pairingFile: String) throws -> String { "test-device" }
