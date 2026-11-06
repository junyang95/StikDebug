import Foundation

/// Fixed HTTPS destinations, bounded response streams and independent endpoint deadlines.
/// Only authenticated registration/non-ban evidence can issue a seven-day grant.
struct WowDeviceAccessClient: @unchecked Sendable {
    static let endpoints = ["https://app-shop.cn/api/vip-license.action", "https://wow-app.store/api/vip-license.action"]
    private let configuration: URLSessionConfiguration
    private let publicKey: Data
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String
    private let timeout: TimeInterval

    init(configuration: URLSessionConfiguration = .ephemeral,
         publicKey: Data = WowDeviceAccess.publicKey,
         now: @escaping @Sendable () -> Date = { Date() },
         nonce: @escaping @Sendable () -> String = { UUID().uuidString },
         timeout: TimeInterval = 10) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.timeoutIntervalForRequest = 10
        copy.timeoutIntervalForResource = 10
        copy.waitsForConnectivity = true
        copy.allowsCellularAccess = true
        copy.allowsExpensiveNetworkAccess = true
        copy.allowsConstrainedNetworkAccess = true
        self.configuration = copy
        self.publicKey = publicKey
        self.now = now
        self.nonce = nonce
        self.timeout = timeout.isFinite ? min(10, max(0.01, timeout)) : 10
    }

    func verify(udid: String) async throws {
        _ = try await requestLicense(udid: udid, nonce: nonce())
    }

    func requestLicense(udid: String, nonce challenge: String) async throws -> Data {
        try WowDeviceAccess.validateDeviceIdentifier(udid)
        guard !challenge.isEmpty, challenge.utf8.count <= 128,
              challenge.utf8.allSatisfy({ (33...126).contains($0) }) else { throw WowDeviceAccessError.invalidResponse }
        var lastError: WowDeviceAccessError = .networkUnavailable
        var sawUnsupportedServer = false
        for endpoint in Self.endpoints {
            do {
                try Task.checkCancellation()
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await request(endpoint: endpoint, udid: udid, challenge: challenge) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw WowDeviceAccessError.networkUnavailable
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                _ = try WowDeviceAccess.verifiedLicense(data, udid: udid, nonce: challenge, now: now(), publicKey: publicKey)
                return data
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? WowDeviceAccessError) == .cancelled {
                    throw WowDeviceAccessError.cancelled
                }
                let failure = (error as? WowDeviceAccessError) ?? .networkUnavailable
                if failure == .banned || failure == .notRegistered { throw failure }
                if failure == .serverUnsupported { sawUnsupportedServer = true }
                lastError = failure
            }
        }
        // A reachable old server cannot grant a new offline window, including when
        // the other endpoint is unavailable. Roll out the backend before this client.
        throw sawUnsupportedServer ? WowDeviceAccessError.serverUnsupported : lastError
    }

    private func request(endpoint: String, udid: String, challenge: String) async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("JITLauncher/DeviceAccess", forHTTPHeaderField: "User-Agent")
        request.setValue(udid, forHTTPHeaderField: "DEVICE_UDID")
        request.setValue(challenge, forHTTPHeaderField: "X-VIP-NONCE")
        return try await BoundedAccessRequest().load(request, configuration: configuration)
    }
}

/// Bounds bytes as they arrive; a Content-Length check alone is insufficient for
/// chunked responses. All terminal paths resume the continuation exactly once.
private final class BoundedAccessRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var acceptedResponse = false
    private var buffer = Data()

    func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    continuation.resume(throwing: WowDeviceAccessError.cancelled)
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(WowDeviceAccessError.cancelled))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(WowDeviceAccessError.networkUnavailable))
            return
        }
        guard response.expectedContentLength <= Int64(WowDeviceAccess.maximumResponseBytes) else {
            completionHandler(.cancel)
            finish(.failure(WowDeviceAccessError.invalidResponse))
            return
        }
        lock.lock()
        let active = !completed
        acceptedResponse = active
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard acceptedResponse, data.count <= WowDeviceAccess.maximumResponseBytes - buffer.count else {
            lock.unlock()
            finish(.failure(WowDeviceAccessError.invalidResponse))
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(WowDeviceAccessError.networkUnavailable)); return }
        lock.lock()
        let valid = acceptedResponse
        let data = buffer
        lock.unlock()
        finish(valid ? .success(data) : .failure(WowDeviceAccessError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Even same-host redirects are not part of the fixed API contract. Do
        // not forward a device identifier, nonce or implicit credentials.
        completionHandler(nil)
        finish(.failure(WowDeviceAccessError.invalidResponse))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        self.continuation = nil
        self.session = nil
        self.task = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
