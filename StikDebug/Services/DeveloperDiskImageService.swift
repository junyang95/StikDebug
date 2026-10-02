//
//  DeveloperDiskImageService.swift
//  StikDebug
//

import Foundation

final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()

    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession? = nil) {
        self.fileManager = fileManager
        self.session = session ?? Self.makeEphemeralSession()
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
        if destinationURL.pathExtension == "plist" {
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
        for (index, item) in Self.downloadItems.enumerated() {
            try Task.checkCancellation()
            let destination = URL.documentsDirectory.appendingPathComponent(item.relativePath)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !force && size > 0 { continue }
            let detail = "\(index + 1)/\(Self.downloadItems.count) · \(destination.lastPathComponent)"
            progressHandler?(0, detail)
            try await downloadFile(from: item.urlString, to: destination) { value in progressHandler?(value, detail) }
        }
        progressHandler?(1, "DDI 文件下载完成".localized)
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

    private static let downloadItems: [DDIDownloadItem] = [
        .init(
            name: "Build Manifest",
            relativePath: "DDI/BuildManifest.plist",
            urlString: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
        ),
        .init(
            name: "Image",
            relativePath: "DDI/Image.dmg",
            urlString: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/Image.dmg"
        ),
        .init(
            name: "TrustCache",
            relativePath: "DDI/Image.dmg.trustcache",
            urlString: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
        )
    ]

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

private struct DDIDownloadItem {
    let name: String
    let relativePath: String
    let urlString: String
}

enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "DDI 下载地址无效：".localized + string
        case .invalidResponse:
            return "DDI 下载内容无效，请稍后重新下载。".localized
        case .badStatus(let statusCode):
            return String(format: "DDI 下载服务器返回 HTTP %d，请稍后重试。".localized, statusCode)
        }
    }
}

func redownloadDDI(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
    try await DeveloperDiskImageService.shared.redownload(progressHandler: progressHandler)
}
