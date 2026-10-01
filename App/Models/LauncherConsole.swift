import Combine
import Foundation
#if !targetEnvironment(simulator)
import StikJIT
#endif

/// Buffers before crossing to MainActor so fast syslog never creates an unbounded task queue.
private final class ConsoleLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var deliveryPending = false
    private var accepting = true
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        pending.append(String(line.prefix(4096)))
        if pending.count > 300 { pending.removeFirst(pending.count - 300) }
    }
    func take() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard !deliveryPending, !pending.isEmpty else { return nil }
        deliveryPending = true
        let lines = pending; pending.removeAll(keepingCapacity: true)
        return lines
    }
    func delivered() { lock.lock(); deliveryPending = false; lock.unlock() }
    func accept(_ enabled: Bool) {
        lock.lock(); accepting = enabled; pending.removeAll(keepingCapacity: true); lock.unlock()
    }
}

/// The reader owns its FFI handles until the blocking read actually returns.
@MainActor
final class LauncherConsole: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var errorMessage: String?
    @Published var isPaused = false { didSet { buffer?.accept(!isPaused && !isStopping) } }
    private var generation = UUID()
    private var buffer: ConsoleLineBuffer?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.stik.launcher.console", qos: .utility)
    #if !targetEnvironment(simulator)
    private var session: DeviceLogSession?
    #endif

    func start(pairingFile: URL) {
        guard !isRunning else { return }
        errorMessage = nil
        #if targetEnvironment(simulator)
        errorMessage = NSLocalizedString("error.device_required", comment: "")
        #else
        let reader = DeviceLogSession()
        let buffer = ConsoleLineBuffer()
        self.buffer = buffer
        session = reader
        isRunning = true
        isStopping = false
        isPaused = false
        let token = UUID()
        generation = token
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let batch = buffer.take() else { return }
            Task { @MainActor [weak self] in
                defer { buffer.delivered() }
                guard let self, self.generation == token, !self.isStopping, !self.isPaused else { return }
                self.lines.append(contentsOf: batch)
                if self.lines.count > 1500 { self.lines.removeFirst(self.lines.count - 1500) }
            }
        }
        self.timer = timer
        timer.resume()
        queue.async { [weak self] in
            let failure: String?
            do {
                try reader.run(pairingFile: pairingFile) { line in buffer.append(line) }
                failure = nil
            } catch { failure = error.localizedDescription }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if !self.isStopping { self.errorMessage = failure }
                self.timer?.cancel(); self.timer = nil
                self.buffer?.accept(false); self.buffer = nil
                self.session = nil
                self.isRunning = false
                self.isStopping = false
            }
        }
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
        buffer?.accept(false)
        timer?.cancel(); timer = nil
        #if !targetEnvironment(simulator)
        session?.cancel()
        #endif
    }
    func clear() { lines.removeAll(); buffer?.accept(!isPaused && !isStopping) }
}
