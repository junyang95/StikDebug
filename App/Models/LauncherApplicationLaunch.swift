import Foundation

/// Keeps cancellation between application launch and JIT activation recoverable.
/// Native calls already in progress are allowed to return before cleanup runs.
enum LauncherApplicationLaunch {
    static func run(
        enableJIT: Bool,
        launch: (_ startSuspended: Bool) throws -> Int32,
        checkCancelled: () throws -> Void,
        enable: (_ pid: Int32) throws -> Void,
        resume: (_ pid: Int32) throws -> Void
    ) throws -> Int32 {
        try checkCancelled()
        let pid = try launch(enableJIT)
        guard enableJIT else { return pid }

        do {
            // Launch can block while a connection is invalidated. Check again
            // before opening a separate JIT session for its suspended process.
            try checkCancelled()
            try enable(pid)
        } catch {
            // Recovery must not depend on the cancelled admission token, and a
            // recovery error must not hide the original cancellation/JIT error.
            try? resume(pid)
            throw error
        }
        return pid
    }
}
