import Foundation
import CryptoKit

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior { case success, missing, corrupt, connectionStall, bodyStall, oversized }
    static let lock = NSLock()
    static var mirrorBehavior: Behavior = .success
    static var upstreamBehavior: Behavior = .success
    static var payloads: [String: Data] = [:]
    static var requests: [URL] = []
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(url)
        let behavior = url.host == "mirror.test" ? Self.mirrorBehavior : Self.upstreamBehavior
        let bytes = Self.payloads[url.lastPathComponent]!
        Self.lock.unlock()
        guard behavior != .connectionStall else { return }
        let headers = behavior == .oversized ? [:] : ["Content-Length": "\(bytes.count)"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: behavior == .missing ? 404 : 200,
                                                            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if behavior == .missing { client?.urlProtocolDidFinishLoading(self); return }
        let body = behavior == .corrupt ? Data(repeating: 0xEE, count: bytes.count) : bytes
        if behavior == .oversized {
            client?.urlProtocol(self, didLoad: body + Data([0]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let split = max(1, body.count / 2)
        client?.urlProtocol(self, didLoad: body.prefix(split))
        guard behavior != .bodyStall else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); let alive = !self.stopped; self.stateLock.unlock()
            guard alive else { return }
            self.client?.urlProtocol(self, didLoad: body.suffix(body.count - split))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    static func configure(mirror: Behavior, upstream: Behavior = .success) {
        lock.lock(); mirrorBehavior = mirror; upstreamBehavior = upstream; requests = []; lock.unlock()
    }
}

@main
enum DDIDownloadTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); count += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { count += 1 }
        }
        let bundled = try DDIAssetCatalog.load()
        check(bundled.families["cryptex"]?.files.count == 5 && bundled.families["personalized"]?.files.count == 3,
              "Production bundled catalog decodes both asset families")
        check(bundled.upstreamBaseURL.contains(bundled.upstreamRevision) && bundled.mirrorBaseURL.contains(bundled.upstreamRevision),
              "Production download URLs pin the catalog revision")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DDIFixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let common = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        let all = common + ["Image.dmg.cryptex_info", "Image.dmg.root_hash"]
        var payloads: [String: Data] = [:]
        let assets: [DDIAssetCatalog.File] = all.enumerated().map { index, name in
            let bytes = Data(repeating: UInt8(index + 1), count: 16_384 + index)
            payloads[name] = bytes
            return .init(name: name, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let catalog = DDIAssetCatalog(schemaVersion: 1, upstreamRevision: String(repeating: "a", count: 40),
                                      mirrorBaseURL: "https://mirror.test/revision", upstreamBaseURL: "https://upstream.test/revision/PersonalizedImages",
                                      families: ["cryptex": .init(directory: "Xcode_iOS_DDI_Cryptex", files: assets),
                                                 "personalized": .init(directory: "Xcode_iOS_DDI_Personalized", files: Array(assets.prefix(3)))])
        try catalog.validate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.payloads = payloads
        let timeouts = DDIDownloadRunner.Timeouts(connection: 0.12, stalled: 0.12, resource: 2)
        func run(_ name: String, method: DDIMountMethod = .cryptex,
                 cancellationCheck: @escaping () throws -> Void = {},
                 progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> DDIPaths {
            let paths = DDIPaths.default(in: root.appendingPathComponent(name))
            try DDIDownloadRunner.download(to: paths, method: method, catalog: catalog, configuration: configuration,
                                           timeouts: timeouts, cancellationCheck: cancellationCheck, progress: progress)
            return paths
        }
        check(DDIMountMethod.forVersion(.init(majorVersion: 26, minorVersion: 3, patchVersion: 9)) == .personalized, "iOS 26.3 uses personalized assets")
        check(DDIMountMethod.forVersion(.init(majorVersion: 26, minorVersion: 4, patchVersion: 0)) == .cryptex, "iOS 26.4 uses Cryptex")
        check(DDIMountMethod.forVersion(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == .cryptex, "iOS 27 uses Cryptex")
        let items = try DDIDownloadCatalog.items(for: .default(in: root), method: .cryptex, catalog: catalog)
        check(items.count == 5 && items.allSatisfy { $0.url.host == "mirror.test" && $0.fallbackURL.host == "upstream.test" }, "Cryptex has five pinned dual-source assets")
        check(try DDIDownloadCatalog.items(for: .default(in: root), method: .personalized, catalog: catalog).count == 3, "Personalized has three assets")
        let unknown = DDIAssetCatalog(schemaVersion: 2, upstreamRevision: catalog.upstreamRevision, mirrorBaseURL: catalog.mirrorBaseURL,
                                     upstreamBaseURL: catalog.upstreamBaseURL, families: catalog.families)
        rejects("Reject unknown catalog schema") { try unknown.validate() }
        FixtureProtocol.configure(mirror: .success)
        let eventLock = NSLock()
        var events: [(Double, String)] = []
        let cryptex = try run("cryptex", progress: { fraction, status in eventLock.lock(); events.append((fraction, status)); eventLock.unlock() })
        check(DDICache.isUsable(paths: cryptex, method: .cryptex, catalog: catalog), "Five validated files and matching receipt are usable")
        check(FixtureProtocol.requests.count == 5 && FixtureProtocol.requests.allSatisfy { $0.host == "mirror.test" }, "Healthy mirror never contacts upstream")
        check(events.contains { $0.0 > 0 && $0.0 < 1 && $0.1.hasPrefix("ddi|downloading|") }, "Streaming bytes produce intermediate total progress")
        check(events.last?.1.hasPrefix("ddi|committing|") == true, "Verified group reports commit phase")
        check(!DDICache.isUsable(paths: cryptex, method: .personalized, catalog: catalog), "Mount method mismatch invalidates cache")
        let changed = DDIAssetCatalog(schemaVersion: 1, upstreamRevision: String(repeating: "b", count: 40), mirrorBaseURL: catalog.mirrorBaseURL,
                                     upstreamBaseURL: catalog.upstreamBaseURL, families: catalog.families)
        check(!DDICache.isUsable(paths: cryptex, method: .cryptex, catalog: changed), "Catalog revision mismatch invalidates cache")
        try Data(repeating: 0xFF, count: payloads["Image.dmg"]!.count).write(to: URL(fileURLWithPath: cryptex.imagePath))
        check(!DDICache.isUsable(paths: cryptex, method: .cryptex, catalog: catalog), "Same-length corruption fails SHA-256 check")
        _ = try run("cryptex", method: .personalized)
        check(DDICache.isUsable(paths: cryptex, method: .personalized, catalog: catalog), "Personalized commit replaces cache and receipt")
        check(cryptex.cryptexOnlyPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Personalized commit removes Cryptex-only assets")
        try FileManager.default.removeItem(at: cryptex.receiptURL)
        check(!DDICache.isUsable(paths: cryptex, method: .personalized, catalog: catalog), "Legacy or interrupted cache without receipt is rejected")
        FixtureProtocol.configure(mirror: .missing)
        let fallback = try run("fallback")
        check(DDICache.isUsable(paths: fallback, method: .cryptex, catalog: catalog), "404 mirror recovers using pinned upstream")
        check(FixtureProtocol.requests.count == 10, "Every failed mirror asset gets one upstream attempt")
        FixtureProtocol.configure(mirror: .corrupt)
        check(DDICache.isUsable(paths: try run("checksum-fallback"), method: .cryptex, catalog: catalog), "Bad mirror hashes trigger upstream fallback")
        FixtureProtocol.configure(mirror: .oversized)
        check(DDICache.isUsable(paths: try run("oversized-fallback"), method: .cryptex, catalog: catalog), "Unbounded HTTP body is rejected and recovered")
        FixtureProtocol.configure(mirror: .connectionStall)
        check(DDICache.isUsable(paths: try run("connect-fallback"), method: .cryptex, catalog: catalog), "Connection timeout switches to upstream")
        FixtureProtocol.configure(mirror: .bodyStall)
        check(DDICache.isUsable(paths: try run("stall-fallback"), method: .cryptex, catalog: catalog), "Stalled byte stream switches to upstream")
        FixtureProtocol.configure(mirror: .missing, upstream: .missing)
        rejects("Both sources fail the operation") { _ = try run("both-fail") }
        check(!FileManager.default.fileExists(atPath: DDIPaths.default(in: root.appendingPathComponent("both-fail")).receiptURL.path), "Failed batch cannot create receipt")
        let prior = try Data(contentsOf: fallback.receiptURL)
        rejects("Redownload failure is reported") { _ = try run("fallback") }
        check(try Data(contentsOf: fallback.receiptURL) == prior && DDICache.isUsable(paths: fallback, method: .cryptex, catalog: catalog), "Failed staged download preserves prior complete batch")
        FixtureProtocol.configure(mirror: .connectionStall, upstream: .connectionStall)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.02
        rejects("External operation cancellation stops transfer") {
            _ = try run("cancel", cancellationCheck: { if ProcessInfo.processInfo.systemUptime > deadline { throw CancellationError() } })
        }
        check(FixtureProtocol.requests.count == 1, "Cancellation does not start fallback")
        let cancelPaths = DDIPaths.default(in: root.appendingPathComponent("cancel"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cancelPaths.receiptURL.deletingLastPathComponent().path)
        check(leftovers.isEmpty, "Cancellation cleans temporary batch")
        try fallback.removeCachedFiles()
        check(!FileManager.default.fileExists(atPath: fallback.receiptURL.path) && fallback.allPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Reset removes receipt and every asset")
        print("\(count) DDI download/cache tests passed")
    }
}
