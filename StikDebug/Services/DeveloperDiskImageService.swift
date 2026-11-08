//
//  DeveloperDiskImageService.swift
//  StikDebug
//

import Foundation

/// Prepares the optional DDI cache from files shipped inside the IPA.
/// Missing or damaged app resources fail locally; there is no download fallback.
final class DeveloperDiskImageService {
    static let shared = DeveloperDiskImageService()
    static let directoryURL = URL.documentsDirectory.appendingPathComponent("DDI", isDirectory: true)
    static var usesCryptexDDI: Bool { shared.assetSet.method == .cryptex }
    static var filesAreReady: Bool { shared.cachedFilesAreReady }
    static var requiredFileNames: [String] { shared.assetSet.files.map(\.fileName) }
    static var missingFiles: [String] { shared.missingOrInvalidFiles }

    typealias Copier = @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    private let fileManager: FileManager
    private let cacheDirectoryURL: URL
    private let bundleDirectoryURL: URL
    private let assetSet: DDIAssetSet
    private let copier: Copier?
    private let installationLock = NSLock()
    private var installationInProgress = false
    private static let receiptName = ".asset-set"

    init(fileManager: FileManager = .default,
         directoryURL: URL = DeveloperDiskImageService.directoryURL,
         bundleDirectoryURL: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("DDI", isDirectory: true),
         assetSet: DDIAssetSet = .current(), copier: Copier? = nil) {
        self.fileManager = fileManager
        self.cacheDirectoryURL = directoryURL
        self.bundleDirectoryURL = bundleDirectoryURL
        self.assetSet = assetSet
        self.copier = copier
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

    func prepareMissingFiles(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await installItems(force: false, progressHandler: progressHandler)
    }

    func restoreBundledFiles(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await installItems(force: true, progressHandler: progressHandler)
    }

    private func installItems(force: Bool, progressHandler: (@Sendable (Double, String) -> Void)?) async throws {
        guard beginInstallation() else { throw DDIAssetError.installationInProgress }
        defer { endInstallation() }
        try Task.checkCancellation()
        if !force && cachedFilesAreReady {
            progressHandler?(1, "DDI 内置文件已准备完成".localized)
            return
        }

        // Verified staging is isolated by asset release and mount method. A failed
        // or cancelled copy never replaces a file in the active complete cache.
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
            let report: @Sendable (Double) -> Void = { [count = assetSet.files.count] value in
                progressHandler?((Double(index) + min(1, max(0, value))) / Double(count), detail)
            }
            report(0)
            let source = assetSet.bundledURL(for: item, in: bundleDirectoryURL)
            do {
                if let copier {
                    try await copier(source, destination, report)
                } else {
                    try copyBundledFile(from: source, to: destination, item: item, progress: report)
                }
                try Task.checkCancellation()
                try assetSet.verifyFile(at: destination, item: item)
            } catch {
                // Incomplete bytes must never be mistaken for resumable verified data.
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        try Task.checkCancellation()
        for item in assetSet.files { try assetSet.verifyFile(at: staging.appendingPathComponent(item.fileName), item: item) }
        try assetSet.cacheKey.write(to: staging.appendingPathComponent(Self.receiptName), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        // The commit is not interrupted halfway through: the complete directory
        // and receipt replace the old set together, including obsolete extra files.
        if fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            _ = try fileManager.replaceItemAt(cacheDirectoryURL, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: cacheDirectoryURL)
        }
        progressHandler?(1, "DDI 内置文件已准备完成".localized)
    }

    private func copyBundledFile(from source: URL, to destination: URL, item: DDIAssetFile,
                                 progress: @Sendable (Double) -> Void) throws {
        guard source.isFileURL,
              let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DDIAssetError.missingBundledFile(item.fileName)
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == item.size else {
            throw DDIAssetError.invalidFile(item.fileName)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            guard Int64(data.count) <= item.size - copied else { throw DDIAssetError.invalidFile(item.fileName) }
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            copied += Int64(data.count)
            progress(Double(copied) / Double(item.size))
        }
        guard copied == item.size else { throw DDIAssetError.invalidFile(item.fileName) }
        try output.synchronize()
    }

    private func beginInstallation() -> Bool {
        installationLock.lock()
        defer { installationLock.unlock() }
        guard !installationInProgress else { return false }
        installationInProgress = true
        return true
    }

    private func endInstallation() {
        installationLock.lock()
        defer { installationLock.unlock() }
        installationInProgress = false
    }
}

enum DDIAssetError: LocalizedError {
    case missingBundledFile(String)
    case invalidFile(String)
    case installationInProgress

    var errorDescription: String? {
        switch self {
        case .missingBundledFile(let name):
            return String(format: "IPA 缺少内置 DDI 文件：%@，请重新安装完整版本。".localized, name)
        case .invalidFile(let name):
            return String(format: "内置 DDI 文件校验失败：%@，请重新安装完整版本。".localized, name)
        case .installationInProgress:
            return "DDI 正在准备，请等待当前任务完成。".localized
        }
    }
}
