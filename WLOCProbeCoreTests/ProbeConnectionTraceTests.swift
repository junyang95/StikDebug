#if DEBUG
import Foundation
import Network
import XCTest
@testable import WLOCProbeCore

final class ProbeConnectionTraceTests: XCTestCase {
    func testTerminationOrdersEOFSubmissionCompletionAndFirstFailureWithoutExtraEvents() throws {
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace { records.append($0) }
        trace.begin()
        trace.readEOF(upload: true)
        trace.readEOF(upload: true)
        trace.writeCloseCompleted(to: .upstream) // A callback without submission is invalid.
        trace.writeCloseSubmitted(to: .upstream)
        trace.writeCloseSubmitted(to: .upstream)
        trace.writeCloseCompleted(to: .upstream)
        trace.writeCloseCompleted(to: .upstream)
        trace.failure(.clientState, side: .client, error: .posix(.ECONNRESET))
        trace.failure(.upstreamState, side: .upstream, error: .posix(.ENETDOWN))
        XCTAssertEqual(records.count, 1)
        trace.finish(.transportError)
        trace.readEOF(upload: false)
        trace.writeCloseSubmitted(to: .client)
        trace.writeCloseCompleted(to: .client)

        let closed = try XCTUnwrap(records.last)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(closed.termination?.client.readEOF?.order, 1)
        XCTAssertEqual(closed.termination?.upstream.writeCloseSubmitted?.order, 2)
        XCTAssertEqual(closed.termination?.upstream.writeCloseCompleted?.order, 3)
        XCTAssertEqual(closed.failure?.observedAt?.order, 4)
        XCTAssertNil(closed.termination?.upstream.readEOF)
        XCTAssertNil(closed.termination?.client.writeCloseSubmitted)
        XCTAssertNil(closed.termination?.client.writeCloseCompleted)
    }

    func testFullTerminationRecordRoundTripRemainsBelowLogBound() throws {
        var now: TimeInterval = 100
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace(clock: { now }) { records.append($0) }
        trace.begin()
        trace.targetValidated("gs-loc.apple.com")
        trace.upstreamReady()
        trace.relayReady()
        now += 0.125
        trace.readEOF(upload: false)
        trace.writeCloseSubmitted(to: .client)
        trace.writeCloseCompleted(to: .client)
        now += 0.125
        trace.readEOF(upload: true)
        trace.writeCloseSubmitted(to: .upstream)
        trace.writeCloseCompleted(to: .upstream)
        trace.failure(.upstreamState, side: .upstream, error: .posix(.ENETDOWN))
        trace.finish(.transportError)
        let closed = try XCTUnwrap(records.last)
        XCTAssertEqual(closed.termination?.upstream.readEOF?.elapsedMS, 125)
        XCTAssertEqual(closed.termination?.client.readEOF?.elapsedMS, 250)
        XCTAssertEqual(closed.failure?.observedAt?.order, 7)
        let record = ProbeDebugRecord(source: .tunnel, event: .connection,
                                     counters: ProbeDebugCounters(), connection: closed)
        let data = try JSONEncoder().encode(record)
        XCTAssertLessThan(data.count, 4096)
        let decoded = try JSONDecoder().decode(ProbeDebugRecord.self, from: data)
        XCTAssertEqual(decoded.connection?.termination?.client.writeCloseCompleted?.order, 3)
        XCTAssertEqual(decoded.connection?.termination?.upstream.writeCloseCompleted?.order, 6)
        XCTAssertEqual(decoded.connection?.failure?.observedAt?.order, 7)
    }

    func testLifecycleEmitsEachPhaseAndCloseOnlyOnce() {
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace { records.append($0) }
        trace.targetValidated("gs-loc.apple.com")
        trace.upstreamReady()
        trace.relayReady()
        trace.finish(.stop)
        XCTAssertTrue(records.isEmpty)

        trace.begin()
        trace.begin()
        trace.targetValidated("gs-loc.apple.com")
        trace.targetValidated("gs-loc-cn.apple.com")
        trace.upstreamReady()
        trace.upstreamReady()
        trace.relayReady()
        trace.relayReady()
        trace.finish(.completeEOF)
        trace.finish(.transportError)
        trace.begin()
        trace.forwarded(100, upload: true)
        trace.readEOF(upload: false)
        trace.failure(.relayWrite, side: .upstream, error: .posix(.ECONNRESET))
        trace.targetValidated("gs-loc-cn.apple.com")
        trace.upstreamReady()
        trace.relayReady()

        XCTAssertEqual(records.map(\.phase), [.accepted, .targetValidated, .upstreamReady, .relayReady, .closed])
        XCTAssertEqual(records.last?.host, "gs-loc.apple.com")
        XCTAssertEqual(records.last?.reason, .completeEOF)
        XCTAssertEqual(records.last?.sent, 0)
        XCTAssertEqual(records.last?.upstreamEOF, false)
        XCTAssertNil(records.last?.failure)
    }

