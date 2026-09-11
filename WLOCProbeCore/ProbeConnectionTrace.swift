#if DEBUG
import Foundation
import Network

/// Transport metadata only. An EOF or completed relay is not an HTTP/TLS success.
struct ProbeDebugConnection: Codable {
    enum Phase: String, Codable { case accepted, targetValidated, upstreamReady, relayReady, closed }
    enum Reason: String, Codable {
        case completeEOF, clientEOF, cancelled, rejected, transportError
        case handshakeTimeout, idleTimeout, reset, stop, connectionLimit
        var indicatesError: Bool {
            switch self {
            case .rejected, .transportError, .handshakeTimeout, .idleTimeout, .connectionLimit: true
            default: false
            }
        }
    }
    /// Queue-local ordering, not packet timestamps or delivery acknowledgements.
    struct Mark: Codable {
        let order: Int
        let elapsedMS: Int
    }
    struct Termination: Codable {
        struct Direction: Codable {
            var readEOF: Mark?
            var writeCloseSubmitted: Mark?
            var writeCloseCompleted: Mark?
        }
        var client = Direction()
        var upstream = Direction()
    }
    struct Failure: Codable {
        enum Operation: String, Codable {
            case clientState, headerRead, upstreamConnect, upstreamWaiting, upstreamState
            case connectReply, initialUpload, relayRead, relayWrite, halfClose
        }
        enum Side: String, Codable { case client, upstream }
        struct NetworkCode: Codable {
            enum Domain: String, Codable { case posix, dns, tls, other }
            let domain: Domain
            let code: Int?
            init(_ error: NWError) {
                switch error {
                case .posix(let code): domain = .posix; self.code = Int(code.rawValue)
                case .dns(let code): domain = .dns; self.code = Int(code)
                case .tls(let code): domain = .tls; self.code = Int(code)
                @unknown default: domain = .other; self.code = nil
                }
            }
        }
        let operation: Operation
        let side: Side
        let network: NetworkCode?
        let availableBytes: Int?
        let endOfStream: Bool?
        var observedAt: Mark?
    }
    let id: UUID
    let sessionID: UUID
    let resetAt: TimeInterval
    var phase: Phase = .accepted
    var elapsedMS = 0
    var sent: Int64 = 0
    var received: Int64 = 0
    var clientEOF = false
    var upstreamEOF = false
    var host: String?
    var reason: Reason?
    var failure: Failure?
    var termination: Termination?
}

struct ProbeDebugCounters: Codable {
    var tcpAccepted = 0
    var connectAccepted = 0
    var upstreamReady = 0
    var relayReady = 0
    var closed = 0
    var errorClosed = 0
    var resetClosed = 0
    var stopClosed = 0

    mutating func observe(_ connection: ProbeDebugConnection) {
        switch connection.phase {
        case .accepted: tcpAccepted += 1
        case .targetValidated: connectAccepted += 1
        case .upstreamReady: upstreamReady += 1
        case .relayReady: relayReady += 1
        case .closed:
            closed += 1
            if connection.reason?.indicatesError == true || connection.failure != nil { errorClosed += 1 }
            if connection.reason == .reset { resetClosed += 1 }
            if connection.reason == .stop { stopClosed += 1 }
        }
    }
}

/// Owned by one relay on its serial queue. No history buffer or per-chunk log.
final class ProbeConnectionTrace {
    private var value: ProbeDebugConnection
    private let startedAt: TimeInterval
    private let clock: () -> TimeInterval
    private let emit: (ProbeDebugConnection) -> Void
    private var started = false
    private var closed = false
    private var termination = ProbeDebugConnection.Termination()
    private var order = 0

    init(id: UUID, sessionID: UUID, resetAt: TimeInterval,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (ProbeDebugConnection) -> Void) {
        value = ProbeDebugConnection(id: id, sessionID: sessionID, resetAt: resetAt)
        self.clock = clock
        startedAt = clock()
        self.emit = emit
    }

    func begin() {
        guard !started, !closed else { return }
        started = true
        publish(.accepted)
    }

    func targetValidated(_ host: String) {
        guard started, !closed, value.phase == .accepted, WLOCProbePolicy.hosts.contains(host) else { return }
        value.host = host
        publish(.targetValidated)
    }

    func upstreamReady() {
        guard !closed, value.phase == .targetValidated else { return }
        publish(.upstreamReady)
    }

    func relayReady() {
        guard !closed, value.phase == .upstreamReady else { return }
        publish(.relayReady)
    }

    func forwarded(_ count: Int, upload: Bool) {
        guard !closed, count > 0 else { return }
        if upload { value.sent += Int64(count) } else { value.received += Int64(count) }
    }

    func readEOF(upload: Bool) {
        guard !closed else { return }
        if upload {
            guard !value.clientEOF else { return }
            value.clientEOF = true
            termination.client.readEOF = mark()
        } else {
            guard !value.upstreamEOF else { return }
            value.upstreamEOF = true
            termination.upstream.readEOF = mark()
        }
    }

    func writeCloseSubmitted(to side: ProbeDebugConnection.Failure.Side) {
        guard !closed else { return }
        switch side {
        case .client:
            guard termination.client.writeCloseSubmitted == nil else { return }
            termination.client.writeCloseSubmitted = mark()
        case .upstream:
            guard termination.upstream.writeCloseSubmitted == nil else { return }
            termination.upstream.writeCloseSubmitted = mark()
        }
    }

    func writeCloseCompleted(to side: ProbeDebugConnection.Failure.Side) {
        guard !closed else { return }
        switch side {
        case .client:
            guard termination.client.writeCloseSubmitted != nil,
                  termination.client.writeCloseCompleted == nil else { return }
            termination.client.writeCloseCompleted = mark()
        case .upstream:
            guard termination.upstream.writeCloseSubmitted != nil,
                  termination.upstream.writeCloseCompleted == nil else { return }
            termination.upstream.writeCloseCompleted = mark()
        }
    }

    func failure(_ operation: ProbeDebugConnection.Failure.Operation,
                 side: ProbeDebugConnection.Failure.Side, error: NWError?,
                 availableBytes: Int? = nil, endOfStream: Bool? = nil) {
        guard !closed, value.failure == nil else { return }
        // Preserve the first failure if a later timeout/cancel finishes the relay.
        value.failure = .init(operation: operation, side: side, network: error.map { .init($0) },
                              availableBytes: availableBytes.map { max(0, $0) }, endOfStream: endOfStream,
                              observedAt: mark())
    }

    func finish(_ reason: ProbeDebugConnection.Reason) {
        guard started, !closed else { return }
        closed = true
        value.reason = reason
        value.termination = termination
        publish(.closed)
    }

    private func elapsedMS() -> Int {
        let milliseconds = (clock() - startedAt) * 1000
        // Monotonic production clock; clamp injected/pathological values defensively.
        return milliseconds.isFinite ? Int(max(0, min(milliseconds, Double(Int.max / 2)))) : 0
    }

    private func mark() -> ProbeDebugConnection.Mark {
        order += 1
        return .init(order: order, elapsedMS: elapsedMS())
    }

    private func publish(_ phase: ProbeDebugConnection.Phase) {
        value.phase = phase
        value.elapsedMS = elapsedMS()
        emit(value)
    }
}
#endif
