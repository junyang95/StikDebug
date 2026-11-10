import CoreLocation
import Foundation
import Testing
@testable import PikminRuntime

@Suite(.serialized) @MainActor struct SessionTests {
    let session = WalkingSessionController.shared
    let fixed = FixedLocationSessionController.shared
    func setup() async {
        LocationNetworkGate.shared.update(.wifi)
        EnvironmentPreflightService.shared.canStartSession = true
        await session.restoreRealLocation()
        DeviceCommands.shared.reset()
    }
    func config(goal: SessionGoalKind = .manual, value: Double = 0) -> WalkingSessionConfig {
        WalkingSessionConfig(goalKind: goal, goalValue: value, startLatitude: 22.2946, startLongitude: 114.174)
    }
    func drain() async {
        await withCheckedContinuation { c in LocationSimulationCommandQueue.shared.async { c.resume() } }
    }

    @Test func networkBlocksBothWalkingModesBeforeDeviceCommands() async {
        let blockedStates: [LocationNetworkState] = [.checking, .cellular, .unavailable]
        for state in blockedStates {
            for usesRoute in [false, true] {
                await setup()
                LocationNetworkGate.shared.update(state)
                if usesRoute {
                    await session.startRoute(config: config(), coordinates: [
                        config().startCoordinate,
                        CLLocationCoordinate2D(latitude: 22.295, longitude: 114.175)
                    ])
                } else {
                    await session.start(config: config())
                }
                await drain()
                #expect(session.phase == .failed)
                #expect(session.lastError == state.blockingMessage)
                #expect(DeviceCommands.shared.snapshot().isEmpty)
                #expect(BackgroundAudioManager.shared.leases == 0)
                #expect(BackgroundLocationManager.shared.leases == 0)
                LocationNetworkGate.shared.update(.wifi)
                session.handleNetworkChange()
                #expect(session.phase == .idle)
                #expect(session.lastError == nil)
                #expect(DeviceCommands.shared.snapshot().isEmpty)
            }
        }
        await setup()
    }

    @Test func cellularCannotStartOrHoldFixedLocation() async {
        await setup()
        LocationNetworkGate.shared.update(.cellular)
        fixed.start(config().startCoordinate, isForeground: true)
        fixed.hold(config().startCoordinate)
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(fixed.lastError == LocationNetworkState.cellular.blockingMessage)
        #expect(DeviceCommands.shared.snapshot().isEmpty)
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)

