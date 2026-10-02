import Foundation
import CryptoKit

struct DDIAssetCatalog: Codable {
    let schemaVersion: Int
    let upstreamRevision: String
    let mirrorBaseURL: String
    let upstreamBaseURL: String
    let families: [String: Family]

    struct Family: Codable {
        let directory: String
        let files: [File]
    }
    struct File: Codable, Equatable {
        let name: String
        let size: Int64
        let sha256: String
    }

    static func load() throws -> DDIAssetCatalog {
        guard let url = Bundle(for: DDIResourceBundle.self).url(forResource: "DDIAssets", withExtension: "json") else {
            throw StikJITError.ddiDownload("Bundled DDI asset catalog is missing")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let common: Set<String> = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        guard schemaVersion == 1, upstreamRevision.count == 40,
              upstreamRevision.unicodeScalars.allSatisfy(hex.contains),
              URL(string: mirrorBaseURL)?.scheme == "https", URL(string: mirrorBaseURL)?.host != nil,
              URL(string: upstreamBaseURL)?.scheme == "https", URL(string: upstreamBaseURL)?.host != nil else {
            throw StikJITError.ddiDownload("Invalid DDI catalog version or download source")
        }
        for method in [DDIMountMethod.cryptex, .personalized] {
            let expected = method == .cryptex ? common.union(["Image.dmg.cryptex_info", "Image.dmg.root_hash"]) : common
            let directory = method == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
            guard let family = families[method.rawValue], family.directory == directory,
                  family.files.count == expected.count, Set(family.files.map(\.name)) == expected,
                  family.files.allSatisfy({ $0.size > 0 && $0.size < 2_147_483_648 && $0.sha256.count == 64 && $0.sha256.unicodeScalars.allSatisfy(hex.contains) }) else {
                throw StikJITError.ddiDownload("Invalid \(method.rawValue) DDI file catalog")
            }
        }
    }
}

private final class DDIResourceBundle: NSObject {}

enum DDICache {
    private struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let upstreamRevision: String
        let method: DDIMountMethod
        let files: [DDIAssetCatalog.File]
    }

    static func isUsable(paths: DDIPaths, method: DDIMountMethod, catalog: DDIAssetCatalog) -> Bool {
        do {
            try catalog.validate()
            let expected = try receipt(method: method, catalog: catalog)
            let actual = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: paths.receiptURL))
            guard actual == expected else { return false }
            if method == .personalized && paths.cryptexOnlyPaths.contains(where: FileManager.default.fileExists) { return false }
            for file in expected.files { try verify(URL(fileURLWithPath: paths.path(for: file.name)), file: file) }
            return true
        } catch { return false }
    }

    static func verify(_ url: URL, file: DDIAssetCatalog.File) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.size else {
            throw StikJITError.ddiDownload("DDI size mismatch: \(file.name)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw StikJITError.ddiDownload("DDI checksum mismatch: \(file.name)")
        }
    }

    static func commit(staging: URL, paths: DDIPaths, method: DDIMountMethod, catalog: DDIAssetCatalog) throws {
        let receipt = try receipt(method: method, catalog: catalog)
        for file in receipt.files { try verify(staging.appendingPathComponent(file.name), file: file) }
        let manager = FileManager.default
        // A partial commit can leave files on disk, but cannot leave a valid receipt.
        if manager.fileExists(atPath: paths.receiptURL.path) { try manager.removeItem(at: paths.receiptURL) }
        for file in receipt.files {
            let destination = URL(fileURLWithPath: try paths.path(for: file.name))
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staging.appendingPathComponent(file.name), to: destination)
        }
        if method == .personalized { try paths.removeCryptexOnlyFiles() }
        try JSONEncoder().encode(receipt).write(to: paths.receiptURL, options: .atomic)
    }

    private static func receipt(method: DDIMountMethod, catalog: DDIAssetCatalog) throws -> Receipt {
        guard let family = catalog.families[method.rawValue] else { throw StikJITError.ddiDownload("Missing DDI family") }
        return Receipt(schemaVersion: 1, upstreamRevision: catalog.upstreamRevision, method: method, files: family.files)
    }
}
