import Foundation

final class DDIInstallationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Installs one complete, hash-verified family from the app's read-only resources.
/// A missing or damaged bundle is an error; there is no network fallback.
enum DDIAssetInstaller {
    private static let installationLock = NSLock()

    static func install(to paths: DDIPaths, method: DDIMountMethod = .current,
                        catalog suppliedCatalog: DDIAssetCatalog? = nil,
                        assetsDirectory suppliedDirectory: URL? = nil,
                        onlyIfNeeded: Bool = false,
                        cancellation: DDIInstallationCancellation = DDIInstallationCancellation(),
                        cancellationCheck: @escaping () throws -> Void = {},
                        progress: @escaping (Double, String) -> Void = { _, _ in }) throws {
        func check() throws { try cancellation.check(); try cancellationCheck() }
        while !installationLock.try() {
            try check()
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { installationLock.unlock() }
        try check()
        let catalog = try suppliedCatalog ?? DDIAssetCatalog.load()
        try catalog.validate()
        if onlyIfNeeded && DDICache.isUsable(paths: paths, method: method, catalog: catalog) { return }
        guard let family = catalog.families[method.rawValue] else {
            throw StikJITError.ddiInstallation("Bundled catalog is missing the selected DDI family")
        }
        let resources = try suppliedDirectory ?? DDIAssetCatalog.assetsDirectory()
        let sourceDirectory = resources.appendingPathComponent(family.directory, isDirectory: true)
        let manager = FileManager.default
        let directory = paths.receiptURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".ddi-install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let total = family.files.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        for file in family.files {
            try check()
            let source = sourceDirectory.appendingPathComponent(file.name)
            guard let attributes = try? manager.attributesOfItem(atPath: source.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw StikJITError.ddiFilesMissing("Bundled \(family.directory)/\(file.name) is missing; reinstall the app")
            }
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size else {
                throw StikJITError.ddiInstallation("Bundled DDI size mismatch: \(file.name); reinstall the app")
            }
            let destination = staging.appendingPathComponent(file.name)
            try copy(source, to: destination, size: file.size, cancellationCheck: check) { bytes in
                progress(Double(completed + bytes) / Double(total), status("copying", file.name, bytes, file.size))
            }
            try check()
            progress(Double(completed + file.size) / Double(total), status("verifying", file.name, file.size, file.size))
            try DDICache.verify(destination, file: file)
            completed += file.size
        }
        try check()
        if let file = family.files.last {
            progress(1, status("committing", file.name, file.size, file.size))
        }
        try check()
        try DDICache.commit(staging: staging, paths: paths, method: method, catalog: catalog)
    }

    private static func copy(_ source: URL, to destination: URL, size: Int64,
                             cancellationCheck: () throws -> Void,
                             progress: (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StikJITError.ddiInstallation("Cannot create a temporary DDI file")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        progress(0)
        while true {
            try cancellationCheck()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            guard Int64(data.count) <= size - copied else {
                throw StikJITError.ddiInstallation("Bundled DDI grew while copying: \(source.lastPathComponent)")
            }
            try cancellationCheck()
            try output.write(contentsOf: data)
            copied += Int64(data.count)
            progress(copied)
        }
        guard copied == size else {
            throw StikJITError.ddiInstallation("Incomplete bundled DDI file: \(source.lastPathComponent)")
        }
        try output.synchronize()
    }

    private static func status(_ phase: String, _ name: String, _ bytes: Int64, _ total: Int64) -> String {
        "ddi|\(phase)|bundle|\(name)|\(bytes)|\(total)"
    }
}
