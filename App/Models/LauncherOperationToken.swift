import Foundation

/// Cancellation crosses the main actor and blocking device queues. It prevents
/// a queued command from starting after its connection or authorization expired.
final class LauncherOperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var workBegan = false
    private var leftForeground = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// Atomically admits device work, so leaving the foreground during an
    /// authorization wait cannot race a later queued command into execution.
    func beginWork() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        workBegan = true
    }

    /// Existing bounded device work may finish in the background. Work still
    /// waiting for admission is cancelled, and no late foreground-only action
    /// may be published by this token, even if the app subsequently returns.
    @discardableResult
    func leaveForeground() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        leftForeground = true
        guard workBegan else { cancelled = true; return true }
        return false
    }

    var allowsForegroundCompletion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !leftForeground && !cancelled
    }

    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}
