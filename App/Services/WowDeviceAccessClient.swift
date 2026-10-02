import Foundation

/// Uses only fixed HTTPS endpoints and fresh responses. A successful call is not
/// cached: callers must request admission again before the protected operation.
struct WowDeviceAccessClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let publicKey: Data
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String
    private let timeout: TimeInterval

    init(configuration: URLSessionConfiguration = .ephemeral,
         publicKey: Data = WowDeviceAccess.publicKey,
         now: @escaping @Sendable () -> Date = { Date() },
         nonce: @escaping @Sendable () -> String = { UUID().uuidString },
         timeout: TimeInterval = 25) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.timeoutIntervalForRequest = 15
        copy.timeoutIntervalForResource = 25
        copy.waitsForConnectivity = true
        copy.allowsCellularAccess = true
        copy.allowsExpensiveNetworkAccess = true
        copy.allowsConstrainedNetworkAccess = true
        self.configuration = copy
        self.publicKey = publicKey
        self.now = now
        self.nonce = nonce
        self.timeout = timeout.isFinite ? min(25, max(0.01, timeout)) : 25
    }

    func verify(udid: String) async throws {
        try WowDeviceAccess.validateDeviceIdentifier(udid)
        do {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await verifyFresh(udid: udid) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw WowDeviceAccessError.networkUnavailable
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is CancellationError { throw WowDeviceAccessError.cancelled }
        catch let error as WowDeviceAccessError { throw error }
        catch { throw WowDeviceAccessError.networkUnavailable }
    }

    private func verifyFresh(udid: String) async throws {
        let challenge = nonce()
        guard !challenge.isEmpty, challenge.utf8.count <= 128,
              challenge.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw WowDeviceAccessError.invalidResponse
        }
        try Task.checkCancellation()
        let registration = try await request(path: "checkVipInfo.action", udid: udid, challenge: challenge)
        try WowDeviceAccess.verifyRegistration(registration, udid: udid)
        try Task.checkCancellation()
        let license = try await request(path: "vip-license.action", udid: udid, challenge: challenge)
        try Task.checkCancellation()
        try WowDeviceAccess.verifyLicense(license, udid: udid, nonce: challenge, now: now(), publicKey: publicKey)
    }

    private func request(path: String, udid: String, challenge: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://wow-app.store/api/" + path)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
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