    func testUnknownHostNeverEntersTraceOrEncodedRecord() throws {
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace { records.append($0) }
        trace.begin()
        trace.targetValidated("private.example.invalid")
        trace.targetValidated("gs-loc.apple.com.evil.invalid")
        trace.upstreamReady()
        trace.relayReady()
        trace.finish(.rejected)

        XCTAssertEqual(records.map(\.phase), [.accepted, .closed])
        for record in records {
            XCTAssertNil(record.host)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            XCTAssertNil(object["host"])
        }
        XCTAssertEqual(records.last?.reason, .rejected)
    }

    func testElapsedBytesAndEOFMetadataAreCumulativeWithoutPerChunkEvents() throws {
        var now: TimeInterval = 100
        let id = UUID()
        let sessionID = UUID()
        var records: [ProbeDebugConnection] = []
        let trace = ProbeConnectionTrace(id: id, sessionID: sessionID, resetAt: 1234,
                                         clock: { now }, emit: { records.append($0) })
        trace.begin()
        now += 0.125
        trace.targetValidated("gs-loc.apple.com")
        now += 0.125
        trace.upstreamReady()
        now += 0.25
        trace.relayReady()
        trace.forwarded(11, upload: true)
        trace.forwarded(13, upload: true)
        trace.forwarded(17, upload: false)
        trace.forwarded(0, upload: true)
        trace.forwarded(-5, upload: false)
        trace.readEOF(upload: true)
        trace.readEOF(upload: false)
        XCTAssertEqual(records.count, 4, "Byte and EOF updates must not log per-chunk events")
        now += 0.5
        trace.finish(.completeEOF)

        XCTAssertEqual(records.map(\.elapsedMS), [0, 125, 250, 500, 1000])
        let closed = try XCTUnwrap(records.last)
        XCTAssertEqual(closed.id, id)
        XCTAssertEqual(closed.sessionID, sessionID)
        XCTAssertEqual(closed.resetAt, 1234)
        XCTAssertEqual(closed.sent, 24)
        XCTAssertEqual(closed.received, 17)
        XCTAssertTrue(closed.clientEOF)
        XCTAssertTrue(closed.upstreamEOF)
        XCTAssertNil(closed.failure)

        let decoded = try JSONDecoder().decode(ProbeDebugConnection.self, from: JSONEncoder().encode(closed))
        XCTAssertEqual(decoded.elapsedMS, 1000)
        XCTAssertEqual(decoded.sent, 24)
        XCTAssertEqual(decoded.received, 17)
        XCTAssertTrue(decoded.clientEOF)
        XCTAssertTrue(decoded.upstreamEOF)
    }

    func testElapsedClampsNegativeAndNonFiniteClockValues() {
        for value in [-1.0, Double.infinity, -Double.infinity, Double.nan] {
            var now: TimeInterval = 0
            var records: [ProbeDebugConnection] = []
            let trace = makeTrace(clock: { now }) { records.append($0) }
            trace.begin()
            now = value
            trace.finish(.cancelled)
            XCTAssertEqual(records.last?.elapsedMS, 0)
        }
    }

    func testFirstPOSIXFailurePreservesOperationSideAndReceiveMetadata() throws {
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace { records.append($0) }
        trace.begin()
        trace.failure(.headerRead, side: .client, error: .posix(.ECONNRESET), availableBytes: 27, endOfStream: true)
        trace.failure(.halfClose, side: .upstream, error: .posix(.EPIPE), availableBytes: 0, endOfStream: false)
        trace.finish(.handshakeTimeout)

        let record = try XCTUnwrap(records.last)
        let failure = try XCTUnwrap(record.failure)
        XCTAssertEqual(record.reason, .handshakeTimeout)
        XCTAssertEqual(failure.operation, .headerRead)
        XCTAssertEqual(failure.side, .client)
        XCTAssertEqual(failure.network?.domain, .posix)
        XCTAssertEqual(failure.network?.code, Int(POSIXErrorCode.ECONNRESET.rawValue))
        XCTAssertEqual(failure.availableBytes, 27)
        XCTAssertEqual(failure.endOfStream, true)
    }

