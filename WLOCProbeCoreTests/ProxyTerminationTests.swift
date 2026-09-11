#if DEBUG
import Darwin
import Foundation
import Network
import XCTest
@testable import WLOCProbeCore

/// BSD peers keep the wire-level half-close/RST stimulus independent of NWConnection.
/// Every endpoint is bound or connected to 127.0.0.1; no external DNS or traffic is used.
final class ProxyTerminationTests: XCTestCase {
    private let connectHeader = Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nHost: gs-loc.apple.com\r\n\r\n".utf8)
    private let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    func testDirectBSDControlDeliversBothHalfCloseOrders() async throws {
        let request = payload(count: 98_321, seed: 3)
        let response = payload(count: 131_089, seed: 5)
        for clientClosesFirst in [true, false] {
            let upstream = try TerminationListener()
            let server = Task.detached {
                let peer = try upstream.accept()
                if clientClosesFirst {
                    let received = try peer.readUntilEOF(limit: request.count)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try peer.sendAll(response)
                    try peer.shutdownWrite()
                    return received
                }
                try peer.sendAll(response)
                try peer.shutdownWrite()
                return try peer.readUntilEOF(limit: request.count)
            }
            let client = try TerminationSocket.connect(port: upstream.port)
            if clientClosesFirst {
                try client.sendAll(request)
                try client.shutdownWrite()
                XCTAssertEqual(try client.readUntilEOF(limit: response.count), response)
            } else {
                XCTAssertEqual(try client.readUntilEOF(limit: response.count), response)
                try await Task.sleep(nanoseconds: 150_000_000)
                try client.sendAll(request)
                try client.shutdownWrite()
            }
            let received = try await server.value
            XCTAssertEqual(received, request, "BSD fixture itself must preserve the complete half-closed stream")
        }
    }

