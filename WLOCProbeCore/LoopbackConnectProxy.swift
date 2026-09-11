import Foundation
import Network

/// TLS is never terminated here. All mutable state and connection callbacks use one queue.
final class LoopbackConnectProxy {
    typealias UpstreamFactory = (String) -> NWConnection
    private let queue = DispatchQueue(label: "com.jy.stikdebug.wloc-probe")
    private var listener: NWListener?
    private var clients: [UUID: ConnectRelay] = [:]
    private var state = ProbeSnapshot(mode: .wlocProbe)
    private var startCompletion: ((Result<UInt16, Error>) -> Void)?
    private var fatalFailure: ((Error) -> Void)?
    private let upstream: UpstreamFactory
    private let handshakeTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    #if DEBUG
    private var debugTimer: DispatchSourceTimer?
    private var debugCounters = ProbeDebugCounters()
    /// Test-only observation hook. Set before start; callbacks run on the proxy queue.
    var debugObserver: ((ProbeDebugRecord) -> Void)?
    #endif

    init(
        handshakeTimeout: TimeInterval = WLOCProbePolicy.handshakeTimeout,
        idleTimeout: TimeInterval = WLOCProbePolicy.idleTimeout,
        upstream: @escaping UpstreamFactory = { NWConnection(host: NWEndpoint.Host($0), port: 443, using: .tcp) }
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.idleTimeout = idleTimeout
        self.upstream = upstream
    }

