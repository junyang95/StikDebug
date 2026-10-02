import CoreLocation
import Foundation
import Testing
@testable import PikminRuntime

@Suite(.serialized) @MainActor struct SessionTests {
    let session = WalkingSessionController.shared
    let fixed = FixedLocationSessionController.shared
    func setup() async {
        await session.restoreRealLocation()
        let now = Date().timeIntervalSince1970
        VipLocationGate.shared.update(VipLicense(udid: "test-device", status: "VALID", isVip: true,
            isBanned: false, expireAt: 0, nonce: "test", ts: now*1000))
        DeviceCommands.shared.reset()
    }
    func config(goal: SessionGoalKind = .manual, value: Double = 0) -> WalkingSessionConfig {
        WalkingSessionConfig(goalKind: goal, goalValue: value, startLatitude: 22.2946, startLongitude: 114.174)
    }
    func drain() async {
        await withCheckedContinuation { c in LocationSimulationCommandQueue.shared.async { c.resume() } }
    }
    @Test func manualRouteStopHoldsLastCoordinateWithoutClear() async throws {
        await setup()
        await session.startRoute(config: config(), coordinates: [config().startCoordinate,
            CLLocationCoordinate2D(latitude: 22.295, longitude: 114.175)])
        await session.stop()
        await drain()
        #expect(session.phase == .completed)
        #expect(fixed.coordinate?.latitude == session.currentCoordinate?.latitude)
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        #expect(BackgroundAudioManager.shared.leases == 1)
        await session.restoreRealLocation()
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(DeviceCommands.shared.snapshot().last == "clear")
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
    }
    @Test func pauseHoldsAndResumeReleasesOnlyFixedLease() async {
        await setup()
        await session.start(config: config())
        session.pause()
        #expect(fixed.coordinate != nil)
        #expect(BackgroundAudioManager.shared.leases == 2)
        session.resume()
        #expect(fixed.coordinate == nil)
        #expect(BackgroundAudioManager.shared.leases == 1)
        await session.restoreRealLocation()
    }
    @Test func goalCompletionHoldsPosition() async throws {
        await setup()
        await session.start(config: config(goal: .duration, value: 0.1))
        for _ in 0..<40 {
            if session.phase == .completed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.phase == .completed)
        #expect(fixed.coordinate != nil)
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        await session.restoreRealLocation()
    }
    @Test func stopDuringHealthAuthorizationCannotRestart() async {
        await setup()
        var release: CheckedContinuation<Bool, Never>?
        HealthStepService.shared.authorize = { await withCheckedContinuation { release = $0 } }
        let start = Task { await session.start(config: config()) }
        while release == nil { await Task.yield() }
        await session.stop()
        release?.resume(returning: true)
        await start.value
        HealthStepService.shared.authorize = nil
        #expect(session.phase == .completed)
        #expect(!DeviceCommands.shared.snapshot().contains("set"))
        await session.restoreRealLocation()
    }
    @Test func restoreDuringStopCannotReenableHold() async throws {
        await setup()
        await session.start(config: config())
        for _ in 0..<40 {
            if session.estimatedSteps > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        var release: CheckedContinuation<Bool, Never>?
        HealthStepService.shared.write = { await withCheckedContinuation { release = $0 } }
        let stopping = Task { await session.stop() }
        while release == nil { await Task.yield() }
        let restoring = Task { await session.restoreRealLocation() }
        await Task.yield()
        release?.resume(returning: true)
        await stopping.value
        await restoring.value
        HealthStepService.shared.write = nil
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(DeviceCommands.shared.snapshot().last == "clear")
        #expect(BackgroundAudioManager.shared.leases == 0)
        let commands = DeviceCommands.shared.snapshot()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(DeviceCommands.shared.snapshot() == commands)
    }
    @Test func revokedLicenseStopsWithoutHoldingOrClearing() async {
        await setup()
        await session.start(config: config())
        VipLocationGate.shared.update(nil)
        await session.stop(holdLocation: false)
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        #expect(BackgroundAudioManager.shared.leases == 0)
    }
}