    func testClientHalfCloseStillReceivesDelayedCompleteResponse() async throws {
        let upstream = try TerminationListener()
        let request = payload(count: 65_537, seed: 7)
        let response = payload(count: 131_089, seed: 23)
        let server = Task.detached {
            let peer = try upstream.accept()
            let received = try peer.readUntilEOF(limit: request.count)
            // The reply is deliberately impossible until the proxy forwards the client's FIN.
            try await Task.sleep(nanoseconds: 150_000_000)
            try peer.sendAll(response)
            try peer.shutdownWrite()
            return received
        }
        let trace = TerminationTraceRecorder()
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace)
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader)
        XCTAssertEqual(try client.readExactly(established.count), established)
        try client.sendAll(request)
        let halfClosedAt = ProcessInfo.processInfo.systemUptime
        try client.shutdownWrite()
        let received = try client.readUntilEOF(limit: response.count)
        let uploaded = try await server.value

        XCTAssertEqual(uploaded, request, "The upstream must receive every byte before the forwarded FIN")
        XCTAssertEqual(received, response, "A client FIN must not truncate the delayed reverse response")
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - halfClosedAt, 0.14)
        let record = try await finalRecord(trace)
        try assertCompleteTransfer(record, sent: request.count, received: response.count)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
        XCTAssertEqual(state.uploadedBytes, Int64(request.count))
        XCTAssertEqual(state.downloadedBytes, Int64(response.count))
    }

    func testUpstreamHalfCloseStillReceivesDelayedClientUpload() async throws {
        let upstream = try TerminationListener()
        let greeting = payload(count: 8_209, seed: 31)
        let upload = payload(count: 98_321, seed: 47)
        let server = Task.detached {
            let peer = try upstream.accept()
            try peer.sendAll(greeting)
            try peer.shutdownWrite()
            // A read remains live after SHUT_WR; the client has not even started this upload.
            return try peer.readUntilEOF(limit: upload.count)
        }
        let trace = TerminationTraceRecorder()
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace)
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader)
        XCTAssertEqual(try client.readExactly(established.count), established)
        XCTAssertEqual(try client.readUntilEOF(limit: greeting.count), greeting)
        // Only after observing the upstream's FIN do we attempt a new, delayed upload.
        try await Task.sleep(nanoseconds: 150_000_000)
        try client.sendAll(upload)
        try client.shutdownWrite()
        let received = try await server.value

        XCTAssertEqual(received, upload, "An upstream FIN must not close the client's sending direction")
        let record = try await finalRecord(trace)
        try assertCompleteTransfer(record, sent: upload.count, received: greeting.count)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
        XCTAssertEqual(state.uploadedBytes, Int64(upload.count))
        XCTAssertEqual(state.downloadedBytes, Int64(greeting.count))
    }

    func testPipelinedCONNECTPayloadAndClientFINStillReceiveResponse() async throws {
        let upstream = try TerminationListener()
        let upload = payload(count: 257, seed: 71)
        let response = payload(count: 4_111, seed: 83)
        let server = Task.detached {
            let peer = try upstream.accept()
            let received = try peer.readUntilEOF(limit: upload.count)
            try peer.sendAll(response)
            try peer.shutdownWrite()
            return received
        }
        let trace = TerminationTraceRecorder()
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace)
        let inputQueued = DispatchSemaphore(value: 0)
        proxy.debugObserver = { record in
            trace.observe(record)
            if record.connection?.phase == .accepted {
                // Queue all bytes and FIN before starting the accepted NWConnection.
                // Network.framework still decides whether to combine data and EOF.
                _ = inputQueued.wait(timeout: .now() + 2)
            }
        }
        let port = try await start(proxy)
        defer { inputQueued.signal(); proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader + upload)
        try client.shutdownWrite()
        inputQueued.signal()
        XCTAssertEqual(try client.readExactly(established.count), established)
        XCTAssertEqual(try client.readUntilEOF(limit: response.count), response)
        let record = try await finalRecord(trace)
        let received = try await server.value

        XCTAssertEqual(received, upload, "CONNECT-coalesced initial bytes must survive the client's immediate FIN")
        try assertCompleteTransfer(record, sent: upload.count, received: response.count)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
    }

    func testClientRSTReleasesSlotAndRecordsClientReset() async throws {
        let upstream = try TerminationListener()
        let upload = payload(count: 4_099, seed: 59)
        let acknowledgment = Data("upstream-received-all-bytes".utf8)
        let server = Task.detached {
            let peer = try upstream.accept()
            let received = try peer.readExactly(upload.count)
            try peer.sendAll(acknowledgment)
            // Once the client aborts, the proxy must close its upstream as well.
            let end = peer.waitForPeerEnd()
            return (received, end)
        }
        let trace = TerminationTraceRecorder()
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace)
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader)
        XCTAssertEqual(try client.readExactly(established.count), established)
        try client.sendAll(upload)
        XCTAssertEqual(try client.readExactly(acknowledgment.count), acknowledgment)
        let before = await snapshot(proxy)
        XCTAssertEqual(before.activeConnections, 1)
        let resetAt = ProcessInfo.processInfo.systemUptime
        try client.abortWithRST()
        let record = try await finalRecord(trace)
        let state = await snapshot(proxy)
        let (received, upstreamEnd) = try await server.value

        XCTAssertEqual(received, upload)
        XCTAssertTrue(upstreamEnd, "The upstream must be released, not left waiting until its timeout")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - resetAt, 1.0)
        XCTAssertEqual(state.activeConnections, 0)
        let closed = try XCTUnwrap(record.connection)
        let failure = try XCTUnwrap(closed.failure)
        XCTAssertEqual(closed.reason, .transportError)
        XCTAssertEqual(failure.side, .client)
        XCTAssertTrue([.clientState, .relayRead].contains(failure.operation), "Unexpected first operation: \(failure.operation)")
        XCTAssertEqual(failure.network?.domain, .posix)
        XCTAssertEqual(failure.network?.code, Int(ECONNRESET))
        XCTAssertEqual(closed.sent, Int64(upload.count))
        XCTAssertEqual(closed.received, Int64(acknowledgment.count))
        XCTAssertEqual(record.counters?.tcpAccepted, 1)
        XCTAssertEqual(record.counters?.closed, 1)
        XCTAssertEqual(record.counters?.errorClosed, 1)
        XCTAssertEqual(trace.records.filter { $0.connection?.phase == .closed }.count, 1)
    }

    func testInjectedFINCompletionENETDOWNStillDrainsDelayedResponse() async throws {
        let upstream = try TerminationListener()
        let request = payload(count: 4_103, seed: 97)
        let response = payload(count: 131_101, seed: 109)
        let server = Task.detached {
            let peer = try upstream.accept()
            let received = try peer.readUntilEOF(limit: request.count)
            try await Task.sleep(nanoseconds: 150_000_000)
            try peer.sendAll(response)
            try peer.shutdownWrite()
            return received
        }
        let trace = TerminationTraceRecorder()
        var isFirstFIN = true // Only accessed by writeClose on the proxy's serial queue.
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace, writeClose: { connection, completion in
            let inject = isFirstFIN
            isFirstFIN = false
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { actualError in
                // Fault injection: the FIN really goes on the wire, but the first
                // completion is synthetic. This does not assert an OS ordering.
                completion(inject ? .posix(.ENETDOWN) : actualError)
            })
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader)
        XCTAssertEqual(try client.readExactly(established.count), established)
        try client.sendAll(request)
        try client.shutdownWrite()
        let received = try client.readUntilEOF(limit: response.count)
        XCTAssertEqual(received, response, "A synthetic FIN completion failure must not discard the later reverse payload")
        let uploaded = try await server.value
        XCTAssertEqual(uploaded, request)
        let record = try await finalRecord(trace)
        try assertCompleteTransfer(record, sent: request.count, received: response.count)
        let closed = try XCTUnwrap(record.connection)
        XCTAssertEqual(closed.failure?.operation, .halfClose)
        XCTAssertEqual(closed.failure?.side, .upstream)
        XCTAssertEqual(closed.failure?.network?.domain, .posix)
        XCTAssertEqual(closed.failure?.network?.code, Int(ENETDOWN))
        XCTAssertEqual(closed.reason, .transportError)
        XCTAssertEqual(record.counters?.errorClosed, 1)
        XCTAssertNil(closed.termination?.upstream.writeCloseCompleted,
                     "A failed FIN callback must never be reported as a completed write-close")
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
    }

    func testInjectedFINCompletionENETDOWNWithoutFINExpiresAtFixedDeadline() async throws {
        let upstream = try TerminationListener()
        let request = payload(count: 2_057, seed: 127)
        let server = Task.detached {
            let peer = try upstream.accept()
            // No FIN is actually sent by the first injected write-close, so the
            // server cannot see EOF until the proxy's independent deadline fires.
            return try peer.readUntilEOF(limit: request.count)
        }
        let trace = TerminationTraceRecorder()
        var isFirstFIN = true
        let proxy = makeProxy(upstreamPort: upstream.port, trace: trace, writeClose: { connection, completion in
            if isFirstFIN {
                isFirstFIN = false
                // Deliberately simulate a failed submission: no real FIN, no reply.
                completion(.posix(.ENETDOWN))
            } else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { completion($0) })
            }
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try TerminationSocket.connect(port: port)
        try client.sendAll(connectHeader)
        XCTAssertEqual(try client.readExactly(established.count), established)
        try client.sendAll(request)
        let halfClosedAt = ProcessInfo.processInfo.systemUptime
        try client.shutdownWrite()
        XCTAssertTrue(try client.readUntilEOF(limit: 0).isEmpty)
        let elapsed = ProcessInfo.processInfo.systemUptime - halfClosedAt
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "The injected failure must enter bounded drain instead of closing immediately")
        XCTAssertLessThan(elapsed, 1.8, "The independent one-second drain deadline must release the connection")
        let uploaded = try await server.value
        XCTAssertEqual(uploaded, request)
        let record = try await finalRecord(trace)
        let closed = try XCTUnwrap(record.connection)
        XCTAssertEqual(closed.failure?.operation, .halfClose)
        XCTAssertEqual(closed.failure?.side, .upstream)
        XCTAssertEqual(closed.failure?.network?.code, Int(ENETDOWN))
        XCTAssertEqual(closed.reason, .transportError)
        XCTAssertTrue(closed.clientEOF)
        XCTAssertFalse(closed.upstreamEOF)
        XCTAssertNil(closed.termination?.upstream.writeCloseCompleted)
        XCTAssertEqual(record.counters?.closed, 1)
        XCTAssertEqual(record.counters?.errorClosed, 1)
        XCTAssertEqual(record.counters?.resetClosed, 0)
        XCTAssertEqual(record.counters?.stopClosed, 0)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
    }

    func testResetAndStopInterruptInjectedDrainWithoutCounterLeak() async throws {
        var cleanupTraces: [TerminationTraceRecorder] = []
        for reset in [true, false] {
            let upstream = try TerminationListener()
            let request = payload(count: 1_031, seed: reset ? 139 : 149)
            let server = Task.detached {
                let peer = try upstream.accept()
                return try peer.readUntilEOF(limit: request.count)
            }
            let trace = TerminationTraceRecorder()
            let injected = DispatchSemaphore(value: 0)
            var isFirstFIN = true
            let proxy = makeProxy(upstreamPort: upstream.port, trace: trace, writeClose: { connection, completion in
                if isFirstFIN {
                    isFirstFIN = false
                    // Synthetic failed FIN submission leaves an otherwise idle read chain.
                    completion(.posix(.ENETDOWN))
                    injected.signal()
                } else {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { completion($0) })
                }
            })
            let port = try await start(proxy)
            defer { proxy.stop() }
            let client = try TerminationSocket.connect(port: port)
            try client.sendAll(connectHeader)
            XCTAssertEqual(try client.readExactly(established.count), established)
            try client.sendAll(request)
            try client.shutdownWrite()
            XCTAssertEqual(injected.wait(timeout: .now() + 2), .success)
            let draining = await snapshot(proxy)
            XCTAssertEqual(draining.activeConnections, 1, "The injected failure must still be draining before cleanup")
            let cleanupAt = ProcessInfo.processInfo.systemUptime
            let after: ProbeSnapshot
            if reset {
                after = await withCheckedContinuation { continuation in
                    proxy.snapshot(reset: true) { continuation.resume(returning: $0) }
                }
            } else {
                await withCheckedContinuation { continuation in proxy.stop { continuation.resume() } }
                after = await snapshot(proxy)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cleanupAt, 0.5)
            XCTAssertEqual(after.activeConnections, 0)
            XCTAssertEqual(after.listening, reset)
            let uploaded = try await server.value
            XCTAssertEqual(uploaded, request)
            XCTAssertTrue(try client.readUntilEOF(limit: 0).isEmpty)
            let record = try await finalRecord(trace)
            XCTAssertEqual(record.connection?.reason, reset ? .reset : .stop)
            XCTAssertEqual(record.connection?.failure?.operation, .halfClose)
            XCTAssertEqual(record.connection?.failure?.network?.code, Int(ENETDOWN))
            XCTAssertEqual(record.counters?.closed, 1)
            XCTAssertEqual(record.counters?.errorClosed, 1, "The existing injected error is counted once, not erased by cleanup")
            XCTAssertEqual(record.counters?.resetClosed, reset ? 1 : 0)
            XCTAssertEqual(record.counters?.stopClosed, reset ? 0 : 1)
            if reset {
                let cleared = try XCTUnwrap(trace.records.last { $0.event == .reset })
                XCTAssertEqual(cleared.counters?.tcpAccepted, 0)
                XCTAssertEqual(cleared.counters?.closed, 0)
                XCTAssertEqual(cleared.counters?.errorClosed, 0)
                XCTAssertEqual(cleared.counters?.resetClosed, 0)
            }
            cleanupTraces.append(trace)
        }
        // Let both superseded one-second deadlines pass: neither may add another close.
        try await Task.sleep(nanoseconds: 1_050_000_000)
        for trace in cleanupTraces {
            XCTAssertEqual(trace.records.filter { $0.connection?.phase == .closed }.count, 1)
        }
    }

    private func assertCompleteTransfer(_ record: ProbeDebugRecord, sent: Int, received: Int,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let closed = try XCTUnwrap(record.connection, file: file, line: line)
        XCTAssertEqual(closed.phase, .closed, file: file, line: line)
        XCTAssertEqual(closed.sent, Int64(sent), file: file, line: line)
        XCTAssertEqual(closed.received, Int64(received), file: file, line: line)
        XCTAssertTrue(closed.clientEOF, file: file, line: line)
        XCTAssertTrue(closed.upstreamEOF, file: file, line: line)
        XCTAssertEqual(record.counters?.tcpAccepted, 1, file: file, line: line)
        XCTAssertEqual(record.counters?.relayReady, 1, file: file, line: line)
        XCTAssertEqual(record.counters?.closed, 1, file: file, line: line)
        let termination = try XCTUnwrap(closed.termination, file: file, line: line)
        let clientEOF = try XCTUnwrap(termination.client.readEOF, file: file, line: line)
        let upstreamEOF = try XCTUnwrap(termination.upstream.readEOF, file: file, line: line)
        let clientFIN = try XCTUnwrap(termination.client.writeCloseSubmitted, file: file, line: line)
        let upstreamFIN = try XCTUnwrap(termination.upstream.writeCloseSubmitted, file: file, line: line)
        XCTAssertLessThan(clientEOF.order, upstreamFIN.order, file: file, line: line)
        XCTAssertLessThan(upstreamEOF.order, clientFIN.order, file: file, line: line)
        if let completed = termination.client.writeCloseCompleted {
            XCTAssertLessThan(clientFIN.order, completed.order, file: file, line: line)
        }
        if let completed = termination.upstream.writeCloseCompleted {
            XCTAssertLessThan(upstreamFIN.order, completed.order, file: file, line: line)
        }
        if let failure = closed.failure,
           [.clientState, .upstreamState].contains(failure.operation),
           failure.network?.domain == .posix, failure.network?.code == Int(ENETDOWN) {
            let observed = try XCTUnwrap(failure.observedAt, file: file, line: line)
            let submitted = failure.side == .client ? clientFIN : upstreamFIN
            XCTAssertLessThan(submitted.order, observed.order,
                              "The bounded drain is only eligible after FIN submission on the failing side", file: file, line: line)
            XCTAssertEqual(closed.reason, .transportError, file: file, line: line)
            XCTAssertEqual(record.counters?.errorClosed, 1,
                           "Draining the complete payload must not erase the observed transport failure", file: file, line: line)
        }
        // The oracle is exact delayed delivery in both directions, not a presumed
        // clean OS terminal state after both EOFs. Preserve any real close diagnostics.
    }

    private func makeProxy(upstreamPort: UInt16, trace: TerminationTraceRecorder,
                           writeClose: @escaping LoopbackConnectProxy.WriteClose = { connection, completion in
                               connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                               completion: .contentProcessed { completion($0) })
                           }) -> LoopbackConnectProxy {
        let proxy = LoopbackConnectProxy(handshakeTimeout: 2, idleTimeout: 2, upstream: { _ in
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        }, writeClose: writeClose)
        proxy.debugObserver = trace.observe
        return proxy
    }

    private func start(_ proxy: LoopbackConnectProxy) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            proxy.start(onFailure: { XCTFail("Unexpected local listener failure: \($0)") }) {
                continuation.resume(with: $0)
            }
        }
    }

    private func snapshot(_ proxy: LoopbackConnectProxy) async -> ProbeSnapshot {
        await withCheckedContinuation { continuation in
            proxy.snapshot { continuation.resume(returning: $0) }
        }
    }

    private func finalRecord(_ trace: TerminationTraceRecorder) async throws -> ProbeDebugRecord {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            if let record = trace.records.last(where: { $0.connection?.phase == .closed }) {
                if let data = try? record.encoded() {
                    print("TERMINATION_TEST_CLOSE \(String(decoding: data, as: UTF8.self))")
                }
                return record
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return try XCTUnwrap(trace.records.last { $0.connection?.phase == .closed }, "No close record within one second")
    }

    private func payload(count: Int, seed: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ seed) })
    }
}

