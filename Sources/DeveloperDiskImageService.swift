import Foundation

public struct DDIPaths: Sendable {
    public var imagePath: String
    public var trustcachePath: String
    public var manifestPath: String
    public var cryptexInfoPath: String
    public var rootHashPath: String

    public init(imagePath: String, trustcachePath: String, manifestPath: String,
                cryptexInfoPath: String? = nil, rootHashPath: String? = nil) {
        self.imagePath = imagePath
        self.trustcachePath = trustcachePath
        self.manifestPath = manifestPath
        self.cryptexInfoPath = cryptexInfoPath ?? "\(imagePath).cryptex_info"
        self.rootHashPath = rootHashPath ?? "\(imagePath).root_hash"
    }

    public static func `default`(in directory: URL) -> DDIPaths {
        DDIPaths(imagePath: directory.appendingPathComponent("DDI/Image.dmg").path,
                 trustcachePath: directory.appendingPathComponent("DDI/Image.dmg.trustcache").path,
                 manifestPath: directory.appendingPathComponent("DDI/BuildManifest.plist").path)
    }

    var allFilesUsable: Bool {
        guard let catalog = try? DDIAssetCatalog.load() else { return false }
        return DDICache.isUsable(paths: self, method: .current, catalog: catalog)
    }

    var allPaths: [String] { personalizedPaths + cryptexOnlyPaths }
    var personalizedPaths: [String] { [imagePath, trustcachePath, manifestPath] }
    var cryptexOnlyPaths: [String] { [cryptexInfoPath, rootHashPath] }
    var receiptURL: URL {
        URL(fileURLWithPath: manifestPath).deletingLastPathComponent().appendingPathComponent("DDIAssets.complete.json")
    }

    func path(for name: String) throws -> String {
        switch name {
        case "BuildManifest.plist": return manifestPath
        case "Image.dmg": return imagePath
        case "Image.dmg.trustcache": return trustcachePath
        case "Image.dmg.cryptex_info": return cryptexInfoPath
        case "Image.dmg.root_hash": return rootHashPath
        default: throw StikJITError.ddiInstallation("Unknown DDI asset: \(name)")
        }
    }

    func removeCachedFiles() throws {
        for path in Set([receiptURL.path] + allPaths) where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func removeCryptexOnlyFiles() throws {
        for path in Set(cryptexOnlyPaths) where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

enum DDIMountMethod: String, Codable {
    case cryptex
    case personalized
    static var current: DDIMountMethod { forVersion(ProcessInfo.processInfo.operatingSystemVersion) }
    static func forVersion(_ version: OperatingSystemVersion) -> DDIMountMethod {
        version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4) ? .cryptex : .personalized
    }
}

@available(iOS 17.4, *)
public actor DeveloperDiskImageService {
    public static let shared = DeveloperDiskImageService()

    public init() {}

    public func prepareIfNeeded(to paths: DDIPaths, progress: @escaping (Double, String) -> Void = { _, _ in }) async throws {
        try await run(to: paths, onlyIfNeeded: true, progress: progress)
    }

    public func restore(to paths: DDIPaths, progress: @escaping (Double, String) -> Void = { _, _ in }) async throws {
        try await run(to: paths, onlyIfNeeded: false, progress: progress)
    }

    private func run(to paths: DDIPaths, onlyIfNeeded: Bool, progress: @escaping (Double, String) -> Void) async throws {
        let cancellation = DDIInstallationCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try DDIAssetInstaller.install(to: paths, onlyIfNeeded: onlyIfNeeded,
                                                      cancellation: cancellation, progress: progress)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
