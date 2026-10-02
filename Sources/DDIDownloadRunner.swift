import Foundation

final class DDITransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?

    func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func setTask(_ task: URLSessionTask?) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task?.cancel() }
    }
}

enum DDIDownloadRunner {
    private static let downloadLock = NSLock()

    struct Timeouts {
        var connection: TimeInterval = 15
        var stalled: TimeInterval = 20
        var resource: TimeInterval = 600
    }

    static func download(to paths: DDIPaths, method: DDIMountMethod = .current,
                         catalog: DDIAssetCatalog,
                         configuration: URLSessionConfiguration = .ephemeral,
                         timeouts: Timeouts = Timeouts(),
                         cancellation: DDITransferCancellation = DDITransferCancellation(),
                         cancellationCheck: @escaping () throws -> Void = {},
                         progress: @escaping (Double, String) -> Void) throws {
        while !downloadLock.try() {
            try cancellation.check()
            try cancellationCheck()
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { downloadLock.unlock() }
        try cancellation.check()
        try cancellationCheck()
        let items = try DDIDownloadCatalog.items(for: paths, method: method, catalog: catalog)
        let directory = paths.receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".ddi-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        var completedSource = "mirror"
        for item in items {
            try cancellation.check()
            try cancellationCheck()
            let file = DDIAssetCatalog.File(name: item.name, size: item.size, sha256: item.sha256)
            let destination = staging.appendingPathComponent(item.name)
            let baseline = completed
            var finalError: Error?
            for (index, url) in [item.url, item.fallbackURL].enumerated() {
                try cancellation.check()
                try cancellationCheck()
                let source = index == 0 ? "mirror" : "upstream"
                if index == 1 {
                    progress(Double(completed) / Double(total), status("fallback", source, item.name, 0, item.size))
                }
                do {
                    let transfer = DDIFileTransfer(destination: destination, expectedSize: item.size,
                                                   timeouts: timeouts) { bytes in
                        progress(Double(baseline + bytes) / Double(total), status("downloading", source, item.name, bytes, item.size))
                    }
                    try transfer.run(url: url, configuration: configuration, cancellation: cancellation, cancellationCheck: cancellationCheck)
                    progress(Double(completed + item.size) / Double(total), status("verifying", source, item.name, item.size, item.size))
                    try DDICache.verify(destination, file: file)
                    finalError = nil
                    completedSource = source
                    break
                } catch {
                    try cancellation.check()
                    try cancellationCheck()
                    finalError = error
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            if let finalError {
                throw StikJITError.ddiDownload("\(item.name): both download sources failed; \(finalError.localizedDescription)")
            }
            completed += item.size
        }
        try cancellation.check()
        try cancellationCheck()
        if let last = items.last { progress(1, status("committing", completedSource, last.name, last.size, last.size)) }
        try DDICache.commit(staging: staging, paths: paths, method: method, catalog: catalog)
    }

    private static func status(_ phase: String, _ source: String, _ name: String, _ bytes: Int64, _ total: Int64) -> String {
        "ddi|\(phase)|\(source)|\(name)|\(bytes)|\(total)"
    }
}

// Stream into a temporary file: large DMGs never accumulate in memory, including
// on a server that ignores Content-Length. The pinned catalog is the size limit.
private final class DDIFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let timeouts: DDIDownloadRunner.Timeouts
    private let progress: (Int64) -> Void
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var startedAt: TimeInterval = 0
    private var lastActivity: TimeInterval = 0
    private var lastReport: TimeInterval = 0
    private var receivedResponse = false
    private var finished = false
    private var failure: Error?
    private var allowedHost: String?

    init(destination: URL, expectedSize: Int64, timeouts: DDIDownloadRunner.Timeouts,
         progress: @escaping (Int64) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.timeouts = timeouts
        self.progress = progress
    }

    func run(url: URL, configuration: URLSessionConfiguration, cancellation: DDITransferCancellation,
             cancellationCheck: () throws -> Void) throws {
        try cancellation.check()
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StikJITError.ddiDownload("Cannot create a temporary DDI file")
        }
        handle = try FileHandle(forWritingTo: destination)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = max(timeouts.connection, timeouts.stalled)
        configuration.timeoutIntervalForResource = timeouts.resource
        configuration.waitsForConnectivity = false
        // Do not hand a Wi-Fi download over to cellular while path callbacks arrive.
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.allowsCellularAccess = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        allowedHost = url.host
        startedAt = ProcessInfo.processInfo.systemUptime
        lastActivity = startedAt
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + min(1, timeouts.connection), repeating: min(1, timeouts.connection))
        timer.setEventHandler { [weak self, weak task] in self?.checkTimeout(task: task) }
        cancellation.setTask(task)
        progress(0)
        timer.resume()
        task.resume()
        var cancellationError: Error?
        while completed.wait(timeout: .now() + 0.2) == .timedOut {
            do { try cancellationCheck() }
            catch { cancellationError = error; cancellation.cancel() }
        }
        timer.cancel()
        cancellation.setTask(nil)
        session.invalidateAndCancel()
        if let cancellationError { throw cancellationError }
        try cancellation.check()
        try cancellationCheck()
        if let failure { throw failure }
        guard received == expectedSize else { throw StikJITError.ddiDownload("Incomplete DDI response (\(received)/\(expectedSize) bytes)") }
    }

    private func checkTimeout(task: URLSessionTask?) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let expired = !finished && (now - startedAt >= timeouts.resource ||
            (!receivedResponse && now - startedAt >= timeouts.connection) ||
            (receivedResponse && now - lastActivity >= timeouts.stalled))
        if expired && failure == nil {
            failure = StikJITError.ddiDownload(receivedResponse ? "DDI download stalled; connection timed out" : "DDI server connection timed out")
        }
        lock.unlock()
        if expired { task?.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        receivedResponse = true
        lastActivity = ProcessInfo.processInfo.systemUptime
        if let response = response as? HTTPURLResponse, response.statusCode == 200 {
            if response.expectedContentLength >= 0 && response.expectedContentLength != expectedSize {
                failure = StikJITError.ddiDownload("DDI server returned an unexpected file size")
            }
        } else {
            failure = StikJITError.ddiDownload("DDI server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let accept = failure == nil
        lock.unlock()
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard failure == nil, !finished else { lock.unlock(); dataTask.cancel(); return }
        do {
            guard received + Int64(data.count) <= expectedSize else {
                throw StikJITError.ddiDownload("DDI response exceeded its verified size")
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            lastActivity = ProcessInfo.processInfo.systemUptime
            let report = lastActivity - lastReport >= 0.15 || received == expectedSize
            if report { lastReport = lastActivity }
            let bytes = received
            lock.unlock()
            if report { progress(bytes) }
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if failure == nil { failure = error }
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        finished = true
        lock.unlock()
        completed.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Both configured endpoints serve immutable objects directly. A redirect
        // must not silently move a download onto an unrelated host or plain HTTP.
        completionHandler(request.url?.scheme == "https" && request.url?.host == allowedHost ? request : nil)
    }
}