    func testNegativeTLSAndDNSCodesSurviveFirstFailureAndCodableRoundTrip() throws {
        let failures: [(NWError, ProbeDebugConnection.Failure.NetworkCode.Domain, Int)] = [
            (.tls(-9807), .tls, -9807),
            (.dns(-65538), .dns, -65538)
        ]
        for (error, domain, code) in failures {
            var records: [ProbeDebugConnection] = []
            let trace = makeTrace { records.append($0) }
            trace.begin()
            trace.failure(.upstreamWaiting, side: .upstream, error: error)
            trace.failure(.upstreamState, side: .upstream, error: .posix(.ECONNREFUSED))
            trace.finish(.transportError)
            let original = try XCTUnwrap(records.last)
            let decoded = try JSONDecoder().decode(ProbeDebugConnection.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.failure?.operation, .upstreamWaiting)
            XCTAssertEqual(decoded.failure?.side, .upstream)
            XCTAssertEqual(decoded.failure?.network?.domain, domain)
            XCTAssertEqual(decoded.failure?.network?.code, code)
            XCTAssertNil(decoded.failure?.availableBytes)
            XCTAssertNil(decoded.failure?.endOfStream)
        }
    }

    func testFailureWithoutNWErrorKeepsFirstOperationAndClampsAvailableBytes() throws {
        var records: [ProbeDebugConnection] = []
        let trace = makeTrace { records.append($0) }
        trace.begin()
        trace.failure(.halfClose, side: .client, error: nil, availableBytes: -1, endOfStream: false)
        trace.failure(.relayWrite, side: .upstream, error: .posix(.EPIPE))
        trace.finish(.cancelled)
        let failure = try XCTUnwrap(records.last?.failure)
        XCTAssertEqual(failure.operation, .halfClose)
        XCTAssertEqual(failure.side, .client)
        XCTAssertNil(failure.network)
        XCTAssertEqual(failure.availableBytes, 0)
        XCTAssertEqual(failure.endOfStream, false)
    }

    func testCountersSeparateTCPConnectUpstreamRelayAndSingleClose() {
        var counters = ProbeDebugCounters()
        let trace = makeTrace { counters.observe($0) }
        trace.begin()
        trace.begin()
        XCTAssertEqual(counters.tcpAccepted, 1)
        XCTAssertEqual(counters.connectAccepted, 0)
        trace.targetValidated("gs-loc.apple.com")
        XCTAssertEqual(counters.connectAccepted, 1)
        XCTAssertEqual(counters.upstreamReady, 0)
        trace.upstreamReady()
        XCTAssertEqual(counters.upstreamReady, 1)
        XCTAssertEqual(counters.relayReady, 0)
        trace.relayReady()
        trace.finish(.completeEOF)
        trace.finish(.transportError)
        XCTAssertEqual(counters.relayReady, 1)
        XCTAssertEqual(counters.closed, 1)
        XCTAssertEqual(counters.errorClosed, 0)
        XCTAssertEqual(counters.resetClosed, 0)
        XCTAssertEqual(counters.stopClosed, 0)
    }

    func testCloseReasonsKeepCleanupAndErrorCountersDistinct() {
        let reasons: [(ProbeDebugConnection.Reason, Bool)] = [
            (.completeEOF, false), (.clientEOF, false), (.cancelled, false), (.reset, false), (.stop, false),
            (.rejected, true), (.transportError, true), (.handshakeTimeout, true), (.idleTimeout, true), (.connectionLimit, true)
        ]
        for (reason, isError) in reasons {
            var counters = ProbeDebugCounters()
            let trace = makeTrace { counters.observe($0) }
            trace.begin()
            trace.finish(reason)
            XCTAssertEqual(counters.tcpAccepted, 1, reason.rawValue)
            XCTAssertEqual(counters.connectAccepted, 0, reason.rawValue)
            XCTAssertEqual(counters.closed, 1, reason.rawValue)
            XCTAssertEqual(counters.errorClosed, isError ? 1 : 0, reason.rawValue)
            XCTAssertEqual(counters.resetClosed, reason == .reset ? 1 : 0, reason.rawValue)
            XCTAssertEqual(counters.stopClosed, reason == .stop ? 1 : 0, reason.rawValue)
        }
    }

    func testRecordedFailureCountsAsErrorEvenWhenLaterCleanupClosesRelay() {
        for reason in [ProbeDebugConnection.Reason.cancelled, .reset, .stop] {
            var counters = ProbeDebugCounters()
            let trace = makeTrace { counters.observe($0) }
            trace.begin()
            trace.failure(.upstreamConnect, side: .upstream, error: .posix(.ECONNREFUSED))
            trace.finish(reason)
            XCTAssertEqual(counters.closed, 1)
            XCTAssertEqual(counters.errorClosed, 1)
            XCTAssertEqual(counters.resetClosed, reason == .reset ? 1 : 0)
            XCTAssertEqual(counters.stopClosed, reason == .stop ? 1 : 0)
        }
    }

    private func makeTrace(clock: @escaping () -> TimeInterval = { 0 },
                           emit: @escaping (ProbeDebugConnection) -> Void) -> ProbeConnectionTrace {
        ProbeConnectionTrace(id: UUID(), sessionID: UUID(), resetAt: 100, clock: clock, emit: emit)
    }
}
#endif
