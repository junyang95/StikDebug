import Foundation
import CryptoKit

struct DDIAssetCatalog: Codable {
    let schemaVersion: Int
    let upstreamRevision: String
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

    static func load(bundle: Bundle = Bundle(for: DDIResourceBundle.self)) throws -> DDIAssetCatalog {
        guard let url = bundle.url(forResource: "DDIAssets", withExtension: "json") else {
            throw StikJITError.ddiInstallation("Bundled DDI asset catalog is missing")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    static func assetsDirectory(bundle: Bundle = Bundle(for: DDIResourceBundle.self)) throws -> URL {
        guard let resources = bundle.resourceURL else {
            throw StikJITError.ddiFilesMissing("The app's bundled DDI resource directory is unavailable; reinstall the app")
        }
        let directory = resources.appendingPathComponent("DDI", isDirectory: true)
        guard (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw StikJITError.ddiFilesMissing("The app is missing its bundled DDI folder; reinstall the app")
        }
        return directory
    }

    func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let common: Set<String> = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        guard schemaVersion == 1, upstreamRevision.count == 40,
              upstreamRevision.unicodeScalars.allSatisfy(hex.contains),
              Set(families.keys) == Set(["cryptex", "personalized"]) else {
            throw StikJITError.ddiInstallation("Invalid bundled DDI catalog version or file families")
        }
        for method in [DDIMountMethod.cryptex, .personalized] {
            let expected = method == .cryptex ? common.union(["Image.dmg.cryptex_info", "Image.dmg.root_hash"]) : common
            let directory = method == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
            guard let family = families[method.rawValue], family.directory == directory,
                  family.files.count == expected.count, Set(family.files.map(\.name)) == expected,
                  family.files.allSatisfy({ $0.size > 0 && $0.size < 2_147_483_648 && $0.sha256.count == 64 && $0.sha256.unicodeScalars.allSatisfy(hex.contains) }) else {
                throw StikJITError.ddiInstallation("Invalid \(method.rawValue) DDI file catalog")
            }
        }
    }
}

final class DDIResourceBundle: NSObject {}

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
            throw StikJITError.ddiInstallation("DDI size mismatch: \(file.name)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw StikJITError.ddiInstallation("DDI checksum mismatch: \(file.name)")
        }
    }

    static func commit(staging: URL, paths: DDIPaths, method: DDIMountMethod, catalog: DDIAssetCatalog) throws {
        let receipt = try receipt(method: method, catalog: catalog)
        for file in receipt.files { try verify(staging.appendingPathComponent(file.name), file: file) }
        let manager = FileManager.default
        let receiptSource = staging.appendingPathComponent("DDIAssets.complete.json")
        try JSONEncoder().encode(receipt).write(to: receiptSource, options: .atomic)
        let replacements = try receipt.files.map {
            (source: staging.appendingPathComponent($0.name), destination: URL(fileURLWithPath: try paths.path(for: $0.name)))
        } + [(source: receiptSource, destination: paths.receiptURL)]
        let allTargets = (paths.allPaths + [paths.receiptURL.path]).map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard Set(allTargets).count == allTargets.count else {
            throw StikJITError.ddiInstallation("DDI cache destinations overlap")
        }
        // Preflight every destination before touching the previous complete set.
        for destination in allTargets {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path),
               try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType != .typeRegular {
                throw StikJITError.ddiInstallation("DDI cache destination is not a regular file: \(destination.lastPathComponent)")
            }
        }
        let backup = staging.appendingPathComponent("previous", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: false)
        var originals: [(source: URL, destination: URL)] = []
        var installed: [URL] = []
        do {
            for (index, destination) in allTargets.enumerated() where manager.fileExists(atPath: destination.path) {
                let saved = backup.appendingPathComponent(String(index))
                try manager.moveItem(at: destination, to: saved)
                originals.append((source: saved, destination: destination))
            }
            // Publish the receipt last. No cancellation is observed mid-commit:
            // the cache must finish as a complete old or complete new asset set.
            for replacement in replacements {
                try manager.moveItem(at: replacement.source, to: replacement.destination)
                installed.append(replacement.destination)
            }
        } catch {
            let commitError = error
            var rollbackFailed = false
            for destination in installed.reversed() {
                do { try manager.removeItem(at: destination) } catch { rollbackFailed = true }
            }
            for original in originals.reversed() {
                do { try manager.moveItem(at: original.source, to: original.destination) } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                try? manager.removeItem(at: paths.receiptURL)
                throw StikJITError.ddiInstallation("Cache replacement could not be recovered; restore the bundled DDI again")
            }
            throw commitError
        }
    }

    private static func receipt(method: DDIMountMethod, catalog: DDIAssetCatalog) throws -> Receipt {
        guard let family = catalog.families[method.rawValue] else { throw StikJITError.ddiInstallation("Missing DDI family") }
        return Receipt(schemaVersion: 1, upstreamRevision: catalog.upstreamRevision, method: method, files: family.files)
    }
}
