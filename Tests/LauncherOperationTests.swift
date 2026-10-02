import Foundation

private enum ProbeError: Error, Equatable { case launch, enable, resume }

/// Only test instrumentation is shared between queues; keep it synchronized so
/// the cancellation scenarios exercise production synchronization without races.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var storedError: Error?

    func append(_ event: String) {
        lock.lock(); storedEvents.append(event); lock.unlock()
    }
    func record(_ error: Error) {
        lock.lock(); storedError = error; lock.unlock()
    }
    var events: [String] {
        lock.lock(); defer { lock.unlock() }; return storedEvents
    }
    var error: Error? {
        lock.lock(); defer { lock.unlock() }; return storedError
    }
}

@main
enum LauncherOperationTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            count += 1
        }
        func cancelled(_ action: () throws -> Void, _ name: String) {
            do { try action(); preconditionFailure(name) }
            catch is CancellationError { count += 1 }
            catch { preconditionFailure("\(name): unexpected \(error)") }
        }
        func wait(_ gate: DispatchSemaphore, _ name: String) {
            precondition(gate.wait(timeout: .now() + 5) == .success, "Timed out: \(name)")
        }

        let pending = LauncherOperationToken()
        let authorizationStarted = DispatchSemaphore(value: 0)
        let authorizationReturns = DispatchSemaphore(value: 0)
        let waitingFinished = DispatchSemaphore(value: 0)
        let waitingProbe = Probe()
        DispatchQueue.global().async {
            authorizationStarted.signal()
            guard authorizationReturns.wait(timeout: .now() + 5) == .success else {
                preconditionFailure("Authorization test was not released")
            }
            do { try pending.beginWork(); waitingProbe.append("device command") }
            catch { waitingProbe.record(error) }
            waitingFinished.signal()
        }
        wait(authorizationStarted, "authorization started")
        check(pending.leaveForeground(), "Background cancels authorization still waiting")
        authorizationReturns.signal()
        wait(waitingFinished, "late authorization returned")
        check(waitingProbe.events.isEmpty && waitingProbe.error is CancellationError,
              "A late authorization cannot admit a device command")
        check(!pending.allowsForegroundCompletion, "Late console completion is not admitted")

        let started = LauncherOperationToken()
        try started.beginWork()
        check(!started.leaveForeground(), "Background preserves already admitted bounded work")
        try started.check()
        check(!started.allowsForegroundCompletion, "Admitted work cannot start a console after backgrounding")
        try started.beginWork()
        check(!started.allowsForegroundCompletion, "Reusing an admitted token cannot erase foreground history")
        started.cancel()
        cancelled({ try started.check() }, "Connection invalidation still cancels admitted work")
        cancelled({ try started.beginWork() }, "An explicitly cancelled token cannot admit work")

        let fresh = LauncherOperationToken()
        check(fresh.allowsForegroundCompletion, "Current foreground admission may complete")
        try fresh.beginWork()
        check(fresh.allowsForegroundCompletion, "Starting a command preserves its foreground admission")
        fresh.cancel()
        check(!fresh.allowsForegroundCompletion, "Explicit cancellation blocks foreground completion")

        let launchToken = LauncherOperationToken()
        try launchToken.beginWork()
        let launched = DispatchSemaphore(value: 0)
        let returnFromLaunch = DispatchSemaphore(value: 0)
        let launchFinished = DispatchSemaphore(value: 0)
        let launchProbe = Probe()
        DispatchQueue.global().async {
            do {
                _ = try LauncherApplicationLaunch.run(enableJIT: true, launch: { suspended in
                    launchProbe.append(suspended ? "launch suspended" : "launch running")
                    launched.signal()
                    guard returnFromLaunch.wait(timeout: .now() + 5) == .success else {
                        preconditionFailure("Blocking launch test was not released")
                    }
                    return 42
                }, checkCancelled: { try launchToken.check() }, enable: { pid in
                    launchProbe.append("enable \(pid)")
                }, resume: { pid in
                    launchProbe.append("resume \(pid)")
                })
            } catch { launchProbe.record(error) }
            launchFinished.signal()
        }
        wait(launched, "native launch entered")
        launchToken.cancel()
        returnFromLaunch.signal()
        wait(launchFinished, "cancelled launch cleanup")
        check(launchProbe.events == ["launch suspended", "resume 42"],
              "Cancellation during launch skips enable and resumes once")
        check(launchProbe.error is CancellationError, "Launch cancellation propagates")

        var events: [String] = []
        do {
            _ = try LauncherApplicationLaunch.run(enableJIT: true, launch: { _ in
                events.append("launch"); return 43
            }, checkCancelled: {}, enable: { _ in
                events.append("enable"); throw ProbeError.enable
            }, resume: { _ in
                events.append("resume"); throw ProbeError.resume
            })
            preconditionFailure("Enable failure should propagate")
        } catch {
            check(error as? ProbeError == .enable, "Failed recovery preserves the original enable error")
        }
        check(events == ["launch", "enable", "resume"], "Enable failure attempts recovery exactly once")

        var cancellationChecks = 0
        events = []
        cancelled({
            _ = try LauncherApplicationLaunch.run(enableJIT: true, launch: { _ in 44 }, checkCancelled: {
                cancellationChecks += 1
                if cancellationChecks == 2 { throw CancellationError() }
            }, enable: { _ in events.append("enable") }, resume: { _ in
                events.append("resume"); throw ProbeError.resume
            })
        }, "Failed recovery preserves the original cancellation")
        check(events == ["resume"], "Cancellation cleanup does not accidentally enable JIT")

        events = []
        do {
            _ = try LauncherApplicationLaunch.run(enableJIT: true, launch: { _ in
                throw ProbeError.launch
            }, checkCancelled: {}, enable: { _ in events.append("enable") }, resume: { _ in events.append("resume") })
            preconditionFailure("Launch failure should propagate")
        } catch {
            check(error as? ProbeError == .launch && events.isEmpty,
                  "A failed launch never resumes an unknown process")
        }

        let cancelledBeforeLaunch = LauncherOperationToken()
        cancelledBeforeLaunch.cancel()
        events = []
        cancelled({
            _ = try LauncherApplicationLaunch.run(enableJIT: true, launch: { _ in
                events.append("launch"); return 45
            }, checkCancelled: { try cancelledBeforeLaunch.check() }, enable: { _ in
                events.append("enable")
            }, resume: { _ in events.append("resume") })
        }, "Cancellation before launch propagates")
        check(events.isEmpty, "Cancelled queued work never launches or resumes anything")

        events = []
        let jitPID = try LauncherApplicationLaunch.run(enableJIT: true, launch: { suspended in
            events.append(suspended ? "launch suspended" : "launch running"); return 46
        }, checkCancelled: {}, enable: { pid in events.append("enable \(pid)") }, resume: { _ in events.append("resume") })
        check(jitPID == 46 && events == ["launch suspended", "enable 46"], "Successful JIT preserves normal completion")
        events = []
        let plainPID = try LauncherApplicationLaunch.run(enableJIT: false, launch: { suspended in
            events.append(suspended ? "launch suspended" : "launch running"); return 47
        }, checkCancelled: {}, enable: { _ in events.append("enable") }, resume: { _ in events.append("resume") })
        check(plainPID == 47 && events == ["launch running"], "Ordinary launch never suspends or enables JIT")

        print("\(count) launcher operation tests passed")
    }
}
