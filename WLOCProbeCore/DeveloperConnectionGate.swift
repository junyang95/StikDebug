import Foundation

/// Protects the app FFI boundary, including work already enqueued when the UI changes mode.
enum DeveloperConnectionGate {
    static let blockedStatus: Int32 = -90
    static let experimentKey = "wlocProbeRestoreConnection"
    private static let simulationKey = "developerSimulationNeedsRestore"
    private static let lock = NSLock()
    private static var blocked = UserDefaults.standard.object(forKey: experimentKey) != nil
    private static var operations = 0

    static var isBlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked
    }

    static var needsRestore: Bool { UserDefaults.standard.bool(forKey: simulationKey) }

    static func beginProbe() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !blocked, operations == 0, !needsRestore else { return false }
        blocked = true
        return true
    }

    static func setBlocked(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        blocked = value
    }

    static func beginDeveloperOperation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !blocked else { return false }
        operations += 1
        return true
    }

    static func endDeveloperOperation() {
        lock.lock(); defer { lock.unlock() }
        operations -= 1
    }

    static func performLocationCommand(clear: Bool, _ operation: () -> Int32) -> Int32 {
        lock.lock()
        guard !blocked else { lock.unlock(); return blockedStatus }
        operations += 1
        if !clear { UserDefaults.standard.set(true, forKey: simulationKey) }
        lock.unlock()
        let code = operation()
        lock.lock()
        operations -= 1
        if clear && code == 0 { UserDefaults.standard.set(false, forKey: simulationKey) }
        lock.unlock()
        return code
    }
}