        // The Wi-Fi requirement never prevents an explicit real-GPS recovery.
        await session.restoreRealLocation()
        #expect(DeviceCommands.shared.snapshot() == ["clear"])
        #expect(session.lastError == nil && fixed.lastError == nil)
        await setup()
    }

    @Test func losingWiFiStopsFixedKeepAliveWithoutClearingLocation() async {
        await setup()
        fixed.hold(config().startCoordinate)
        await drain()
        #expect(fixed.coordinate != nil)
        #expect(BackgroundAudioManager.shared.leases == 1)
        let commands = DeviceCommands.shared.snapshot()

        LocationNetworkGate.shared.update(.cellular)
        fixed.handleNetworkChange()
        fixed.updateForegroundState(false)
        fixed.updateForegroundState(true)
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(fixed.lastError == LocationNetworkState.cellular.blockingMessage)
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
        #expect(DeviceCommands.shared.snapshot() == commands)
        #expect(!commands.contains("clear"))
        LocationNetworkGate.shared.update(.wifi)
        fixed.handleNetworkChange()
        #expect(fixed.lastError == nil)
        #expect(fixed.coordinate == nil)
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(DeviceCommands.shared.snapshot() == commands)
        await setup()
    }

    @Test func networkLossPausesMovementAndRequiresWiFiBeforeResume() async throws {
        await setup()
        await session.start(config: config())
        await drain()
        #expect(session.phase == .running)
        LocationNetworkGate.shared.update(.cellular)
        session.handleNetworkChange()
        #expect(session.phase == .paused)
        #expect(session.lastError == LocationNetworkState.cellular.blockingMessage)
        #expect(fixed.coordinate == nil)
        let steps = session.estimatedSteps
        let distance = session.distanceMeters
        let commands = DeviceCommands.shared.snapshot()

        session.resume()
        session.refreshAfterForeground()
        #expect(session.phase == .paused)
        try await Task.sleep(for: .milliseconds(1200))
        await drain()
        #expect(session.estimatedSteps == steps)
        #expect(session.distanceMeters == distance)
        #expect(DeviceCommands.shared.snapshot() == commands)

        LocationNetworkGate.shared.update(.wifi)
        session.handleNetworkChange()
        #expect(session.phase == .paused)
        #expect(session.lastError == nil)
        #expect(DeviceCommands.shared.snapshot() == commands)
        session.resume()
        #expect(session.phase == .running)
        #expect(session.lastError == nil)
        session.refreshAfterForeground()
        for _ in 0..<100 where DeviceCommands.shared.snapshot().count == commands.count {
            await Task.yield()
        }
        await drain()
        #expect(DeviceCommands.shared.snapshot().count > commands.count)
        await session.restoreRealLocation()
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
    }

    @Test func cellularResumeReleasesPausedFixedHold() async {
        await setup()
        await session.start(config: config())
        session.pause()
        await drain()
        #expect(fixed.coordinate != nil)
        #expect(BackgroundAudioManager.shared.leases == 2)

        LocationNetworkGate.shared.update(.cellular)
        session.handleNetworkChange()
        session.resume()
        #expect(session.phase == .paused)
        #expect(session.lastError == LocationNetworkState.cellular.blockingMessage)
        #expect(fixed.coordinate == nil)
        #expect(BackgroundAudioManager.shared.leases == 1)
        await session.restoreRealLocation()
        #expect(DeviceCommands.shared.snapshot().last == "clear")
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
        await setup()
    }

    @Test func networkLossCancelsReconnectBeforeAnotherDeviceCommand() async throws {
        await setup()
        await session.start(config: config())
        DeviceCommands.shared.respondToSet { 11 }
        session.refreshAfterForeground()
        for _ in 0..<1000 where session.phase != .reconnecting { await Task.yield() }
        #expect(session.phase == .reconnecting)

        LocationNetworkGate.shared.update(.cellular)
        session.handleNetworkChange()
        let commands = DeviceCommands.shared.snapshot()
        #expect(session.phase == .paused)
        #expect(session.reconnectAttempt == 0)
        #expect(session.lastError == LocationNetworkState.cellular.blockingMessage)
        // Wait past the first reconnect delay to catch a stale retry reviving the session.
        try await Task.sleep(for: .milliseconds(1200))
        await drain()
        #expect(session.phase == .paused)
        #expect(DeviceCommands.shared.snapshot() == commands)
        await setup()
    }

    @Test func networkChangeDuringAuthorizationCannotSendStartingLocation() async {
        await setup()
        var release: CheckedContinuation<Bool, Never>?
        HealthStepService.shared.authorize = { await withCheckedContinuation { release = $0 } }
        let start = Task { await session.start(config: config()) }
        while release == nil { await Task.yield() }
        LocationNetworkGate.shared.update(.cellular)
        session.handleNetworkChange()
        release?.resume(returning: true)
        await start.value
        HealthStepService.shared.authorize = nil
        await drain()
        #expect(session.phase == .failed)
        #expect(session.lastError == LocationNetworkState.cellular.blockingMessage)
        #expect(DeviceCommands.shared.snapshot().isEmpty)
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
        await setup()
    }

    @Test func bindingFailureStopsFixedKeepAliveAndKeepsRecoveryAvailable() async throws {
        for code: Int32 in 80...86 {
            await setup()
            DeviceCommands.shared.respondToSet { code }
            fixed.hold(config().startCoordinate)
            await drain()
            for _ in 0..<100 where fixed.lastError == nil { await Task.yield() }
            #expect(fixed.coordinate == nil)
            #expect(fixed.lastError == OfflineBindingMessages.message(for: code))
            #expect(BackgroundAudioManager.shared.leases == 0)
            #expect(BackgroundLocationManager.shared.leases == 0)
            #expect(!DeviceCommands.shared.snapshot().contains("clear"))
            fixed.handleNetworkChange()
            #expect(fixed.lastError == OfflineBindingMessages.message(for: code))
            if code == 86 {
                let commands = DeviceCommands.shared.snapshot()
                try await Task.sleep(for: .milliseconds(1200))
                #expect(DeviceCommands.shared.snapshot() == commands)
            }
            await session.restoreRealLocation()
            #expect(DeviceCommands.shared.snapshot().last == "clear")
            #expect(fixed.lastError == nil && session.lastError == nil)
        }
    }

    @Test func delayedNetworkFailureDoesNotLeaveFixedWarningAfterWiFiRecovery() async {
        await setup()
        // A command may have been blocked earlier, while its result arrives after Wi-Fi returns.
        DeviceCommands.shared.respondToSet { LocationNetworkGate.blockedStatus }
        fixed.hold(config().startCoordinate)
        await drain()
        for _ in 0..<1000 where fixed.coordinate != nil { await Task.yield() }
        #expect(DeviceCommands.shared.snapshot() == ["set"])
        #expect(fixed.coordinate == nil)
        #expect(fixed.lastError == nil)
        #expect(BackgroundAudioManager.shared.leases == 0)
        #expect(BackgroundLocationManager.shared.leases == 0)
        await setup()
    }

    @Test func delayedNetworkFailureDoesNotLeaveWalkingWarningAfterWiFiRecovery() async {
        await setup()
        DeviceCommands.shared.respondToSet { LocationNetworkGate.blockedStatus }
        await session.start(config: config())
        #expect(session.phase == .idle)
        #expect(session.lastError == nil)
        #expect(DeviceCommands.shared.snapshot() == ["set"])

        await setup()
        await session.start(config: config())
        DeviceCommands.shared.respondToSet { LocationNetworkGate.blockedStatus }
        session.refreshAfterForeground()
        for _ in 0..<1000 where session.phase == .running { await Task.yield() }
        #expect(session.phase == .paused)
        #expect(session.lastError == nil)
        #expect(DeviceCommands.shared.snapshot() == ["set", "set"])
        #expect(fixed.coordinate == nil)
        await setup()
    }

    @Test func wifiRecoveryPreservesWalkingBindingFailures() async {
        await setup()
        DeviceCommands.shared.respondToSet { 86 }
        await session.start(config: config())
        session.handleNetworkChange()
        #expect(session.phase == .failed)
        #expect(session.lastError == OfflineBindingMessages.message(for: 86))

        await setup()
        await session.start(config: config())
        DeviceCommands.shared.respondToSet { 86 }
        session.refreshAfterForeground()
        for _ in 0..<1000 where session.phase == .running { await Task.yield() }
        session.handleNetworkChange()
        #expect(session.phase == .paused)
        #expect(session.lastError == OfflineBindingMessages.message(for: 86))
        await setup()
    }

    @Test func transientFixedLocationFailureKeepsRetrying() async {
        await setup()
        DeviceCommands.shared.respondToSet { 11 }
        fixed.hold(config().startCoordinate)
        await drain()
        #expect(fixed.coordinate != nil && fixed.lastError == nil)
        #expect(BackgroundAudioManager.shared.leases == 1)
        DeviceCommands.shared.respondToSet(nil)
        fixed.updateForegroundState(false)
        fixed.updateForegroundState(true)
        await drain()
        #expect(DeviceCommands.shared.snapshot().filter { $0 == "set" }.count == 2)
        await session.restoreRealLocation()
    }

    @Test func staleBindingFailureCannotStopANewerFixedSession() async {
        await setup()
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DeviceCommands.shared.respondToSet {
            began.signal()
            release.wait()
            return 86
        }
        fixed.hold(config().startCoordinate)
        while began.wait(timeout: .now()) != .success { await Task.yield() }
        let replacement = CLLocationCoordinate2D(latitude: 35, longitude: 139)
        fixed.start(replacement, isForeground: true)
        DeviceCommands.shared.respondToSet(nil)
        release.signal()
        await drain()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixed.coordinate?.latitude == replacement.latitude)
        #expect(fixed.lastError == nil)
        #expect(BackgroundAudioManager.shared.leases == 1)
        await session.restoreRealLocation()
    }

    @Test func localReadinessStartsSessionWithoutWebsiteAuthorization() async {
        await setup()
        await session.start(config: config())
        await drain()
        #expect(session.phase == .running)
        #expect(DeviceCommands.shared.snapshot().contains("set"))
        await session.restoreRealLocation()
    }
    @Test func manualRouteStopHoldsLastCoordinateWithoutClear() async throws {
        await setup()
        await session.startRoute(config: config(), coordinates: [config().startCoordinate,
            CLLocationCoordinate2D(latitude: 22.295, longitude: 114.175)])
        #expect(session.activeRouteEndBehavior == .reverse)
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

    @Test func onePassRouteStopsAtTheLastPointWithoutOvershootOrClearingLocation() async throws {
        await setup()
        var routeConfig = config()
        routeConfig.speedKilometersPerHour = 3.6
        routeConfig.usesNaturalSpeedVariation = false
        let middle = MovementMath.offset(routeConfig.startCoordinate, eastMeters: 0.2, northMeters: 0)
        let end = MovementMath.offset(middle, eastMeters: 0, northMeters: 0.2)
        let traversal = try #require(RouteTraversal(coordinates: [routeConfig.startCoordinate, middle, end], endBehavior: .stopAtEnd))
        await session.startRoute(config: routeConfig, coordinates: traversal.coordinates, endBehavior: .stopAtEnd)
        #expect(session.activeRouteEndBehavior == .stopAtEnd)
        #expect(session.progress == 0)
        for _ in 0..<60 where session.phase != .completed { try await Task.sleep(for: .milliseconds(50)) }
        await drain()
        #expect(session.phase == .completed)
        #expect(session.currentCoordinate?.latitude == end.latitude && session.currentCoordinate?.longitude == end.longitude)
        #expect(fixed.coordinate?.latitude == end.latitude && fixed.coordinate?.longitude == end.longitude)
        #expect(abs(session.distanceMeters - traversal.totalDistance) < 0.000_001)
        #expect(abs(session.elapsedSeconds - traversal.totalDistance) < 0.000_001)
        #expect(session.estimatedSteps == Int(traversal.totalDistance / routeConfig.strideMeters))
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        #expect(BackgroundAudioManager.shared.leases == 1 && BackgroundLocationManager.shared.leases == 1)
        await session.restoreRealLocation()
    }

    @Test func finalPointFailureMustReconnectBeforeCompleting() async throws {
        await setup()
        var routeConfig = config()
        routeConfig.usesNaturalSpeedVariation = false
        let end = MovementMath.offset(routeConfig.startCoordinate, eastMeters: 0.2, northMeters: 0)
        await session.startRoute(config: routeConfig, coordinates: [routeConfig.startCoordinate, end], endBehavior: .stopAtEnd)
        DeviceCommands.shared.respondToSet { 11 }
        for _ in 0..<60 where session.phase != .reconnecting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.phase == .reconnecting)
        #expect(fixed.coordinate == nil)
        let distanceAtEndpoint = session.distanceMeters
        let elapsedAtEndpoint = session.elapsedSeconds
        DeviceCommands.shared.respondToSet(nil)
        for _ in 0..<60 where session.phase != .completed { try await Task.sleep(for: .milliseconds(50)) }
        await drain()
        #expect(session.phase == .completed)
        #expect(session.distanceMeters == distanceAtEndpoint && session.elapsedSeconds == elapsedAtEndpoint)
        #expect(fixed.coordinate?.latitude == end.latitude && fixed.coordinate?.longitude == end.longitude)
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        await session.restoreRealLocation()
    }

    @Test func losingWiFiDuringFinalSendDoesNotCompleteUntilExplicitResume() async throws {
        await setup()
        var routeConfig = config()
        routeConfig.usesNaturalSpeedVariation = false
        let end = MovementMath.offset(routeConfig.startCoordinate, eastMeters: 0.2, northMeters: 0)
        await session.startRoute(config: routeConfig, coordinates: [routeConfig.startCoordinate, end], endBehavior: .stopAtEnd)
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DeviceCommands.shared.respondToSet {
            began.signal()
            release.wait()
            return 0
        }
        var commandBegan = false
        for _ in 0..<60 {
            if began.wait(timeout: .now()) == .success { commandBegan = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(commandBegan)
        LocationNetworkGate.shared.update(.cellular)
        session.handleNetworkChange()
        DeviceCommands.shared.respondToSet(nil)
        release.signal()
        await drain()
        for _ in 0..<100 { await Task.yield() }
        #expect(session.phase == .paused && fixed.coordinate == nil)
        LocationNetworkGate.shared.update(.wifi)
        session.handleNetworkChange()
        #expect(session.phase == .paused)
        session.resume()
        session.refreshAfterForeground()
        for _ in 0..<60 where session.phase != .completed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.phase == .completed)
        #expect(fixed.coordinate?.latitude == end.latitude && fixed.coordinate?.longitude == end.longitude)
        await session.restoreRealLocation()
    }

    @Test func legacyLoopArgumentStillSelectsLoopingPlayback() async {
        await setup()
        await session.startRoute(config: config(), coordinates: [config().startCoordinate,
            CLLocationCoordinate2D(latitude: 22.295, longitude: 114.175)], isLoop: true)
        #expect(session.activeRouteEndBehavior == .loop)
        await session.restoreRealLocation()
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
    @Test func stoppingWithoutHoldKeepsExplicitRestoreAvailable() async {
        await setup()
        await session.start(config: config())
        await session.stop(holdLocation: false)
        await drain()
        #expect(fixed.coordinate == nil)
        #expect(!DeviceCommands.shared.snapshot().contains("clear"))
        #expect(BackgroundAudioManager.shared.leases == 0)
        // Stopping a session and restoring physical GPS remain separate actions.
        await session.restoreRealLocation()
        await drain()
        #expect(DeviceCommands.shared.snapshot().last == "clear")
        #expect(session.currentCoordinate == nil && session.lastError == nil)
    }
}
