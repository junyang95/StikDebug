import Darwin
import Foundation
import XCTest
@testable import WLOCProbeCore

final class CertificateProfileServerTests: XCTestCase {
    private let profile = Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)

    func testFragmentedGETDeliversExactProfileAndHeadersThenStops() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.lastPathComponent, "StikDebug-WLOC.mobileconfig")
        XCTAssertNotNil(UUID(uuidString: url.pathComponents[1]))
        let client = try ProfileSocket(url)
        let bytes = request(url)
        for part in [bytes.prefix(3), bytes.dropFirst(3).prefix(17), bytes.dropFirst(20)] {
            try client.send(Data(part))
        }
        let response = try client.readToEnd()
        try assertProfile(response, equals: profile)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: application/x-apple-aspen-config\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"StikDebug-WLOC.mobileconfig\"\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        do { _ = try await start(server); XCTFail("A successful download must consume the server") }
        catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .stopped) }
    }

    func testInvalidRequestsDoNotConsumeValidDownload() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        let host = "127.0.0.1:\(url.port!)"
        let requests = [
            "GET /wrong HTTP/1.1\r\nHost: \(host)\r\n\r\n",
            "POST \(url.path) HTTP/1.1\r\nHost: \(host)\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\nHost: localhost:\(url.port!)\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\nHost: \(host)\r\nHost: \(host)\r\n\r\n",
            "GET \(url.path)?extra HTTP/1.1\r\nHost: \(host)\r\n\r\n",
            "GET \(url.absoluteString) HTTP/1.1\r\nHost: \(host)\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\nHost: \(host)\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET \(url.path) HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 1\r\n\r\nx",
            "GET \(url.path) HTTP/1.1\r\nHost: \(host)\r\n Bad: folded\r\n\r\n"
        ]
        for invalid in requests {
            let client = try ProfileSocket(url)
            try client.send(Data(invalid.utf8))
            XCTAssertTrue(try client.readToEnd().isEmpty)
        }
        let valid = try ProfileSocket(url)
        try valid.send(request(url))
        try assertProfile(valid.readToEnd(), equals: profile)
    }

    func testOversizedHeaderIsRejectedWithoutConsumingServer() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        let invalid = try ProfileSocket(url)
        try invalid.send(Data(repeating: 65, count: 4_097))
        XCTAssertTrue(try invalid.readToEnd().isEmpty)
        let valid = try ProfileSocket(url)
        try valid.send(request(url))
        try assertProfile(valid.readToEnd(), equals: profile)
    }

    func testExactHeaderAndProfileBoundsAreAccepted() async throws {
        let largestProfile = Data((0..<65_536).map { UInt8($0 % 251) })
        for halfClose in [false, true] {
            let server = CertificateProfileServer(profile: largestProfile)
            let url = try await start(server)
            defer { server.stop() }
            let client = try ProfileSocket(url)
            let prefix = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(url.port!)\r\nX-Pad: "
            let header = prefix + String(repeating: "a", count: 4_096 - prefix.utf8.count - 4) + "\r\n\r\n"
            XCTAssertEqual(header.utf8.count, 4_096)
            try client.send(Data(header.utf8))
            if halfClose { try client.finishWriting() }
            try assertProfile(client.readToEnd(), equals: largestProfile)
        }
    }

    func testInvalidProfileSizesFailBeforeListening() async throws {
        for data in [Data(), Data(repeating: 0, count: 65_537)] {
            let server = CertificateProfileServer(profile: data)
            do { _ = try await start(server); XCTFail("Invalid profile was accepted") }
            catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .invalidProfileSize) }
            server.stop()
        }
    }

    func testEarlyEOFReleasesSlotAndCompleteGETWithEOFSucceeds() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        let incomplete = try ProfileSocket(url)
        try incomplete.send(Data("GET ".utf8))
        try incomplete.finishWriting()
        XCTAssertTrue(try incomplete.readToEnd().isEmpty)
        let complete = try ProfileSocket(url)
        try complete.send(request(url))
        try complete.finishWriting()
        try assertProfile(complete.readToEnd(), equals: profile)
    }

    func testTwoConnectionLimitAndSuccessClosesOtherRequest() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        let first = try ProfileSocket(url)
        let second = try ProfileSocket(url)
        try first.send(Data("G".utf8))
        try second.send(Data("G".utf8))
        // TCP connect may complete before the listener's serialized accept callback.
        try await Task.sleep(nanoseconds: 80_000_000)
        let excess = try ProfileSocket(url)
        XCTAssertTrue(try excess.readToEnd().isEmpty)
        try first.send(request(url).dropFirst())
        try assertProfile(first.readToEnd(), equals: profile)
        XCTAssertTrue(try second.readToEnd().isEmpty)
    }

    func testStopClosesActiveRequestsAndPreventsRestart() async throws {
        // Exercise both already-delivered and queued accepts; do not hide this race with sleep.
        for _ in 0..<20 {
            let server = CertificateProfileServer(profile: profile)
            let url = try await start(server)
            let client = try ProfileSocket(url)
            try client.send(Data("G".utf8))
            server.stop()
            XCTAssertTrue(try client.readToEnd().isEmpty)
            do { _ = try await start(server); XCTFail("Stopped server restarted") }
            catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .stopped) }
            server.stop()
        }
    }

    func testStopCompletionRunsOnceAfterClosingClientsAndListener() async throws {
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        let first = try ProfileSocket(url)
        let second = try ProfileSocket(url)
        try first.send(Data("G".utf8))
        try second.send(Data("G".utf8))
        // Let both accepted connections enter the active header-read state.
        try await Task.sleep(nanoseconds: 80_000_000)

        let stopped = expectation(description: "stop completes exactly once")
        stopped.assertForOverFulfill = true
        server.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertTrue(try first.readToEnd().isEmpty)
        XCTAssertTrue(try second.readToEnd().isEmpty)
        XCTAssertThrowsError(try ProfileSocket(url)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ECONNREFUSED)
        }

        // An already-stopped server must also complete a new stop call once, without
        // reusing or re-firing the callback belonging to the previous invocation.
        let stoppedAgain = expectation(description: "idempotent stop completes exactly once")
        stoppedAgain.assertForOverFulfill = true
        server.stop { stoppedAgain.fulfill() }
        await fulfillment(of: [stoppedAgain], timeout: 2)
        XCTAssertThrowsError(try ProfileSocket(url)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ECONNREFUSED)
        }
    }

    func testStopBeforeStartAndDuplicateStartHaveBoundedCompletions() async throws {
        let stopped = CertificateProfileServer(profile: profile)
        stopped.stop()
        do { _ = try await start(stopped); XCTFail("Stopped server started") }
        catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .stopped) }
        let server = CertificateProfileServer(profile: profile)
        let url = try await start(server)
        defer { server.stop() }
        do { _ = try await start(server); XCTFail("Duplicate start succeeded") }
        catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .alreadyStarted) }
        let client = try ProfileSocket(url)
        try client.send(request(url))
        try assertProfile(client.readToEnd(), equals: profile)
    }

    #if DEBUG
    func testHeaderDeadlineDoesNotExtendForPartialProgress() async throws {
        let server = CertificateProfileServer(profile: profile, testingLifetime: 2, testingHeaderTimeout: 0.4)
        let url = try await start(server)
        defer { server.stop() }
        let client = try ProfileSocket(url)
        let started = ProcessInfo.processInfo.systemUptime
        try client.send(Data("G".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        try client.send(Data("E".utf8))
        XCTAssertTrue(try client.readToEnd().isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.6)
        let valid = try ProfileSocket(url)
        try valid.send(request(url))
        try assertProfile(valid.readToEnd(), equals: profile)
    }

    func testAbsoluteLifetimeExpiresDespiteActiveRequest() async throws {
        let server = CertificateProfileServer(profile: profile, testingLifetime: 0.2, testingHeaderTimeout: 2)
        let url = try await start(server)
        let client = try ProfileSocket(url)
        let started = ProcessInfo.processInfo.systemUptime
        try client.send(Data("G".utf8))
        XCTAssertTrue(try client.readToEnd().isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.7)
        do { _ = try await start(server); XCTFail("Expired server restarted") }
        catch { XCTAssertEqual(error as? CertificateProfileServer.ServerError, .stopped) }
    }
    #endif

    private func request(_ url: URL) -> Data {
        Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(url.port!)\r\n\r\n".utf8)
    }

    private func start(_ server: CertificateProfileServer) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            server.start { continuation.resume(with: $0) }
        }
    }

    private func assertProfile(_ response: Data, equals expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let end = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)), file: file, line: line)
        XCTAssertTrue(response.starts(with: Data("HTTP/1.1 200 OK\r\n".utf8)), file: file, line: line)
        XCTAssertEqual(Data(response[end.upperBound...]), expected, file: file, line: line)
        XCTAssertTrue(String(decoding: response[..<end.lowerBound], as: UTF8.self)
            .contains("Content-Length: \(expected.count)"), file: file, line: line)
    }
}

/// Wire-level local peer with hard I/O timeouts, independent of Network.framework callbacks.
private final class ProfileSocket {
    private let fd: Int32

    init(_ url: URL) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(url.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += sent
            }
        }
    }

    func finishWriting() throws {
        guard shutdown(fd, SHUT_WR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func readToEnd() throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while result.count <= 70_000 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 || (count < 0 && errno == ECONNRESET) { return result }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw POSIXError(.EFBIG)
    }

    deinit { Darwin.close(fd) }
}
