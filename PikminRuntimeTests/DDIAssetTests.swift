import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

struct DDIAssetSelectionTests {
    @Test func cryptexStartsAtIOS264IncludingFutureMajorVersions() {
        let cases: [(Int, Int, Int, DDIMountMethod)] = [
            (18, 7, 9, .personalized), (26, 0, 0, .personalized),
            (26, 3, 99, .personalized), (26, 4, 0, .cryptex),
            (26, 4, 1, .cryptex), (26, 5, 0, .cryptex), (27, 0, 0, .cryptex)
        ]
        for (major, minor, patch, expected) in cases {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
            #expect(DDIMountMethod.select(for: version) == expected)
            #expect(DDIAssetSet.current(for: version).method == expected)
        }
    }

    @Test func allEightAssetsUseTheSameImmutableQiniuRelease() {
        let release = "6eae353ae694bda1c421d4a3eee5459ae59c99a1"
        let base = "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/releases/\(release)"
        let personalized = DDIAssetSet.current(for: .init(majorVersion: 26, minorVersion: 3, patchVersion: 0))
        let cryptex = DDIAssetSet.current(for: .init(majorVersion: 26, minorVersion: 4, patchVersion: 0))
        #expect(DDIAssetSet.releaseID == release)
        #expect(personalized.release == release && cryptex.release == release)
        #expect(personalized.files.map(\.fileName) == DDITestAssets.personalizedNames)
        #expect(cryptex.files.map(\.fileName) == DDITestAssets.cryptexNames)
        let expected = Set(DDITestAssets.personalizedNames.map { "\(base)/Xcode_iOS_DDI_Personalized/\($0)" }
            + DDITestAssets.cryptexNames.map { "\(base)/Xcode_iOS_DDI_Cryptex/\($0)" })
        let actual = Set([personalized, cryptex].flatMap { set in set.files.map { set.url(for: $0).absoluteString } })
        #expect(actual == expected)
        #expect(actual.count == 8)
        #expect(personalized.cacheKey != cryptex.cacheKey)
        for item in personalized.files + cryptex.files {
            #expect(item.size > 0)
            #expect(item.sha256.count == 64)
            #expect(item.sha256.allSatisfy { $0.isHexDigit })
        }
    }

    @Test func integrityRequiresBothExactSizeAndSHA256() throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let item = DDIDownloadItem(fileName: "Image.dmg", size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let set = DDIAssetSet(release: "test", method: .personalized, files: [item])
        let file = directory.root.appendingPathComponent(item.fileName)
        try Data("abc".utf8).write(to: file)
        try set.verifyFile(at: file, item: item)
        for badContent in ["", "ab", "abcd", "abd"] {
            try Data(badContent.utf8).write(to: file)
            #expect(throws: (any Error).self) { try set.verifyFile(at: file, item: item) }
        }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try set.verifyFile(at: file, item: item) }
    }
}

