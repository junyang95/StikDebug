import Foundation
import Network
import XCTest
@testable import WLOCProbeCore

final class ProxyIntegrationTests: XCTestCase {
    private let queue = DispatchQueue(label: "probe.test.client")
    private let successHeader = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    func testCoalescedBinaryBytesAreEchoedUnmodifiedAndCounted() async throws {
        let echo = try EchoServer()
        let upstreamPort = try await echo.start()
        defer { echo.stop() }
        let proxy = LoopbackConnectProxy(upstream: { _ in
            NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        let payload = Data((0..<262_144).map { UInt8($0 % 256) })
        let connectHeader = Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n\r\n".utf8)
        client.send(content: connectHeader + payload, completion: .contentProcessed { _ in })
        let response = await read(client, count: successHeader.count + payload.count)
        XCTAssertEqual(response, successHeader + payload)
        let snapshot = await snapshot(proxy)
        XCTAssertEqual(snapshot.totalConnections, 1)
        XCTAssertEqual(snapshot.uploadedBytes, Int64(payload.count))
        XCTAssertEqual(snapshot.downloadedBytes, Int64(payload.count))
        XCTAssertTrue(snapshot.listening)
    }

    func testForbiddenTargetNeverCreatesUpstream() async throws {
        let proxy = LoopbackConnectProxy(upstream: { _ in
            XCTFail("Forbidden target reached upstream factory")
            return NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        client.send(content: Data("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let data = await read(client, count: 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        let state = await snapshot(proxy)
        XCTAssertEqual(state.totalConnections, 0)
    }

    func testPartialHeaderTimesOutAndEarlyCloseReleasesSlot() async throws {
        let proxy = LoopbackConnectProxy(handshakeTimeout: 0.2)
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        client.send(content: Data("CONNE".utf8), completion: .contentProcessed { _ in })
        let timeout = await read(client, count: 1, expectEOF: true)
        XCTAssertTrue(timeout.isEmpty)
        var state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
        XCTAssertNotNil(state.lastError)
        let early = try await connect(port)
        early.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
    }

    func testResetClosesOldConnectionsWithoutRestartingListener() async throws {
        let proxy = LoopbackConnectProxy()
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        // TCP readiness can precede NWListener's queued accept callback.
        for _ in 0..<100 {
            if await snapshot(proxy).activeConnections == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = await snapshot(proxy)
        XCTAssertEqual(before.activeConnections, 1)
        let after = await snapshot(proxy, reset: true)
        XCTAssertEqual(after.activeConnections, 0)
        XCTAssertEqual(after.totalConnections, 0)
        XCTAssertEqual(before.sessionID, after.sessionID)
        XCTAssertEqual(before.port, after.port)
        XCTAssertTrue(after.listening)
        _ = await read(client, count: 1, expectEOF: true)
    }

    func testStopCompletesAndRemovesListener() async throws {
        let proxy = LoopbackConnectProxy()
        _ = try await start(proxy)
        await withCheckedContinuation { continuation in proxy.stop { continuation.resume() } }
        let stopped = await snapshot(proxy)
        XCTAssertFalse(stopped.listening)
        XCTAssertNil(stopped.port)
        XCTAssertEqual(stopped.activeConnections, 0)
    }

    func testUpstreamFailureReturns502AndReleasesConnection() async throws {
        let proxy = LoopbackConnectProxy(upstream: { _ in
            NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        client.send(content: Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let response = await read(client, count: 1)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 502"))
        let state = await snapshot(proxy)
        XCTAssertEqual(state.totalConnections, 1)
        XCTAssertEqual(state.uploadedBytes, 0)
    }

    func testTunnelIdleTimeoutClosesBothDirections() async throws {
        let echo = try EchoServer()
        let upstreamPort = try await echo.start()
        defer { echo.stop() }
        let proxy = LoopbackConnectProxy(idleTimeout: 0.2, upstream: { _ in
            NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        client.send(content: Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let response = await read(client, count: successHeader.count)
        XCTAssertEqual(response, successHeader)
        _ = await read(client, count: 1, expectEOF: true)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.activeConnections, 0)
        XCTAssertEqual(state.lastError, "透传连接空闲超时")
    }

    func testClientHalfCloseStillReceivesUpstreamResponse() async throws {
        let echo = try EchoServer()
        let upstreamPort = try await echo.start()
        defer { echo.stop() }
        let proxy = LoopbackConnectProxy(upstream: { _ in
            NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
        })
        let port = try await start(proxy)
        defer { proxy.stop() }
        let client = try await connect(port)
        defer { client.cancel() }
        client.send(content: Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let header = await read(client, count: successHeader.count)
        XCTAssertEqual(header, successHeader)
        let payload = Data((0..<65_536).map { UInt8($0 % 256) })
        client.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        let response = await read(client, count: payload.count, expectEOF: true)
        XCTAssertEqual(response, payload)
        let state = await snapshot(proxy)
        XCTAssertEqual(state.uploadedBytes, Int64(payload.count))
        XCTAssertEqual(state.downloadedBytes, Int64(payload.count))
    }

    private func start(_ proxy: LoopbackConnectProxy) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            proxy.start(onFailure: { XCTFail("Listener failed: \($0)") }) { continuation.resume(with: $0) }
        }
    }

    private func snapshot(_ proxy: LoopbackConnectProxy, reset: Bool = false) async -> ProbeSnapshot {
        await withCheckedContinuation { continuation in proxy.snapshot(reset: reset) { continuation.resume(returning: $0) } }
    }

    private func connect(_ port: UInt16) async throws -> NWConnection {
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.stateUpdateHandler = { state in
                switch state {
                case .ready: client.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): client.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            client.start(queue: queue)
        }
        return client
    }

    private func read(_ client: NWConnection, count: Int, expectEOF: Bool = false) async -> Data {
        let received = expectation(description: "receive bytes or EOF")
        var output = Data()
        func next() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, eof, error in
                if let data { output.append(data) }
                if eof || error != nil || (!expectEOF && output.count >= count) {
                    received.fulfill()
                } else { next() }
            }
        }
        next()
        await fulfillment(of: [received], timeout: 5)
        return output
    }
}

private final class EchoServer {
    private let queue = DispatchQueue(label: "probe.test.echo")
    private let listener: NWListener
    private var clients: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { return }
            self.clients.append(client)
            client.start(queue: self.queue)
            self.echo(client)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func echo(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, eof, error in
            guard error == nil else { client.cancel(); return }
            client.send(content: data, completion: .contentProcessed { _ in
                if eof {
                    client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                } else { self?.echo(client) }
            })
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            clients.forEach { $0.cancel() }
            clients.removeAll()
        }
    }
}
