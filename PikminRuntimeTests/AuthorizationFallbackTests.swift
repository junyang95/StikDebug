import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

private struct FallbackLicenseFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = P256.Signing.PrivateKey()

    func envelope(
        udid: String = "test-device", nonce: String = "test-nonce",
        status: String = "VALID", vip: Bool = true, banned: Bool = false,
        timestamp: Date? = nil
    ) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "udid": udid, "nonce": nonce, "status": status,
            "isVip": vip, "isBanned": banned, "expireAt": 0,
            "ts": (timestamp ?? now).timeIntervalSince1970 * 1000
        ])
        return try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "sig": key.signature(for: payload).derRepresentation.base64EncodedString()
        ])
    }

    func request(_ transport: FallbackTransport, timeout: TimeInterval = 1) async throws -> Data {
        let timestamp = now
        return try await AuthorizationEndpointFallback.request(
            udid: "test-device", nonce: "test-nonce", endpointTimeout: timeout,
            publicKey: key.publicKey.x963Representation, now: { timestamp }
        ) { try await transport.send($0) }
    }
}

private actor FallbackTransport {
    enum Step {
        case response(Int, Data)
        case failure(URLError.Code)
        case stalled
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var started: CheckedContinuation<Void, Never>?

    init(_ steps: [Step]) { self.steps = steps }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        started?.resume()
        started = nil
        guard !steps.isEmpty else { throw URLError(.resourceUnavailable) }
        switch steps.removeFirst() {
        case let .response(status, data):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .failure(code):
            throw URLError(code)
        case .stalled:
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
    }
}

@Suite struct AuthorizationFallbackTests {
    @Test func freshSignedNonceCanRecoverADeviceClockFarFromServerTime() async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope(timestamp: fixture.now.addingTimeInterval(-30 * 86400))
        let transport = FallbackTransport([.response(200, valid)])
        let result = try await fixture.request(transport)
        #expect(result == valid)
        #expect(await transport.requests.count == 1)
    }

    @Test func validPrimaryDoesNotContactBackup() async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope()
        let transport = FallbackTransport([.response(200, valid)])
        let result = try await fixture.request(transport)
        let requests = await transport.requests
        #expect(result == valid)
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://app-shop.cn/api/vip-license.action")
        #expect(requests.first?.value(forHTTPHeaderField: "DEVICE_UDID") == "test-device")
        #expect(requests.first?.value(forHTTPHeaderField: "X-VIP-NONCE") == "test-nonce")
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .dnsLookupFailed, .timedOut, .cannotConnectToHost])
    func networkFailureUsesBackupWithSameIdentityAndNonce(_ code: URLError.Code) async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope()
        let transport = FallbackTransport([.failure(code), .response(200, valid)])
        let result = try await fixture.request(transport)
        let requests = await transport.requests
        #expect(result == valid)
        #expect(requests.map { $0.url?.host } == ["app-shop.cn", "wow-app.store"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "DEVICE_UDID") == "test-device" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-VIP-NONCE") == "test-nonce" })
    }

    @Test(arguments: [403, 429, 500, 502, 503, 504])
    func httpErrorTriesBackup(_ status: Int) async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope()
        let transport = FallbackTransport([.response(status, Data()), .response(200, valid)])
        let result = try await fixture.request(transport)
        #expect(result == valid)
        #expect(await transport.requests.count == 2)
    }

    @Test func invalidCandidateCannotStopFallback() async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope()
        let invalidCandidates = [
            Data("<html>Maintenance</html>".utf8),
            try fixture.envelope(udid: "different-device"),
            try fixture.envelope(nonce: "old-nonce"),
            try fixture.envelope(timestamp: Date(timeIntervalSince1970: 0)),
            try FallbackLicenseFixture().envelope()
        ]
        for invalid in invalidCandidates {
            let transport = FallbackTransport([.response(200, invalid), .response(200, valid)])
            let result = try await fixture.request(transport)
            #expect(result == valid)
            #expect(await transport.requests.count == 2)
        }
    }

    @Test(arguments: ["BANNED", "EXPIRED", "NOT_VIP"])
    func authenticatedDenialStopsFallback(_ status: String) async throws {
        let fixture = FallbackLicenseFixture()
        let denied = try fixture.envelope(status: status, vip: status != "NOT_VIP", banned: status == "BANNED")
        let transport = FallbackTransport([.response(200, denied), .response(200, try fixture.envelope())])
        let result = try await fixture.request(transport)
        #expect(result == denied)
        #expect(await transport.requests.count == 1)
    }

    @Test func authenticatedBanFlagAlsoStopsFallback() async throws {
        let fixture = FallbackLicenseFixture()
        let denied = try fixture.envelope(banned: true)
        let transport = FallbackTransport([.response(200, denied), .response(200, try fixture.envelope())])
        let result = try await fixture.request(transport)
        #expect(result == denied)
        #expect(await transport.requests.count == 1)
    }

    @Test func stalledPrimaryLeavesTimeForBackup() async throws {
        let fixture = FallbackLicenseFixture()
        let valid = try fixture.envelope()
        let transport = FallbackTransport([.stalled, .response(200, valid)])
        let result = try await fixture.request(transport, timeout: 0.05)
        #expect(result == valid)
        #expect(await transport.requests.count == 2)
    }

    @Test func exhaustionThrowsInsteadOfReturningUnverifiedData() async throws {
        let fixture = FallbackLicenseFixture()
        let transport = FallbackTransport([.failure(.cannotFindHost), .response(200, Data("maintenance".utf8))])
        do {
            _ = try await fixture.request(transport)
            Issue.record("Unverified response must never grant authorization")
        } catch {
            #expect(!(error is CancellationError))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func cancellationStopsWithoutContactingBackup() async throws {
        let fixture = FallbackLicenseFixture()
        let transport = FallbackTransport([.stalled, .response(200, try fixture.envelope())])
        let request = Task { try await fixture.request(transport) }
        await transport.waitForRequest()
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled authorization must throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func transportCancellationIsNotAnEndpointFailure() async throws {
        let fixture = FallbackLicenseFixture()
        let transport = FallbackTransport([.failure(.cancelled), .response(200, try fixture.envelope())])
        do {
            _ = try await fixture.request(transport)
            Issue.record("Transport cancellation must propagate")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await transport.requests.count == 1)
    }
}