@Suite(.serialized) @MainActor struct DDIAssetCacheTests {
    @Test func completeDownloadPublishesMarkerAndNextRequestUsesCache() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .personalized)
        let downloads = DDIFakeDownloads(assets: assets)
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        #expect(!service.cachedFilesAreReady)
        try await service.downloadMissingFiles()
        #expect(service.cachedFilesAreReady)
        try expectInstalled(assets, at: directory.cache)
        try await service.downloadMissingFiles()
        #expect(await downloads.names == DDITestAssets.personalizedNames)
    }

    @Test func legacyCacheWithoutMarkerIsDownloadedAgain() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .personalized)
        try assets.install(at: directory.cache, marker: false)
        let downloads = DDIFakeDownloads(assets: assets)
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        #expect(!service.cachedFilesAreReady)
        try await service.downloadMissingFiles()
        #expect(await downloads.names == DDITestAssets.personalizedNames)
        try expectInstalled(assets, at: directory.cache)
    }

    @Test(arguments: ["missing", "truncated", "same-size-corruption"])
    func matchingMarkerCannotHideBrokenCachedFiles(kind: String) async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .personalized)
        try assets.install(at: directory.cache)
        let image = directory.cache.appendingPathComponent("Image.dmg")
        if kind == "missing" {
            try FileManager.default.removeItem(at: image)
        } else {
            var contents = try Data(contentsOf: image)
            if kind == "truncated" { contents.removeLast() } else { contents[0] ^= 0xff }
            try contents.write(to: image)
        }
        let downloads = DDIFakeDownloads(assets: assets)
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        #expect(!service.cachedFilesAreReady)
        try await service.downloadMissingFiles()
        #expect(service.cachedFilesAreReady)
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func changedReleaseReplacesTheEntireOldDirectory() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let old = DDITestAssets(method: .personalized, release: "old")
        try old.install(at: directory.cache)
        try Data("stale".utf8).write(to: directory.cache.appendingPathComponent("obsolete-file"))
        let assets = DDITestAssets(method: .personalized, release: "new")
        let downloads = DDIFakeDownloads(assets: assets)
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        #expect(!service.cachedFilesAreReady)
        try await service.downloadMissingFiles()
        #expect(service.cachedFilesAreReady)
        #expect(await downloads.names == DDITestAssets.personalizedNames)
        try expectInstalled(assets, at: directory.cache)
        #expect(!FileManager.default.fileExists(atPath: directory.cache.appendingPathComponent("obsolete-file").path))
    }

    @Test func switchingMountMethodsReplacesAllFilesAndRemovesCryptexExtras() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let personalized = DDITestAssets(method: .personalized)
        try personalized.install(at: directory.cache)
        let cryptex = DDITestAssets(method: .cryptex)
        let cryptexDownloads = DDIFakeDownloads(assets: cryptex)
        let cryptexService = makeService(directory: directory, assets: cryptex, downloads: cryptexDownloads)
        #expect(!cryptexService.cachedFilesAreReady)
        try await cryptexService.downloadMissingFiles()
        #expect(await cryptexDownloads.names == DDITestAssets.cryptexNames)
        try expectInstalled(cryptex, at: directory.cache)

        let personalizedDownloads = DDIFakeDownloads(assets: personalized)
        let personalizedService = makeService(directory: directory, assets: personalized, downloads: personalizedDownloads)
        #expect(!personalizedService.cachedFilesAreReady)
        try await personalizedService.downloadMissingFiles()
        #expect(await personalizedDownloads.names == DDITestAssets.personalizedNames)
        try expectInstalled(personalized, at: directory.cache)
        for name in ["Image.dmg.cryptex_info", "Image.dmg.root_hash"] {
            #expect(!FileManager.default.fileExists(atPath: directory.cache.appendingPathComponent(name).path))
        }
    }

    @Test func failedDownloadPreservesCacheAndRetryReusesVerifiedStagedFiles() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        try DDITestAssets(method: .personalized, release: "old").install(at: directory.cache)
        let original = try directory.snapshot()
        let assets = DDITestAssets(method: .cryptex, release: "new")
        let downloads = DDIFakeDownloads(assets: assets, failOnce: "Image.dmg")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        await expectFailure { try await service.downloadMissingFiles() }
        #expect(try directory.snapshot() == original)
        #expect(!service.cachedFilesAreReady)
        try await service.downloadMissingFiles()
        #expect(await downloads.names == ["BuildManifest.plist", "Image.dmg", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"])
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func activeCacheRemainsIntactUntilTheWholeNewSetIsVerified() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let old = DDITestAssets(method: .personalized, release: "old")
        try old.install(at: directory.cache)
        let original = try directory.snapshot()
        let assets = DDITestAssets(method: .cryptex, release: "new")
        let downloads = DDIFakeDownloads(assets: assets, hold: "Image.dmg.root_hash")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        let task = Task { try await service.downloadMissingFiles() }
        await waitForRequest(downloads, count: 5)
        #expect(try directory.snapshot() == original)
        await downloads.release()
        try await task.value
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func invalidHashPreservesCacheAndBadStagedFileIsNotReused() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        try DDITestAssets(method: .personalized, release: "old").install(at: directory.cache)
        let original = try directory.snapshot()
        let assets = DDITestAssets(method: .personalized, release: "new")
        let downloads = DDIFakeDownloads(assets: assets, corruptOnce: "Image.dmg")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        await expectFailure { try await service.downloadMissingFiles() }
        #expect(try directory.snapshot() == original)
        try await service.downloadMissingFiles()
        #expect(await downloads.names == ["BuildManifest.plist", "Image.dmg", "Image.dmg", "Image.dmg.trustcache"])
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func forcedRetryDiscardsPreviouslyVerifiedStaging() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .personalized)
        let downloads = DDIFakeDownloads(assets: assets, failOnce: "Image.dmg")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        await expectFailure { try await service.downloadMissingFiles() }
        try await service.redownload()
        #expect(await downloads.names == ["BuildManifest.plist", "Image.dmg", "BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"])
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func cancellingForcedDownloadPreservesTheUsableInstalledCache() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .cryptex)
        try assets.install(at: directory.cache)
        let original = try directory.snapshot()
        let downloads = DDIFakeDownloads(assets: assets, hold: "BuildManifest.plist")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        let task = Task { try await service.redownload() }
        await waitForRequest(downloads)
        task.cancel()
        await expectFailure { try await task.value }
        #expect(try directory.snapshot() == original)
        #expect(service.cachedFilesAreReady)
        #expect(await downloads.names == ["BuildManifest.plist"])
    }

    @Test func duplicateDownloadIsRejectedWithoutDisturbingTheFirstRequest() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let assets = DDITestAssets(method: .personalized)
        let downloads = DDIFakeDownloads(assets: assets, hold: "BuildManifest.plist")
        let service = makeService(directory: directory, assets: assets, downloads: downloads)
        let first = Task { try await service.downloadMissingFiles() }
        await waitForRequest(downloads)
        // Release the first request even if a regression lets the second request wait or download.
        let release = Task {
            try await Task.sleep(for: .milliseconds(50))
            await downloads.release()
        }
        await expectFailure { try await service.redownload() }
        try await release.value
        try await first.value
        #expect(await downloads.names == DDITestAssets.personalizedNames)
        try expectInstalled(assets, at: directory.cache)
    }

    @Test func partialStagingFromAnotherMountMethodIsNeverReused() async throws {
        let directory = try DDITestDirectory()
        defer { directory.remove() }
        let personalized = DDITestAssets(method: .personalized)
        let personalizedDownloads = DDIFakeDownloads(assets: personalized, failOnce: "Image.dmg")
        let personalizedService = makeService(directory: directory, assets: personalized, downloads: personalizedDownloads)
        await expectFailure { try await personalizedService.downloadMissingFiles() }
        let cryptex = DDITestAssets(method: .cryptex)
        let cryptexDownloads = DDIFakeDownloads(assets: cryptex)
        try await makeService(directory: directory, assets: cryptex, downloads: cryptexDownloads).downloadMissingFiles()
        #expect(await cryptexDownloads.names == DDITestAssets.cryptexNames)
        try expectInstalled(cryptex, at: directory.cache)
        // The original method keeps its own complete staged file for a later retry.
        try await personalizedService.downloadMissingFiles()
        #expect(await personalizedDownloads.names == ["BuildManifest.plist", "Image.dmg", "Image.dmg", "Image.dmg.trustcache"])
        try expectInstalled(personalized, at: directory.cache)
    }

    private func makeService(directory: DDITestDirectory, assets: DDITestAssets, downloads: DDIFakeDownloads) -> DeveloperDiskImageService {
        DeveloperDiskImageService(directoryURL: directory.cache, assetSet: assets.set, downloader: { url, destination, progress in
            try await downloads.download(url: url, to: destination, progress: progress)
        })
    }

    private func expectInstalled(_ assets: DDITestAssets, at directory: URL) throws {
        #expect(try String(contentsOf: directory.appendingPathComponent(".asset-set"), encoding: .utf8) == assets.set.cacheKey)
        for (name, contents) in assets.contents {
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == contents)
        }
    }

    private func expectFailure(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected this download attempt to fail")
        } catch {}
    }

    private func waitForRequest(_ downloads: DDIFakeDownloads, count: Int = 1) async {
        for _ in 0..<200 {
            if await downloads.names.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The fixture download did not start")
    }
}

