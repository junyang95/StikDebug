import CryptoKit
import Foundation

private struct AccessReply {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var chunks: [Data] = []
    var redirect: URL?
    var error: URLError?
    var waits = false
}

private final class AccessProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest, Int) -> AccessReply)?
    private var recorded: [URLRequest] = []
    private var stopped = 0
    func reset(_ handler: @escaping (URLRequest, Int) -> AccessReply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; recorded = []; stopped = 0
    }
    func response(_ request: URLRequest) -> AccessReply {
        lock.lock(); recorded.append(request); let count = recorded.count; let block = handler; lock.unlock()
        return block?(request, count) ?? AccessReply(error: URLError(.badServerResponse))
    }
    func stop() { lock.lock(); stopped += 1; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
}

private final class AccessURLProtocol: URLProtocol {
    static let state = AccessProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.response(request)
        if reply.waits { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.stop() }
}

@main
enum WowDeviceAccessTests {
    static let udid = "test-device-not-a-real-udid"
    static let nonce = "test-request-nonce"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let key = P256.Signing.PrivateKey()
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func rejects(_ expected: WowDeviceAccessError, _ action: () throws -> Void) throws {
        do { try action() } catch let error as WowDeviceAccessError {
            try expect(error == expected, "Expected \(expected), got \(error)"); return
        }
        throw Failure(description: "Expected refusal \(expected)")
    }
    static func rejectsAsync(_ expected: WowDeviceAccessError, _ action: () async throws -> Void) async throws {
        do { try await action() } catch let error as WowDeviceAccessError {
            try expect(error == expected, "Expected \(expected), got \(error)"); return
        }
        throw Failure(description: "Expected async refusal \(expected)")
    }
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func license(status: String = "UNKNOWN", vip: Bool = false, banned: Bool = false,
                        device: String = udid, challenge: String = nonce,
                        timestamp: Double = now.timeIntervalSince1970 * 1000,
                        expiry: Double = 0) -> [String: Any] {
        ["udid": device, "status": status, "isVip": vip, "isBanned": banned,
         "nonce": challenge, "ts": timestamp, "expireAt": expiry]
    }
    static func envelope(_ value: [String: Any], signingKey: P256.Signing.PrivateKey = key) throws -> Data {
        let payload = try json(value)
        let signature = try signingKey.signature(for: payload)
        return try json(["payload": payload.base64EncodedString(), "sig": signature.derRepresentation.base64EncodedString(),
                         "pub": signingKey.publicKey.x963Representation.base64EncodedString()])
    }
    static func verify(_ data: Data, challenge: String = nonce, publicKey: Data = key.publicKey.x963Representation) throws {
        try WowDeviceAccess.verifyLicense(data, udid: udid, nonce: challenge, now: now, publicKey: publicKey)
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccessURLProtocol.self]
        return config
    }
    static func client(timeout: TimeInterval = 25) -> WowDeviceAccessClient {
        WowDeviceAccessClient(configuration: configuration(), publicKey: key.publicKey.x963Representation,
                              now: { now }, timeout: timeout)
    }
    private static func allowRequest(_ request: URLRequest) -> AccessReply {
        if request.url?.path == "/api/checkVipInfo.action" {
            return AccessReply(chunks: [try! json(["code": 0, "data": ["device": udid, "pays": [["unused": "never decoded"]]]])])
        }
        return AccessReply(chunks: [try! envelope(license(challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE") ?? ""))])
    }

    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Registration requires code zero and matching device, ignoring unrelated fields", {
                try WowDeviceAccess.verifyRegistration(json(["code": 0, "data": ["device": udid.uppercased(), "pays": ["irrelevant"], "isVip": false]]), udid: udid)
            }),
            ("Unregistered response is distinct from server or identity errors", {
                for code in [1, 2] {
                    try rejects(.notRegistered) { try WowDeviceAccess.verifyRegistration(json(["code": code]), udid: udid) }
                }
                try rejects(.invalidResponse) { try WowDeviceAccess.verifyRegistration(json(["code": 9]), udid: udid) }
                try rejects(.invalidResponse) { try WowDeviceAccess.verifyRegistration(json(["code": 0, "data": ["device": "different-device"]]), udid: udid) }
            }),
            ("Missing registration schema never grants access", {
                for object: [String: Any] in [[:], ["code": 0], ["code": 0, "data": [:]]] {
                    try rejects(.serverUnsupported) { try WowDeviceAccess.verifyRegistration(json(object), udid: udid) }
                }
                try rejects(.invalidResponse) { try WowDeviceAccess.verifyRegistration(Data("maintenance".utf8), udid: udid) }
            }),
            ("Registered non-VIP and expired VIP licenses pass non-ban policy", {
                try verify(envelope(license(status: "UNKNOWN", vip: false)))
                try verify(envelope(license(status: "EXPIRED", vip: false, expiry: 1)))
                try verify(envelope(license(status: "EXPIRED", vip: true, expiry: 1)))
                try verify(envelope(license(status: "VALID", vip: true, expiry: 0)))
            }),
            ("Either authenticated ban flag or BANNED status refuses use", {
                try rejects(.banned) { try verify(envelope(license(status: "VALID", vip: true, banned: true))) }
                try rejects(.banned) { try verify(envelope(license(status: "BANNED", vip: false, banned: false))) }
            }),
            ("License requires each signed identity and policy field", {
                for field in ["udid", "status", "isVip", "isBanned", "expireAt", "nonce", "ts"] {
                    var value = license(); value.removeValue(forKey: field)
                    try rejects(.serverUnsupported) { try verify(envelope(value)) }
                }
                var malformed = license(); malformed["isBanned"] = "false"
                try rejects(.invalidResponse) { try verify(envelope(malformed)) }
            }),
            ("Unknown signed status refuses access", {
                try rejects(.serverUnsupported) { try verify(envelope(license(status: "MAYBE"))) }
            }),
            ("Signature verification uses pinned key, never envelope pub", {
                let attacker = P256.Signing.PrivateKey()
                try rejects(.invalidResponse) { try verify(envelope(license(), signingKey: attacker)) }
                try rejects(.invalidResponse) { try WowDeviceAccess.verifyLicense(envelope(license()), udid: udid, nonce: nonce, now: now) }
                let original = try envelope(license())
                var parsed = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                parsed["pub"] = "not-even-a-key"
                try verify(json(parsed))
            }),
            ("Changed payload and malformed signature are rejected", {
                var value = try JSONSerialization.jsonObject(with: envelope(license())) as! [String: Any]
                value["payload"] = try json(license(status: "VALID", vip: true)).base64EncodedString()
                try rejects(.invalidResponse) { try verify(json(value)) }
                value["sig"] = "not-base64"
                try rejects(.invalidResponse) { try verify(json(value)) }
            }),
            ("Signed identity and nonce must match this request", {
                try rejects(.invalidResponse) { try verify(envelope(license(device: "another-device"))) }
                try rejects(.invalidResponse) { try verify(envelope(license(challenge: "old-request"))) }
                try rejects(.invalidResponse) { try verify(envelope(license()), challenge: "") }
                try verify(envelope(license(device: udid.uppercased())))
            }),
            ("Stale, future, and invalid license timestamps are rejected", {
                for delta in [-301.0, 301.0] {
                    try rejects(.invalidResponse) { try verify(envelope(license(timestamp: (now.timeIntervalSince1970 + delta) * 1000))) }
                }
                try rejects(.invalidResponse) { try verify(envelope(license(timestamp: 0))) }
                try rejects(.invalidResponse) { try verify(envelope(license(expiry: -1))) }
                try verify(envelope(license(timestamp: (now.timeIntervalSince1970 - 299) * 1000)))
            }),
            ("Bodies are bounded and device headers reject injection", {
                try rejects(.invalidResponse) { try WowDeviceAccess.verifyRegistration(Data(repeating: 32, count: WowDeviceAccess.maximumResponseBytes + 1), udid: udid) }
                for device in ["", "device\r\nInjected: yes", "abc\0def", "device name", String(repeating: "a", count: 129)] {
                    try rejects(.deviceUnavailable) { try WowDeviceAccess.validateDeviceIdentifier(device) }
                }
            }),
            ("Client sends two ordered fresh GET requests to fixed HTTPS endpoints", {
                AccessURLProtocol.state.reset { request, _ in allowRequest(request) }
                try await client().verify(udid: udid)
                let requests = AccessURLProtocol.state.requests
                try expect(requests.map { $0.url?.path } == ["/api/checkVipInfo.action", "/api/vip-license.action"], "Unexpected endpoint order")
                for request in requests {
                    try expect(request.url?.scheme == "https" && request.url?.host == "wow-app.store", "Unexpected destination")
                    try expect(request.httpMethod == "GET" && request.httpBody == nil, "Unexpected mutation request")
                    try expect(request.value(forHTTPHeaderField: "DEVICE_UDID") == udid, "Missing device binding")
                    try expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "Response caching enabled")
                    try expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store, no-cache", "Missing no-cache policy")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "Unexpected credentials")
                }
                let challenge = requests[0].value(forHTTPHeaderField: "X-VIP-NONCE")
                try expect(challenge?.isEmpty == false && requests[1].value(forHTTPHeaderField: "X-VIP-NONCE") == challenge, "Challenge not shared within verification")
            }),
            ("Each verification makes new requests with a new nonce", {
                AccessURLProtocol.state.reset { request, _ in allowRequest(request) }
                let client = client()
                try await client.verify(udid: udid); try await client.verify(udid: udid)
                let requests = AccessURLProtocol.state.requests
                try expect(requests.count == 4, "Previous admission was reused")
                try expect(requests[0].value(forHTTPHeaderField: "X-VIP-NONCE") != requests[2].value(forHTTPHeaderField: "X-VIP-NONCE"), "Challenge reused between requests")
            }),
            ("Unregistered devices stop before the signed-license request", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(chunks: [try! json(["code": 2])]) }
                try await rejectsAsync(.notRegistered) { try await client().verify(udid: udid) }
                try expect(AccessURLProtocol.state.requests.count == 1, "Unregistered verification continued")
            }),
            ("Signed ban is enforced even after successful registration", {
                AccessURLProtocol.state.reset { request, _ in
                    if request.url?.path == "/api/checkVipInfo.action" { return allowRequest(request) }
                    return AccessReply(chunks: [try! envelope(license(status: "BANNED", banned: true, challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE")!))])
                }
                try await rejectsAsync(.banned) { try await client().verify(udid: udid) }
            }),
            ("Network failure after an earlier grant does not allow offline use", {
                AccessURLProtocol.state.reset { request, index in index <= 2 ? allowRequest(request) : AccessReply(error: URLError(.notConnectedToInternet)) }
                let client = client()
                try await client.verify(udid: udid)
                try await rejectsAsync(.networkUnavailable) { try await client.verify(udid: udid) }
            }),
            ("HTTP failures never become admission or ban verdicts", {
                for status in [302, 401, 403, 429, 500, 524] {
                    AccessURLProtocol.state.reset { _, _ in AccessReply(status: status, chunks: [try! json(["code": 0, "data": ["device": udid]])]) }
                    try await rejectsAsync(.networkUnavailable) { try await client().verify(udid: udid) }
                }
            }),
            ("Redirects are refused without forwarding device identity", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(status: 302, redirect: URL(string: "https://different.example/collect")) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
                try expect(AccessURLProtocol.state.requests.count == 1, "Redirect followed to a second request")
            }),
            ("Oversized declared bodies are refused before decoding", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(headers: ["Content-Type": "application/json", "Content-Length": String(WowDeviceAccess.maximumResponseBytes + 1)], chunks: [Data("{}".utf8)]) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
            }),
            ("Oversized streamed bodies are bounded without Content-Length", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(chunks: [Data(repeating: 32, count: WowDeviceAccess.maximumResponseBytes), Data([32])]) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
            }),
            ("Malformed successful HTTP response still refuses access", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(chunks: [Data("<html>maintenance</html>".utf8)]) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
            }),
            ("Cancellation cancels the underlying pending request", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(waits: true) }
                let task = Task { try await client().verify(udid: udid) }
                while AccessURLProtocol.state.requests.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
                task.cancel()
                try await rejectsAsync(.cancelled) { try await task.value }
            }),
            ("Whole verification deadline bounds pending connectivity", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(waits: true) }
                let start = Date()
                try await rejectsAsync(.networkUnavailable) { try await client(timeout: 0.03).verify(udid: udid) }
                try expect(Date().timeIntervalSince(start) < 2, "Verification did not honor its deadline")
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) Wow device-access tests passed; all HTTP requests were intercepted locally.")
        if failures > 0 { exit(EXIT_FAILURE) }
    }
}
