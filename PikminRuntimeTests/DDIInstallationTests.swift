import Foundation
import Testing
@testable import PikminRuntime

@MainActor private final class DDIFixture {
    var calls: [String] = []
    var preparation: (() async throws -> Void)?
    var transfer: (() async throws -> Void)?
    var mounting: (() async throws -> Void)?
    var progress: (@Sendable (Double, String) -> Void)?
    var forced = false
    func make() -> DDIInstallationController {
        DDIInstallationController(dependencies: .init(
            prepare: { self.calls.append("prepare"); try await self.preparation?() },
            download: { force, callback in
                self.calls.append("download"); self.forced = force; self.progress = callback
                try await self.transfer?()
            },
            mount: { self.calls.append("mount"); try await self.mounting?() },
            finish: { self.calls.append("finish") }))
    }
}

@Suite(.serialized) @MainActor struct DDIInstallationTests {
    @Test func oneActionDownloadsMountsAndVerifies() async {
        let f = DDIFixture()
        let installer = f.make()
        installer.start()
        installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "download", "mount", "finish"])
        #expect(installer.phase == .completed)
    }
    @Test func preparationFailureDoesNotDownload() async {
        let f = DDIFixture()
        f.preparation = { throw URLError(.cannotConnectToHost) }
        let installer = f.make(); installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "finish"])
        if case .failed = installer.phase {} else { Issue.record("Must show preparation failure") }
    }
    @Test func failedDownloadNeverMountsAndRetryCanRedownload() async {
        let f = DDIFixture()
        f.transfer = { throw URLError(.networkConnectionLost) }
        let installer = f.make(); installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "download", "finish"])
        if case .failed = installer.phase {} else { Issue.record("Must show download failure") }
        f.transfer = nil
        installer.start(redownload: true)
        await wait { !installer.isRunning }
        #expect(installer.phase == .completed && f.forced)
    }
    @Test func mountFailureNeverReportsInstalled() async {
        let f = DDIFixture()
        f.mounting = { throw URLError(.cannotConnectToHost) }
        let installer = f.make(); installer.start()
        await wait { !installer.isRunning }
        if case .failed = installer.phase {} else { Issue.record("Must show mount failure") }
        #expect(f.calls.last == "finish")
    }
    @Test func cancelledDownloadNeverMountsOrAcceptsLateProgress() async {
        let f = DDIFixture()
        f.transfer = { try await Task.sleep(for: .seconds(30)) }
        let installer = f.make(); installer.start()
        await wait { f.progress != nil }
        installer.cancel()
        await wait { !installer.isRunning }
        f.progress?(0.9, "late callback")
        await Task.yield()
        #expect(installer.phase == .cancelled && installer.downloadDetail != "late callback")
        #expect(f.calls == ["prepare", "download", "finish"])
    }
    @Test func nativeMountCannotBeCancelledOrDuplicated() async {
        let f = DDIFixture()
        var pending: CheckedContinuation<Void, Never>?
        f.mounting = { await withCheckedContinuation { pending = $0 } }
        let installer = f.make(); installer.start()
        await wait { pending != nil }
        #expect(!installer.canCancel)
        installer.cancel(); installer.start()
        #expect(installer.phase == .mounting)
        pending?.resume()
        await wait { !installer.isRunning }
        #expect(installer.phase == .completed)
        #expect(f.calls.filter { $0 == "mount" }.count == 1)
    }
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 where !predicate() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
}

struct DDIDownloadValidationTests {
    @Test(arguments: ["html", "empty", "foreign-host", "http", "bad-status", "invalid-plist"])
    func failedReplacementKeepsExistingFile(kind: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(kind == "invalid-plist" ? "BuildManifest.plist" : "Image.dmg")
        let incoming = directory.appendingPathComponent("incoming")
        let old = Data("previous-complete-file".utf8)
        try old.write(to: destination)
        try Data((kind == "html" ? "<html>maintenance</html>" : kind == "empty" ? "" : "not-a-plist").utf8).write(to: incoming)
        let url = URL(string: kind == "foreign-host" ? "https://example.com/Image.dmg" : kind == "http" ? "http://static.wow-app.store/Image.dmg" : "https://static.wow-app.store/Image.dmg")!
        let response = HTTPURLResponse(url: url, statusCode: kind == "bad-status" ? 503 : 200, httpVersion: nil, headerFields: nil)!
        #expect(throws: (any Error).self) {
            try DeveloperDiskImageService().installDownloadedFile(at: incoming, response: response, to: destination)
        }
        #expect(try Data(contentsOf: destination) == old)
    }

    @Test func validReplacementMovesCompleteFileAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Image.dmg")
        let incoming = directory.appendingPathComponent("incoming")
        try Data("old".utf8).write(to: destination)
        let updated = Data([0, 1, 2, 3, 4])
        try updated.write(to: incoming)
        let response = HTTPURLResponse(url: URL(string: "https://static.wow-app.store/Image.dmg")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try DeveloperDiskImageService().installDownloadedFile(at: incoming, response: response, to: destination)
        #expect(try Data(contentsOf: destination) == updated)
    }
}