private struct DDITestDirectory {
    let root: URL
    var cache: URL { root.appendingPathComponent("DDI", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ddi-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func snapshot() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct DDITestAssets: Sendable {
    static let personalizedNames = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
    static let cryptexNames = personalizedNames + ["Image.dmg.cryptex_info", "Image.dmg.root_hash"]
    let set: DDIAssetSet
    let contents: [String: Data]

    init(method: DDIMountMethod, release: String = "test-release") {
        let names = method == .personalized ? Self.personalizedNames : Self.cryptexNames
        let data = Dictionary(uniqueKeysWithValues: names.map { name -> (String, Data) in
            let content: Data
            if name == "BuildManifest.plist" {
                content = try! PropertyListSerialization.data(fromPropertyList: ["Release": release, "Method": method.rawValue], format: .xml, options: 0)
            } else {
                content = Data("fixture-\(release)-\(method.rawValue)-\(name)".utf8)
            }
            return (name, content)
        })
        contents = data
        set = DDIAssetSet(release: release, method: method, files: names.map { name in
            let bytes = data[name]!
            return DDIDownloadItem(fileName: name, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        })
    }

    func install(at directory: URL, marker: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in contents { try data.write(to: directory.appendingPathComponent(name)) }
        if marker { try set.cacheKey.write(to: directory.appendingPathComponent(".asset-set"), atomically: true, encoding: .utf8) }
    }
}

private actor DDIFakeDownloads {
    let assets: DDITestAssets
    var names: [String] = []
    var failOnce: String?
    var corruptOnce: String?
    var hold: String?

    init(assets: DDITestAssets, failOnce: String? = nil, corruptOnce: String? = nil, hold: String? = nil) {
        self.assets = assets
        self.failOnce = failOnce
        self.corruptOnce = corruptOnce
        self.hold = hold
    }

    func release() { hold = nil }

    func download(url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let name = url.lastPathComponent
        names.append(name)
        while hold == name { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if failOnce == name {
            failOnce = nil
            throw URLError(.networkConnectionLost)
        }
        var data = try #require(assets.contents[name])
        if corruptOnce == name {
            corruptOnce = nil
            data[0] ^= 0xff
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        progress(1)
    }
}
