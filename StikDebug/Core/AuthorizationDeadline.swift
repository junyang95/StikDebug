import Foundation

enum AuthorizationOperationError: Error { case timedOut, deviceBusy }

/// Unlike a task-group timeout, this does not wait for non-cancellable C I/O to exit.
func withAuthorizationDeadline<Value>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let completion = AuthorizationCompletion<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.attach(continuation)
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    let result = try await operation()
                    completion.finish(.success(result))
                } catch { completion.finish(.failure(error)) }
            }
            let timeout = DispatchWorkItem {
                completion.finish(.failure(AuthorizationOperationError.timedOut))
            }
            completion.setCleanup { worker.cancel(); timeout.cancel() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
        }
    } onCancel: {
        completion.finish(.failure(CancellationError()))
    }
}

private final class AuthorizationCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cleanup: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setCleanup(_ cleanup: @escaping () -> Void) {
        lock.lock()
        let isFinished = result != nil
        if !isFinished { self.cleanup = cleanup }
        lock.unlock()
        if isFinished { cleanup() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let cleanup = cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
        continuation?.resume(with: result)
    }
}

/// At most one physical device read. Timing out never queues another blocked C call.
final class AuthorizationDeviceReader: @unchecked Sendable {
    static let shared = AuthorizationDeviceReader()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.pikminhelper.vip-device", qos: .userInitiated)
    private var running = false

    func read(_ operation: @escaping @Sendable () throws -> String) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !running else {
                lock.unlock()
                continuation.resume(throwing: AuthorizationOperationError.deviceBusy)
                return
            }
            running = true
            lock.unlock()
            queue.async {
                let result = Result { try operation() }
                self.lock.lock()
                self.running = false
                self.lock.unlock()
                continuation.resume(with: result)
            }
        }
    }
}
