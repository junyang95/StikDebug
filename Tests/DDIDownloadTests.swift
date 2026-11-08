import Foundation
import CryptoKit

// The script retains its historical filename, but all fixtures and production
// assets are local files. No URL protocol, network configuration or server exists.
@main
enum DDIBundledInstallationTests {
    static func main() async throws {
        let manager = FileManager.default
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); count += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { count += 1 }
        }
        let root = manager.temporaryDirectory.appendingPathComponent("DDIFixtures-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let bundled = try DDIAssetCatalog.load()
        let bundledDirectory = try DDIAssetCatalog.assetsDirectory()
        check(bundled.families["cryptex"]?.files.count == 5 && bundled.families["personalized"]?.files.count == 3,
              "Production catalog contains both DDI families")
        check(bundledDirectory.lastPathComponent == "DDI", "Bundle keeps the DDI folder hierarchy")
        for family in bundled.families.values {
            for file in family.files {
                try DDICache.verify(bundledDirectory.appendingPathComponent(family.directory).appendingPathComponent(file.name), file: file)
                check(true, "Production bundled asset matches its pinned size and SHA-256")
            }
        }
        let catalogData = try JSONEncoder().encode(bundled)
        let encodedCatalog = String(decoding: catalogData, as: UTF8.self)
        check(!encodedCatalog.contains("https:") && !encodedCatalog.contains("BaseURL"), "Catalog contains no download destinations")
        for method in [DDIMountMethod.cryptex, .personalized] {
            let paths = DDIPaths.default(in: root.appendingPathComponent("production-\(method.rawValue)"))
            try DDIAssetInstaller.install(to: paths, method: method)
            check(DDICache.isUsable(paths: paths, method: method, catalog: bundled), "Production bundle installs the complete selected family")
        }

        let common = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        let names = common + ["Image.dmg.cryptex_info", "Image.dmg.root_hash"]
        let source = root.appendingPathComponent("fixture-bundle/DDI", isDirectory: true)
        var families: [String: DDIAssetCatalog.Family] = [:]
        for (familyIndex, method) in [DDIMountMethod.cryptex, .personalized].enumerated() {
            let directoryName = method == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
            let directory = source.appendingPathComponent(directoryName, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try (method == .cryptex ? names : common).enumerated().map { index, name -> DDIAssetCatalog.File in
                let size = name == "Image.dmg" ? 3 * 1_048_576 + 7 : 16_384 + index
                // Families intentionally differ: picking the wrong folder must fail.
                let data = Data(repeating: UInt8(1 + index + familyIndex * 10), count: size)
                try data.write(to: directory.appendingPathComponent(name))
                return .init(name: name, size: Int64(size), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            families[method.rawValue] = .init(directory: directoryName, files: files)
        }
        let catalog = DDIAssetCatalog(schemaVersion: 1, upstreamRevision: String(repeating: "a", count: 40), families: families)
        try catalog.validate()
        func install(_ name: String, method: DDIMountMethod = .cryptex, source override: URL? = nil,
                     onlyIfNeeded: Bool = false, cancellation: DDIInstallationCancellation = .init(),
                     cancellationCheck: @escaping () throws -> Void = {},
                     progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> DDIPaths {
            let paths = DDIPaths.default(in: root.appendingPathComponent(name))
            try DDIAssetInstaller.install(to: paths, method: method, catalog: catalog, assetsDirectory: override ?? source,
                                          onlyIfNeeded: onlyIfNeeded, cancellation: cancellation,
                                          cancellationCheck: cancellationCheck, progress: progress)
            return paths
        }
        func sourceCopy(_ name: String) throws -> URL {
            let result = root.appendingPathComponent(name)
            try manager.copyItem(at: source, to: result)
            return result
        }
        func snapshot(_ paths: DDIPaths) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for path in paths.allPaths + [paths.receiptURL.path] where manager.fileExists(atPath: path) {
                result[path] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
            return result
        }
        func noStaging(_ paths: DDIPaths) throws -> Bool {
            try manager.contentsOfDirectory(atPath: paths.receiptURL.deletingLastPathComponent().path)
                .allSatisfy { !$0.hasPrefix(".ddi-install-") }
        }
        check(DDIMountMethod.forVersion(.init(majorVersion: 26, minorVersion: 3, patchVersion: 9)) == .personalized, "iOS 26.3 selects Personalized")
        check(DDIMountMethod.forVersion(.init(majorVersion: 26, minorVersion: 4, patchVersion: 0)) == .cryptex, "iOS 26.4 selects Cryptex")
        check(DDIMountMethod.forVersion(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == .cryptex, "iOS 27 selects Cryptex")
        rejects("Unknown catalog schemas are rejected") {
            try DDIAssetCatalog(schemaVersion: 2, upstreamRevision: catalog.upstreamRevision, families: families).validate()
        }
        var invalidFamilies = families
        invalidFamilies["cryptex"] = .init(directory: "../other", files: families["cryptex"]!.files)
        rejects("Catalog directories cannot escape the bundled family") {
            try DDIAssetCatalog(schemaVersion: 1, upstreamRevision: catalog.upstreamRevision, families: invalidFamilies).validate()
        }

        var events: [(Double, String)] = []
        let paths = try install("working", progress: { events.append(($0, $1)) })
        check(DDICache.isUsable(paths: paths, method: .cryptex, catalog: catalog), "Five copied files and receipt form a valid Cryptex cache")
        check(events.contains { $0.0 > 0 && $0.0 < 1 && $0.1.hasPrefix("ddi|copying|bundle|Image.dmg|") }, "Large file copying reports intermediate progress")
        check(events.contains { $0.1.hasPrefix("ddi|verifying|bundle|") } && events.last?.1.hasPrefix("ddi|committing|bundle|") == true,
              "Progress covers verification and final commit")
        check(events.allSatisfy { (0...1).contains($0.0) && $0.1.split(separator: "|")[2] == "bundle" }, "Every progress event uses only the bundle source")
        check(try noStaging(paths), "Successful installation removes temporary staging")
        let prior = try snapshot(paths)

        let missing = try sourceCopy("missing")
        try manager.removeItem(at: missing.appendingPathComponent("Xcode_iOS_DDI_Cryptex/Image.dmg.root_hash"))
        rejects("Missing bundled files fail instead of requesting a fallback") { _ = try install("working", source: missing) }
        check(try snapshot(paths) == prior && DDICache.isUsable(paths: paths, method: .cryptex, catalog: catalog), "Missing resources preserve the previous complete cache")
        check(try noStaging(paths), "Missing-resource failure cleans staging")

        let corrupt = try sourceCopy("corrupt")
        let corruptFile = corrupt.appendingPathComponent("Xcode_iOS_DDI_Cryptex/Image.dmg.trustcache")
        try Data(repeating: 0xEE, count: Int(families["cryptex"]!.files[2].size)).write(to: corruptFile)
        rejects("Matching size with a wrong checksum is rejected") { _ = try install("working", source: corrupt) }
        check(try snapshot(paths) == prior, "Corrupt bundle preserves the previous complete cache")
        try Data([0]).write(to: corruptFile)
        rejects("A truncated bundle file is rejected") { _ = try install("working", source: corrupt) }
        check(try snapshot(paths) == prior && noStaging(paths), "Truncated bundle preserves old files and cleans staging")

        let token = DDIInstallationCancellation()
        token.cancel()
        rejects("Pre-cancelled work never mutates the cache") { _ = try install("working", cancellation: token) }
        var cancelCopy = false
        rejects("Cancellation interrupts a multi-chunk local copy") {
            _ = try install("working", cancellationCheck: { if cancelCopy { throw CancellationError() } }, progress: { _, status in
                let fields = status.split(separator: "|")
                if fields[1] == "copying", fields[3] == "Image.dmg", Int(fields[4])! > 0 { cancelCopy = true }
            })
        }
        check(try cancelCopy && snapshot(paths) == prior && noStaging(paths), "Cancelled copy keeps the old set and removes partial files")
        var cancelCommit = false
        rejects("Cancellation just before commit preserves the old receipt") {
            _ = try install("working", cancellationCheck: { if cancelCommit { throw CancellationError() } }, progress: { _, status in
                if status.hasPrefix("ddi|committing|") { cancelCommit = true }
            })
        }
        check(try cancelCommit && snapshot(paths) == prior && noStaging(paths), "Cancellation at the commit boundary leaves the old cache intact")

        _ = try install("working", source: root.appendingPathComponent("does-not-exist"), onlyIfNeeded: true)
        check(try snapshot(paths) == prior, "A valid cache needs no source-file access")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: paths.imagePath))
        check(!DDICache.isUsable(paths: paths, method: .cryptex, catalog: catalog), "Damaged cache cannot pass its receipt")
        _ = try install("working", onlyIfNeeded: true)
        check(DDICache.isUsable(paths: paths, method: .cryptex, catalog: catalog), "Bundled resources repair a damaged cache")
        _ = try install("working", method: .personalized)
        check(DDICache.isUsable(paths: paths, method: .personalized, catalog: catalog), "Three-file Personalized replacement is complete")
        check(paths.cryptexOnlyPaths.allSatisfy { !manager.fileExists(atPath: $0) }, "Switching families removes Cryptex-only files")
        check(!DDICache.isUsable(paths: paths, method: .cryptex, catalog: catalog), "A receipt cannot be reused for another family")
        try manager.removeItem(at: paths.receiptURL)
        check(!DDICache.isUsable(paths: paths, method: .personalized, catalog: catalog), "Files without a completion receipt are not a cache")
        _ = try install("working", method: .personalized)
        let personalizedPrior = try snapshot(paths)
        var invalidPaths = paths
        invalidPaths.rootHashPath = root.appendingPathComponent("blocked-destination").path
        try manager.createDirectory(atPath: invalidPaths.rootHashPath, withIntermediateDirectories: false)
        rejects("Invalid cache destinations fail before replacing old files") {
            try DDIAssetInstaller.install(to: invalidPaths, method: .cryptex, catalog: catalog, assetsDirectory: source)
        }
        check(try snapshot(paths) == personalizedPrior, "Commit preflight failure preserves the previous family")

        let servicePaths = DDIPaths.default(in: root.appendingPathComponent("service"))
        let service = DeveloperDiskImageService()
        try await service.prepareIfNeeded(to: servicePaths)
        check(DDICache.isUsable(paths: servicePaths, method: .current, catalog: bundled), "Public async preparation installs the packaged family")
        try await service.restore(to: servicePaths)
        check(DDICache.isUsable(paths: servicePaths, method: .current, catalog: bundled), "Public restore uses the same verified bundle")
        try paths.removeCachedFiles()
        check(!manager.fileExists(atPath: paths.receiptURL.path) && paths.allPaths.allSatisfy { !manager.fileExists(atPath: $0) }, "Reset removes only cache receipt and assets")
        print("\(count) bundled DDI installation/cache tests passed")
    }
}
