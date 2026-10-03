//
//  DeveloperDiskImageService.swift
//  StikDebug
//

import Foundation

final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()
    static let directoryURL = URL.documentsDirectory.appendingPathComponent("DDI", isDirectory: true)
    static var usesCryptexDDI: Bool { shared.assetSet.method == .cryptex }
    static var filesAreReady: Bool { shared.cachedFilesAreReady }
    static var requiredFileNames: [String] { shared.assetSet.files.map(\.fileName) }
    static var missingFiles: [String] { shared.missingOrInvalidFiles }

    typealias Downloader = @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    private let fileManager: FileManager
    private let session: URLSession
    private let cacheDirectoryURL: URL
    private let assetSet: DDIAssetSet
    private let downloader: Downloader?
    private let downloadLock = NSLock()
    private var downloadInProgress = false
    private static let receiptName = ".asset-set"

    init(fileManager: FileManager = .default, session: URLSession? = nil,
         directoryURL: URL = DeveloperDiskImageService.directoryURL,
         assetSet: DDIAssetSet = .current(), downloader: Downloader? = nil) {
        self.fileManager = fileManager
        self.session = session ?? Self.makeEphemeralSession()
        self.cacheDirectoryURL = directoryURL
        self.assetSet = assetSet
        self.downloader = downloader
    }

    var cachedFilesAreReady: Bool { missingOrInvalidFiles.isEmpty }

    private var missingOrInvalidFiles: [String] {
        let receipt = try? String(contentsOf: cacheDirectoryURL.appendingPathComponent(Self.receiptName), encoding: .utf8)
        guard receipt == assetSet.cacheKey else { return assetSet.files.map(\.fileName) }
        return assetSet.files.compactMap { item in
            do {
                try assetSet.verifyFile(at: cacheDirectoryURL.appendingPathComponent(item.fileName), item: item)
                return nil
            } catch { return item.fileName }
        }
    }

    func downloadMissingFiles(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await downloadItems(force: false, progressHandler: progressHandler)
    }

    func downloadFile(from urlString: String, to destinationURL: URL,
                      progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let url = URL(string: urlString), Self.isAllowed(url) else {
            throw DDIDownloadError.invalidURL(urlString)
        }
        let delegate = DownloadDelegate(progress: progressHandler)
        let (temporaryURL, response) = try await session.download(from: url, delegate: delegate)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try installDownloadedFile(at: temporaryURL, response: response, to: destinationURL)
    }

    func installDownloadedFile(at temporaryURL: URL, response: URLResponse, to destinationURL: URL) throws {
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, Self.isAllowed(finalURL) else {
            throw DDIDownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw DDIDownloadError.badStatus(http.statusCode) }
        let handle = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        let text = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !prefix.isEmpty, http.mimeType != "text/html", !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html") else {
            throw DDIDownloadError.invalidResponse
        }
        if ["plist", "cryptex_info"].contains(destinationURL.pathExtension) {
            let data = try Data(contentsOf: temporaryURL)
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
                throw DDIDownloadError.invalidResponse
            }
        }
        try Task.checkCancellation()
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            // Keep the existing file intact if a replacement download fails.
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func redownload(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await downloadItems(force: true, progressHandler: progressHandler)
    }

    private func downloadItems(force: Bool, progressHandler: (@Sendable (Double, String) -> Void)?) async throws {
        guard beginDownload() else { throw DDIDownloadError.downloadInProgress }
        defer { endDownload() }
        try Task.checkCancellation()
        if !force && cachedFilesAreReady {
            progressHandler?(1, "DDI 文件下载完成".localized)
            return
        }

        // Complete files survive a failed/cancelled attempt, but different asset sets
        // never share staging files or replace the active cache one file at a time.
        let staging = cacheDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent(".DDI-staging", isDirectory: true)
            .appendingPathComponent(assetSet.release, isDirectory: true)
            .appendingPathComponent(assetSet.method.rawValue, isDirectory: true)
        if force && fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        for (index, item) in assetSet.files.enumerated() {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(item.fileName)
            if (try? assetSet.verifyFile(at: destination, item: item)) != nil { continue }
            let detail = "\(index + 1)/\(assetSet.files.count) · \(item.fileName)"
            progressHandler?(0, detail)
            let report: @Sendable (Double) -> Void = { value in progressHandler?(value, detail) }
            if let downloader {
                try await downloader(assetSet.url(for: item), destination, report)
            } else {
                try await downloadFile(from: assetSet.url(for: item).absoluteString, to: destination, progressHandler: report)
            }
            try assetSet.verifyFile(at: destination, item: item)
        }
        try Task.checkCancellation()
        for item in assetSet.files { try assetSet.verifyFile(at: staging.appendingPathComponent(item.fileName), item: item) }
        try assetSet.cacheKey.write(to: staging.appendingPathComponent(Self.receiptName), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            _ = try fileManager.replaceItemAt(cacheDirectoryURL, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: cacheDirectoryURL)
        }
        progressHandler?(1, "DDI 文件下载完成".localized)
    }

    private func beginDownload() -> Bool {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        guard !downloadInProgress else { return false }
        downloadInProgress = true
        return true
    }

    private func endDownload() {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        downloadInProgress = false
    }

    private static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == allowedDownloadHost
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: (@Sendable (Double) -> Void)?
        init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map { DeveloperDiskImageService.isAllowed($0) } == true ? request : nil)
        }
    }

    static let allowedDownloadHost = "static.wow-app.store"

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case badStatus(Int)
    case invalidFile(String)
    case downloadInProgress

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "DDI 下载地址无效：".localized + string
        case .invalidResponse:
            return "DDI 下载内容无效，请稍后重新下载。".localized
        case .badStatus(let statusCode):
            return String(format: "DDI 下载服务器返回 HTTP %d，请稍后重试。".localized, statusCode)
        case .invalidFile(let name):
            return String(format: "DDI 文件校验失败：%@，请重新下载。".localized, name)
        case .downloadInProgress:
            return "DDI 正在下载，请等待当前任务完成。".localized
        }
    }
}

func redownloadDDI(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
    try await DeveloperDiskImageService.shared.redownload(progressHandler: progressHandler)
}
