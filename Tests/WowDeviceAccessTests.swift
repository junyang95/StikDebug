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
         "nonce": challenge, "ts": timestamp, "expireAt": expiry, "isRegistered": true]
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
        return AccessReply(chunks: [try! envelope(license(challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE") ?? ""))])
    }

    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Both policies share verified payloads; registered non-VIP and expired VIP pass JIT", {
                for (status, vip, expiry) in [("UNKNOWN", false, 0.0), ("EXPIRED", true, 1.0), ("VALID", true, 0.0)] {
                    let data = try envelope(license(status: status, vip: vip, expiry: expiry))
                    let value = try WowDeviceAccess.verifiedLicense(data, udid: udid, nonce: nonce, now: now, publicKey: key.publicKey.x963Representation)
                    try expect(value.permitsUse(policy: .registeredUnbanned, at: now), "Registered policy denied ordinary device")
                    try expect(value.validUntil(for: .registeredUnbanned) == now.addingTimeInterval(7 * 86400), "VIP expiry shortened JIT grace")
                    if status != "VALID" { try expect(!value.permitsUse(policy: .vip, at: now), "VIP policy was weakened") }
                }
            }),
            ("Signed registration is required; a legacy online registration response is insufficient", {
                var value = license(); value.removeValue(forKey: "isRegistered")
                try rejects(.serverUnsupported) { try verify(envelope(value)) }
                value["isRegistered"] = false
                try rejects(.notRegistered) { try verify(envelope(value)) }
                value["isRegistered"] = "true"
                try rejects(.invalidResponse) { try verify(envelope(value)) }
            }),
            ("Either signed ban indicator overrides registration", {
                try rejects(.banned) { try verify(envelope(license(status: "BANNED"))) }
                try rejects(.banned) { try verify(envelope(license(status: "VALID", banned: true))) }
                var legacy = license(status: "BANNED"); legacy.removeValue(forKey: "isRegistered")
                try rejects(.banned) { try verify(envelope(legacy)) }
            }),
            ("Signature uses pinned key, never envelope pub or modified fields", {
                try rejects(.invalidResponse) { try verify(envelope(license(), signingKey: P256.Signing.PrivateKey())) }
                var value = try JSONSerialization.jsonObject(with: envelope(license())) as! [String: Any]
                value["pub"] = "ignored"
                try verify(json(value))
                value["payload"] = try json(license(status: "VALID", vip: true)).base64EncodedString()
                try rejects(.invalidResponse) { try verify(json(value)) }
            }),
            ("Signed identity and nonce match this request", {
                try rejects(.invalidResponse) { try verify(envelope(license(device: "another-device"))) }
                try rejects(.invalidResponse) { try verify(envelope(license(challenge: "old-request"))) }
                try rejects(.invalidResponse) { try verify(envelope(license()), challenge: "") }
            }),
            ("Fresh nonce permits signed server time to repair a wrong local clock", {
                for delta in [-30.0 * 86400, 30.0 * 86400] {
                    try verify(envelope(license(timestamp: (now.timeIntervalSince1970 + delta) * 1000)))
                }
                try rejects(.invalidResponse) { try verify(envelope(license(timestamp: 0))) }
                try rejects(.invalidResponse) { try verify(envelope(license(expiry: -1))) }
            }),
            ("Primary signed response uses one fresh fixed HTTPS request", {
                AccessURLProtocol.state.reset { request, _ in allowRequest(request) }
                try await client().verify(udid: udid)
                let request = AccessURLProtocol.state.requests[0]
                try expect(AccessURLProtocol.state.requests.count == 1, "Legacy registration endpoint still required")
                try expect(request.url?.absoluteString == "https://app-shop.cn/api/vip-license.action", "Wrong primary")
                try expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "DEVICE_UDID") == udid, "Wrong request")
                try expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "Implicit credentials")
                try expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "Caching enabled")
            }),
            ("Network or HTTP failure tries backup with same identity and nonce", {
                for failure in [AccessReply(error: URLError(.cannotFindHost)), AccessReply(status: 503)] {
                    AccessURLProtocol.state.reset { request, index in index == 1 ? failure : allowRequest(request) }
                    try await client().verify(udid: udid)
                    let requests = AccessURLProtocol.state.requests
                    try expect(requests.map { $0.url?.host } == ["app-shop.cn", "wow-app.store"], "Wrong fallback order")
                    try expect(requests[0].value(forHTTPHeaderField: "X-VIP-NONCE") == requests[1].value(forHTTPHeaderField: "X-VIP-NONCE"), "Fallback nonce changed")
                }
            }),
            ("Authenticated ban or non-registration stops before fallback", {
                for banned in [true, false] {
                    AccessURLProtocol.state.reset { request, _ in
                        var value = license(status: banned ? "BANNED" : "UNKNOWN", challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE")!)
                        value["isRegistered"] = !banned ? false : true
                        return AccessReply(chunks: [try! envelope(value)])
                    }
                    try await rejectsAsync(banned ? .banned : .notRegistered) { try await client().verify(udid: udid) }
                    try expect(AccessURLProtocol.state.requests.count == 1, "Authenticated refusal searched for another grant")
                }
            }),
            ("Old primary can use new backup; two old servers never create a grant", {
                AccessURLProtocol.state.reset { request, index in
                    if index == 2 { return allowRequest(request) }
                    var value = license(challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE")!); value.removeValue(forKey: "isRegistered")
                    return AccessReply(chunks: [try! envelope(value)])
                }
                try await client().verify(udid: udid)
                AccessURLProtocol.state.reset { request, _ in
                    var value = license(challenge: request.value(forHTTPHeaderField: "X-VIP-NONCE")!); value.removeValue(forKey: "isRegistered")
                    return AccessReply(chunks: [try! envelope(value)])
                }
                try await rejectsAsync(.serverUnsupported) { try await client().verify(udid: udid) }
            }),
            ("Invalid signature permits only an independently verified fallback", {
                AccessURLProtocol.state.reset { request, index in
                    index == 1 ? AccessReply(chunks: [try! envelope(license(), signingKey: P256.Signing.PrivateKey())]) : allowRequest(request)
                }
                try await client().verify(udid: udid)
                try expect(AccessURLProtocol.state.requests.count == 2, "Invalid primary accepted")
            }),
            ("Each online verification generates a new challenge", {
                AccessURLProtocol.state.reset { request, _ in allowRequest(request) }
                let instance = client(); try await instance.verify(udid: udid); try await instance.verify(udid: udid)
                let requests = AccessURLProtocol.state.requests
                try expect(requests[0].value(forHTTPHeaderField: "X-VIP-NONCE") != requests[1].value(forHTTPHeaderField: "X-VIP-NONCE"), "Nonce reused")
            }),
            ("Redirect destinations never receive identity", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(status: 302, redirect: URL(string: "https://different.example/collect")) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
                try expect(AccessURLProtocol.state.requests.allSatisfy { ["app-shop.cn", "wow-app.store"].contains($0.url!.host!) }, "Redirect followed")
            }),
            ("Streamed and declared oversized bodies are bounded", {
                for reply in [AccessReply(headers: ["Content-Length": String(WowDeviceAccess.maximumResponseBytes + 1)], chunks: [Data("{}".utf8)]), AccessReply(chunks: [Data(repeating: 32, count: WowDeviceAccess.maximumResponseBytes), Data([32])])] {
                    AccessURLProtocol.state.reset { _, _ in reply }
                    try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
                }
            }),
            ("Malformed response cannot masquerade as an authenticated refusal", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(chunks: [Data("{}".utf8)]) }
                try await rejectsAsync(.invalidResponse) { try await client().verify(udid: udid) }
            }),
            ("Header injection and missing identity are rejected before networking", {
                for device in ["", "device\r\nInjected: yes", "device name", String(repeating: "a", count: 129)] {
                    try rejects(.deviceUnavailable) { try WowDeviceAccess.validateDeviceIdentifier(device) }
                }
            }),
            ("Cancellation cancels pending transport and never tries backup", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(waits: true) }
                let task = Task { try await client().verify(udid: udid) }
                while AccessURLProtocol.state.requests.isEmpty { await Task.yield() }
                task.cancel()
                try await rejectsAsync(.cancelled) { try await task.value }
                try expect(AccessURLProtocol.state.requests.count == 1, "Cancellation tried fallback")
            }),
            ("Each unavailable endpoint has its own bounded deadline", {
                AccessURLProtocol.state.reset { _, _ in AccessReply(waits: true) }
                let start = Date()
                try await rejectsAsync(.networkUnavailable) { try await client(timeout: 0.03).verify(udid: udid) }
                try expect(Date().timeIntervalSince(start) < 2 && AccessURLProtocol.state.requests.count == 2, "Backup did not receive its own deadline")
            })
        ]
        do {
            for (name, test) in tests { try await test(); print("PASS " + name) }
            print("WowDeviceAccessTests: \(tests.count) passed")
        } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
}
