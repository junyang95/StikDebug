import Foundation
import Network

/// One-shot, loopback-only delivery. The caller must supply a public-only configuration profile.
final class CertificateProfileServer {
    enum ServerError: Error, Equatable { case invalidProfileSize, alreadyStarted, stopped, missingPort }

    private enum State { case idle, starting, serving, stopped }
    private final class Client {
        let connection: NWConnection
        var header = Data()
        var timer: DispatchSourceTimer?
        var sending = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "com.jy.stikdebug.certificate-profile")
    private let profile: Data
    private let lifetime: TimeInterval
    private let headerTimeout: TimeInterval
    private let path = "/\(UUID().uuidString)/StikDebug-WLOC.mobileconfig"
    private var state = State.idle
    private var listener: NWListener?
    private var expiry: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var host: String?
    private var startCompletion: ((Result<URL, Error>) -> Void)?

    init(profile: Data) {
        self.profile = profile
        lifetime = 120
        headerTimeout = 5
    }

    #if DEBUG
    /// Short deadlines for local tests; production callers use init(profile:).
    init(profile: Data, testingLifetime: TimeInterval, testingHeaderTimeout: TimeInterval) {
        self.profile = profile
        lifetime = testingLifetime
        headerTimeout = testingHeaderTimeout
    }
    #endif

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard state == .idle else {
                completion(.failure(state == .stopped ? ServerError.stopped : ServerError.alreadyStarted))
                return
            }
            guard !profile.isEmpty, profile.count <= 65_536 else {
                state = .stopped
                completion(.failure(ServerError.invalidProfileSize))
                return
            }
            state = .starting
            startCompletion = completion
            // Absolute lifetime starts now, not on the first connection or successful read.
            expiry = makeTimer(after: lifetime) { [weak self] in self?.stopOnQueue() }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] update in
                    guard let self, self.state != .stopped else { return }
                    switch update {
                    case .ready:
                        guard self.state == .starting else { return }
                        guard let port = listener?.port?.rawValue else {
                            self.stopOnQueue(error: ServerError.missingPort)
                            return
                        }
                        let host = "127.0.0.1:\(port)"
                        self.host = host
                        self.state = .serving
                        let callback = self.startCompletion
                        self.startCompletion = nil
                        callback?(.success(URL(string: "http://\(host)\(self.path)")!))
                    case .failed(let error): self.stopOnQueue(error: error)
                    case .cancelled: self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
                listener.start(queue: queue)
            } catch { stopOnQueue(error: error) }
        }
    }

    /// Completion runs after the serial queue has cancelled its listener, clients and timers.
    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            stopOnQueue()
            completion()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard state == .serving, clients.count < 2 else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        client.timer = makeTimer(after: headerTimeout) { [weak self] in self?.close(id) }
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        read(id)
    }

    private func read(_ id: UUID) {
        guard let client = clients[id], !client.sending else { return }
        let remaining = 4_096 - client.header.count
        guard remaining > 0 else { close(id); return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, eof, error in
            guard let self, let client = self.clients[id], !client.sending else { return }
            guard error == nil else { self.close(id); return }
            if let data { client.header.append(data) }
            if let end = client.header.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == client.header.endIndex, self.validHeader(client.header) else {
                    self.close(id)
                    return
                }
                // A complete GET followed by FIN is valid: only the client's write side ended.
                self.sendProfile(id)
            } else if eof || client.header.count >= 4_096 {
                self.close(id)
            } else {
                self.read(id)
            }
        }
    }

    private func validHeader(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .ascii), let host else { return false }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "GET \(path) HTTP/1.1", lines.count >= 4 else { return false }
        var foundHost = false
        var foundLength = false
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return false }
            let name = line[..<colon]
            let token = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            guard name.allSatisfy({ token.contains($0) }) else { return false }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return false }
            switch name.lowercased() {
            case "host":
                guard !foundHost, value == host else { return false }
                foundHost = true
            case "content-length":
                guard !foundLength, value == "0" else { return false }
                foundLength = true
            case "transfer-encoding": return false
            default: break
            }
        }
        return foundHost
    }

    private func sendProfile(_ id: UUID) {
        guard let client = clients[id], state == .serving else { return }
        client.sending = true
        client.timer?.cancel()
        // Bound a stalled response as well as a slow header; absolute expiry remains active.
        client.timer = makeTimer(after: headerTimeout) { [weak self] in self?.close(id) }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Disposition: attachment; filename=\"StikDebug-WLOC.mobileconfig\"\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(profile.count)\r\n\r\n"
        client.connection.send(content: Data(header.utf8) + profile, contentContext: .finalMessage,
                               isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, self.clients[id] != nil else { return }
            if error == nil { self.stopOnQueue() } else { self.close(id) }
        })
    }

    private func makeTimer(after seconds: TimeInterval, action: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.cancel()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    private func stopOnQueue(error: Error = ServerError.stopped) {
        guard state != .stopped else { return }
        state = .stopped
        expiry?.cancel()
        expiry = nil
        listener?.stateUpdateHandler = nil
        // Leave the weak accept handler installed while cancellation drains: a TCP peer may
        // already be connected but its accepted NWConnection has not reached our queue yet.
        // accept() rejects that late delivery because state is now stopped.
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { close(id) }
        let callback = startCompletion
        startCompletion = nil
        callback?(.failure(error))
    }

    deinit {
        expiry?.cancel()
        listener?.cancel()
        for client in clients.values {
            client.timer?.cancel()
            client.connection.cancel()
        }
    }
}