    func start(onFailure: @escaping (Error) -> Void, completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            guard listener == nil else {
                completion(.failure(ProxyError.alreadyStarted))
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                self.startCompletion = completion
                self.fatalFailure = onFailure
                listener.stateUpdateHandler = { [weak self] status in
                    guard let self else { return }
                    switch status {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        self.state.port = port
                        self.state.listening = true
                        #if DEBUG
                        self.startDebugTelemetry()
                        #endif
                        let callback = self.startCompletion
                        self.startCompletion = nil
                        callback?(.success(port))
                    case .failed(let error):
                        self.state.lastError = "本机监听失败"
                        self.state.listening = false
                        if let callback = self.startCompletion {
                            self.startCompletion = nil
                            callback(.failure(error))
                        } else {
                            self.fatalFailure?(error)
                        }
                        self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func snapshot(reset: Bool = false, completion: @escaping (ProbeSnapshot) -> Void) {
        queue.async { [self] in
            if reset {
                // Close old tunnels before resetting so later bytes cannot masquerade as a new observation.
                for client in Array(clients.values) {
                    #if DEBUG
                    client.debugCloseReason = .reset
                    #endif
                    client.close()
                }
                state.hosts = [:]
                state.lastError = nil
                state.resetAt = Date()
                #if DEBUG
                debugCounters = ProbeDebugCounters()
                emitDebug(.reset)
                #endif
            }
            state.activeConnections = clients.count
            completion(state)
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            stopOnQueue()
            completion()
        }
    }

    private func stopOnQueue() {
        #if DEBUG
        debugTimer?.cancel()
        debugTimer = nil
        #endif
        let callback = startCompletion
        startCompletion = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        state.listening = false
        state.port = nil
        for client in Array(clients.values) {
            #if DEBUG
            client.debugCloseReason = .stop
            #endif
            client.close()
        }
        clients.removeAll()
        state.activeConnections = 0
        #if DEBUG
        emitDebug(.stopped)
        #endif
        callback?(.failure(ProxyError.stopped))
    }

    #if DEBUG
    private func startDebugTelemetry() {
        debugTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.emitDebug(.snapshot) }
        debugTimer = timer
        timer.resume()
        emitDebug(.ready)
    }

    private func emitDebug(_ event: ProbeDebugRecord.Event) {
        var snapshot = state
        snapshot.activeConnections = clients.count
        publishDebug(ProbeDebugRecord(source: .tunnel, event: event,
                                     snapshot: ProbeDebugSnapshot(snapshot), counters: debugCounters))
    }

    private func publishDebug(_ record: ProbeDebugRecord) {
        ProbeDebugLog.emit(record)
        debugObserver?(record)
    }
    #endif

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        #if DEBUG
        let trace = ProbeConnectionTrace(id: id, sessionID: state.sessionID,
                                        resetAt: state.resetAt.timeIntervalSince1970) { [weak self] value in
            guard let self else { return }
            self.debugCounters.observe(value)
            self.publishDebug(ProbeDebugRecord(source: .tunnel, event: .connection,
                                              counters: self.debugCounters, connection: value))
        }
        trace.begin()
        #endif
        guard clients.count < WLOCProbePolicy.maximumConnections else {
            connection.cancel()
            state.lastError = "连接数达到上限"
            #if DEBUG
            trace.finish(.connectionLimit)
            #endif
            return
        }
        let relay = ConnectRelay(
            client: connection, queue: queue, upstreamFactory: upstream,
            handshakeTimeout: handshakeTimeout, idleTimeout: idleTimeout,
            onAccepted: { [weak self] host in
                guard let self else { return }
                var activity = self.state.hosts[host, default: ProbeHostActivity()]
                activity.connections += 1
                activity.lastActivity = Date()
                self.state.hosts[host] = activity
            },
            onBytes: { [weak self] host, count, upload in
                guard let self else { return }
                var activity = self.state.hosts[host, default: ProbeHostActivity()]
                if upload { activity.uploadedBytes += Int64(count) }
                else { activity.downloadedBytes += Int64(count) }
                activity.lastActivity = Date()
                self.state.hosts[host] = activity
            },
            onClosed: { [weak self] error in
                self?.clients.removeValue(forKey: id)
                if let error { self?.state.lastError = error }
            }
        )
        #if DEBUG
        relay.debugTrace = trace
        #endif
        clients[id] = relay
        relay.start()
    }

    enum ProxyError: Error { case alreadyStarted, stopped }
}

private final class ConnectRelay {
    private let client: NWConnection
    private let queue: DispatchQueue
    private let upstreamFactory: LoopbackConnectProxy.UpstreamFactory
    private let handshakeTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let onAccepted: (String) -> Void
    private let onBytes: (String, Int, Bool) -> Void
    private let onClosed: (String?) -> Void
    private var upstream: NWConnection?
    private var parser = ConnectRequestParser()
    private var host = ""
    private var closed = false
    private var deadline: DispatchSourceTimer?
    private var completedDirections = 0
    #if DEBUG
    var debugTrace: ProbeConnectionTrace?
    var debugCloseReason: ProbeDebugConnection.Reason?
    #endif

    init(client: NWConnection, queue: DispatchQueue,
         upstreamFactory: @escaping LoopbackConnectProxy.UpstreamFactory,
         handshakeTimeout: TimeInterval, idleTimeout: TimeInterval,
         onAccepted: @escaping (String) -> Void,
         onBytes: @escaping (String, Int, Bool) -> Void,
         onClosed: @escaping (String?) -> Void) {
        self.client = client
        self.queue = queue
        self.upstreamFactory = upstreamFactory
        self.handshakeTimeout = handshakeTimeout
        self.idleTimeout = idleTimeout
        self.onAccepted = onAccepted
        self.onBytes = onBytes
        self.onClosed = onClosed
    }

    func start() {
        armTimeout(handshakeTimeout, message: "CONNECT 或上游连接超时")
        client.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.readHeader()
            case .failed(let error):
                #if DEBUG
                self.debugTrace?.failure(.clientState, side: .client, error: error)
                #endif
                self.close(error: "客户端连接失败")
            case .cancelled: self.close()
            default: break
            }
        }
        client.start(queue: queue)
    }

    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: WLOCProbePolicy.chunkBytes) { [weak self] data, _, eof, error in
            guard let self, !self.closed else { return }
            if let error {
                #if DEBUG
                self.debugTrace?.failure(.headerRead, side: .client, error: error,
                                         availableBytes: data?.count ?? 0, endOfStream: eof)
                #endif
                self.close(error: "CONNECT 读取失败"); return
            }
            #if DEBUG
            if eof {
                self.debugTrace?.readEOF(upload: true)
                self.debugCloseReason = .clientEOF
            }
            #endif
            do {
                if let data, let request = try self.parser.append(data) {
                    if eof { self.close(); return }
                    self.connect(request)
                } else if eof { self.close() }
                else { self.readHeader() }
            } catch let error as ConnectRequestError {
                #if DEBUG
                self.debugCloseReason = .rejected
                #endif
                self.client.send(content: error.response, completion: .contentProcessed { [weak self] _ in
                    self?.close(error: "CONNECT 请求被拒绝")
                })
            } catch { self.close(error: "CONNECT 解析失败") }
        }
    }

    private func connect(_ request: ConnectRequest) {
        host = request.host
        #if DEBUG
        debugTrace?.targetValidated(host)
        #endif
        onAccepted(host)
        let remote = upstreamFactory(host)
        upstream = remote
        remote.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                #if DEBUG
                self.debugTrace?.upstreamReady()
                #endif
                remote.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        #if DEBUG
                        self?.debugTrace?.failure(.upstreamState, side: .upstream, error: error)
                        #endif
                        self?.close(error: "上游连接中断")
                    }
                }
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    guard error == nil else {
                        #if DEBUG
                        self.debugTrace?.failure(.connectReply, side: .client, error: error)
                        #endif
                        self.close(error: "CONNECT 应答失败"); return
                    }
                    #if DEBUG
                    self.debugTrace?.relayReady()
                    #endif
                    self.touch()
                    self.relay(from: remote, to: self.client, upload: false)
                    if request.initialPayload.isEmpty {
                        self.relay(from: self.client, to: remote, upload: true)
                    } else {
                        remote.send(content: request.initialPayload, completion: .contentProcessed { [weak self] error in
                            guard let self, !self.closed else { return }
                            guard error == nil else {
                                #if DEBUG
                                self.debugTrace?.failure(.initialUpload, side: .upstream, error: error)
                                #endif
                                self.close(error: "上游发送失败"); return
                            }
                            #if DEBUG
                            self.debugTrace?.forwarded(request.initialPayload.count, upload: true)
                            #endif
                            self.onBytes(self.host, request.initialPayload.count, true)
                            self.relay(from: self.client, to: remote, upload: true)
                        })
                    }
                })
            case .failed(let error), .waiting(let error):
                #if DEBUG
                if case .waiting = state {
                    self.debugTrace?.failure(.upstreamWaiting, side: .upstream, error: error)
                } else {
                    self.debugTrace?.failure(.upstreamConnect, side: .upstream, error: error)
                }
                #endif
                remote.stateUpdateHandler = nil
                self.client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
                    self?.close(error: "无法直接连接上游")
                })
            default: break
            }
        }
        remote.start(queue: queue)
    }

    private func relay(from source: NWConnection, to destination: NWConnection, upload: Bool) {
        guard !closed else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: WLOCProbePolicy.chunkBytes) { [weak self] data, _, eof, error in
            guard let self, !self.closed else { return }
            guard error == nil else {
                #if DEBUG
                self.debugTrace?.failure(.relayRead, side: upload ? .client : .upstream, error: error,
                                         availableBytes: data?.count ?? 0, endOfStream: eof)
                #endif
                self.close(error: "透传连接中断"); return
            }
            #if DEBUG
            if eof { self.debugTrace?.readEOF(upload: upload) }
            #endif
            if let data, !data.isEmpty {
                // At most one chunk per direction in flight; read again only after the write completes.
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    guard error == nil else {
                        #if DEBUG
                        self.debugTrace?.failure(.relayWrite, side: upload ? .upstream : .client, error: error)
                        #endif
                        self.close(error: "透传发送失败"); return
                    }
                    #if DEBUG
                    self.debugTrace?.forwarded(data.count, upload: upload)
                    #endif
                    self.onBytes(self.host, data.count, upload)
                    self.touch()
                    if eof { self.finishDirection(destination) }
                    else { self.relay(from: source, to: destination, upload: upload) }
                })
            } else if eof { self.finishDirection(destination) }
            else { self.relay(from: source, to: destination, upload: upload) }
        }
    }

    private func finishDirection(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error {
                #if DEBUG
                self.debugTrace?.failure(.halfClose, side: destination === self.client ? .client : .upstream, error: error)
                self.debugCloseReason = .transportError
                #endif
                self.close(); return
            }
            self.completedDirections += 1
            if self.completedDirections == 2 { self.close() }
        })
    }

    private func touch() { armTimeout(idleTimeout, message: "透传连接空闲超时") }

    private func armTimeout(_ seconds: TimeInterval, message: String) {
        if deadline == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            deadline = timer
            timer.resume()
        }
        deadline?.setEventHandler { [weak self] in
            #if DEBUG
            self?.debugCloseReason = message == "透传连接空闲超时" ? .idleTimeout : .handshakeTimeout
            #endif
            self?.close(error: message)
        }
        deadline?.schedule(deadline: .now() + seconds)
    }

    func close(error: String? = nil) {
        guard !closed else { return }
        closed = true
        #if DEBUG
        debugTrace?.finish(debugCloseReason ?? (error != nil ? .transportError :
                                                (completedDirections == 2 ? .completeEOF : .cancelled)))
        #endif
        deadline?.cancel()
        deadline = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        onClosed(error)
    }
}
