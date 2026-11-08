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
            install: { force, callback in
                self.calls.append("install"); self.forced = force; self.progress = callback
                try await self.transfer?()
            },
            mount: { self.calls.append("mount"); try await self.mounting?() },
            finish: { self.calls.append("finish") }))
    }
}

@Suite(.serialized) @MainActor struct DDIInstallationTests {
    @Test func oneActionInstallsMountsAndVerifies() async {
        let f = DDIFixture()
        let installer = f.make()
        installer.start()
        installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "install", "mount", "finish"])
        #expect(installer.phase == .completed)
    }
    @Test func preparationFailureDoesNotInstall() async {
        let f = DDIFixture()
        f.preparation = { throw URLError(.cannotConnectToHost) }
        let installer = f.make(); installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "finish"])
        if case .failed = installer.phase {} else { Issue.record("Must show preparation failure") }
    }
    @Test func failedInstallationNeverMountsAndRetryCanRestore() async {
        let f = DDIFixture()
        f.transfer = { throw CocoaError(.fileReadCorruptFile) }
        let installer = f.make(); installer.start()
        await wait { !installer.isRunning }
        #expect(f.calls == ["prepare", "install", "finish"])
        if case .failed = installer.phase {} else { Issue.record("Must show installation failure") }
        f.transfer = nil
        installer.start(restore: true)
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
    @Test func cancelledInstallationNeverMountsOrAcceptsLateProgress() async {
        let f = DDIFixture()
        f.transfer = { try await Task.sleep(for: .seconds(30)) }
        let installer = f.make(); installer.start()
        await wait { f.progress != nil }
        installer.cancel()
        await wait { !installer.isRunning }
        f.progress?(0.9, "late callback")
        await Task.yield()
        #expect(installer.phase == .cancelled && installer.installationDetail != "late callback")
        #expect(f.calls == ["prepare", "install", "finish"])
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