private final class TerminationTraceRecorder {
    private let lock = NSLock()
    private var stored: [ProbeDebugRecord] = []
    var records: [ProbeDebugRecord] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func observe(_ record: ProbeDebugRecord) {
        lock.lock(); defer { lock.unlock() }
        stored.append(record)
    }
}

private enum TerminationSocketError: Error {
    case system(String, Int32)
    case timeout
    case unexpectedEOF(expected: Int, received: Int)
    case exceededLimit(Int)
}

private final class TerminationListener {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TerminationSocketError.system("socket", errno) }
        do {
            var address = TerminationSocket.loopbackAddress(port: 0)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw TerminationSocketError.system("bind", errno) }
            guard Darwin.listen(descriptor, 1) == 0 else { throw TerminationSocketError.system("listen", errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw TerminationSocketError.system("getsockname", errno) }
            self.descriptor = descriptor
            port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func accept() throws -> TerminationSocket {
        try TerminationSocket.waitReadable(descriptor, until: ProcessInfo.processInfo.systemUptime + 2)
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw TerminationSocketError.system("accept", errno) }
        return try TerminationSocket(descriptor: peer)
    }
}

private final class TerminationSocket {
    private var descriptor: Int32

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var suppressSIGPIPE: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            self.descriptor = -1
            throw TerminationSocketError.system("SO_NOSIGPIPE", code)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            self.descriptor = -1
            throw TerminationSocketError.system("SO_SNDTIMEO", code)
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    static func connect(port: UInt16) throws -> TerminationSocket {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TerminationSocketError.system("socket", errno) }
        let socket = try TerminationSocket(descriptor: descriptor)
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw TerminationSocketError.system("connect", errno) }
        return socket
    }

    static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw TerminationSocketError.system("send", errno)
                }
                guard sent > 0 else { throw TerminationSocketError.system("send returned zero", 0) }
                offset += sent
            }
        }
    }

    func shutdownWrite() throws {
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { throw TerminationSocketError.system("shutdown", errno) }
    }

    func abortWithRST() throws {
        var abortive = linger(l_onoff: 1, l_linger: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &abortive,
                         socklen_t(MemoryLayout<linger>.size)) == 0 else {
            throw TerminationSocketError.system("SO_LINGER", errno)
        }
        let old = descriptor
        descriptor = -1
        guard Darwin.close(old) == 0 else { throw TerminationSocketError.system("abort close", errno) }
    }

    func readExactly(_ count: Int) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var result = Data()
        while result.count < count {
            let chunk = try readChunk(maximum: min(32_768, count - result.count), until: deadline)
            guard !chunk.isEmpty else { throw TerminationSocketError.unexpectedEOF(expected: count, received: result.count) }
            result.append(chunk)
        }
        return result
    }

    func readUntilEOF(limit: Int) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var result = Data()
        while true {
            let chunk = try readChunk(maximum: 32_768, until: deadline)
            if chunk.isEmpty { return result }
            result.append(chunk)
            guard result.count <= limit else { throw TerminationSocketError.exceededLimit(limit) }
        }
    }

    func waitForPeerEnd() -> Bool {
        do {
            return try readUntilEOF(limit: 0).isEmpty
        } catch TerminationSocketError.system(_, let code) {
            return code == ECONNRESET || code == ECONNABORTED
        } catch { return false }
    }

    private func readChunk(maximum: Int, until deadline: TimeInterval) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            try Self.waitReadable(descriptor, until: deadline)
            let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if received < 0 {
                if errno == EINTR { continue }
                throw TerminationSocketError.system("recv", errno)
            }
            return Data(buffer.prefix(received))
        }
    }

    static func waitReadable(_ descriptor: Int32, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TerminationSocketError.timeout }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptorState, 1, Int32(ceil(remaining * 1000)))
            if result > 0 { return }
            if result == 0 { throw TerminationSocketError.timeout }
            if errno != EINTR { throw TerminationSocketError.system("poll", errno) }
        }
    }
}
#endif
