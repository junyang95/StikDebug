import CoreLocation
import Foundation
import SwiftData

@MainActor
final class WalkingSessionController: ObservableObject {
    static let shared = WalkingSessionController()

    @Published private(set) var phase: WalkingSessionPhase = .idle
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var estimatedSteps = 0
    @Published private(set) var healthStepsWritten = 0
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var lastError: String?
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var currentSpeedKilometersPerHour = 0.0
    @Published var headingDegrees = 0.0
    @Published var cruiseLocked = false

    private let locationQueue = LocationSimulationCommandQueue.shared
    private var timer: DispatchSourceTimer?
    private var config: WalkingSessionConfig?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var lastTickAt: Date?
    private var batchStartedAt: Date?
    private var lastWrittenEstimatedSteps = 0
    private var pendingFractionalSteps = 0.0
    private var jitterEast = 0.0
    private var jitterNorth = 0.0
    private var jitterTargetEast = 0.0
    private var jitterTargetNorth = 0.0
    private var jitterTargetAge = 0.0
    private var isSendingLocation = false
    private var healthWriteTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var speedOffsetStart = 0.0
    private var speedOffsetTarget = 0.0
    private var speedVariationAge = 0.0
    private var speedVariationDuration = 10.0
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var routeTargetIndex = 1
    private var routeDirection = 1
    /// 闭环路径循环绕圈，非闭环路径走到终点后原路折返。
    private var routeIsLoop = false
    private weak var modelContext: ModelContext?

    private init() {}

    var isActive: Bool {
        phase == .running || phase == .reconnecting || phase == .paused || phase == .preparing
    }

    /// 当前会话真正采用的模式和速度。设置页里的值可能在会话开始后被修改，
    /// 状态界面应显示已经锁定到本次会话里的配置，而不是最新偏好值。
    var activeMode: MovementMode? {
        config?.mode
    }

    var activeSpeedKilometersPerHour: Double? {
        guard let config else { return nil }
        return currentSpeedKilometersPerHour > 0
            ? currentSpeedKilometersPerHour
            : config.speedKilometersPerHour
    }

    var progress: Double? {
        guard let config, config.goalKind != .manual, config.goalValue > 0 else { return nil }
        let current: Double
        switch config.goalKind {
        case .steps: current = Double(estimatedSteps)
        case .distance: current = distanceMeters
        case .duration: current = elapsedSeconds
        case .manual: return nil
        }
        return min(current / config.goalValue, 1)
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setStartingCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard !isActive else { return }
        currentCoordinate = coordinate
    }

    func start(config: WalkingSessionConfig) async {
        routeCoordinates = []
        routeIsLoop = false
        await startPreparedSession(config: config)
    }

    func startRoute(
        config: WalkingSessionConfig,
        coordinates: [CLLocationCoordinate2D],
        isLoop: Bool = false
    ) async {
        let validCoordinates = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard validCoordinates.count > 1 else {
            fail("路线至少需要两个有效坐标".localized)
            return
        }
        routeCoordinates = validCoordinates
        routeTargetIndex = 1
        routeDirection = 1
        routeIsLoop = isLoop
        var routeConfig = config
        routeConfig.mode = .route
        routeConfig.startLatitude = validCoordinates[0].latitude
        routeConfig.startLongitude = validCoordinates[0].longitude
        await startPreparedSession(config: routeConfig)
    }

    private func startPreparedSession(config: WalkingSessionConfig) async {
        guard !isActive else { return }
        guard CLLocationCoordinate2DIsValid(config.startCoordinate) else {
            fail("请选择有效的起点".localized)
            return
        }
        guard EnvironmentPreflightService.shared.canStartSession else {
            fail("环境检查尚未通过".localized)
            return
        }

        phase = .preparing
        lastError = nil
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        SessionNotificationService.shared.requestAuthorizationIfNeeded()
        _ = await HealthStepService.shared.requestAuthorization()

        let initialCode = await sendLocation(config.startCoordinate)
        guard initialCode == 0 else {
            fail(String(format: "无法开始位置模拟（错误 %d）".localized, initialCode))
            return
        }

        self.config = config
        sessionID = UUID()
        startedAt = Date()
        lastTickAt = startedAt
        batchStartedAt = startedAt
        currentCoordinate = config.startCoordinate
        RecentLocationStore.record(
            config.startCoordinate,
            name: config.mode == .route ? "路线起点".localized : "摇杆起点".localized
        )
        distanceMeters = 0
        estimatedSteps = 0
        healthStepsWritten = 0
        elapsedSeconds = 0
        lastWrittenEstimatedSteps = 0
        pendingFractionalSteps = 0
        resetJitter()
        resetSpeedVariation(for: config)
        phase = .running

        Task {
            await LiveActivityManager.shared.start(
                config: config,
                coordinate: config.startCoordinate,
                phase: .running
            )
        }

        BackgroundAudioManager.shared.requestStart()
        BackgroundLocationManager.shared.requestStart()
        startTimer()
    }

    func pause() {
        guard phase == .running else { return }
        phase = .paused
        lastTickAt = Date()
        updateLiveActivity(force: true)
    }

    func resume() {
        guard phase == .paused else { return }
        reconnectAttempt = 0
        lastError = nil
        phase = .running
        lastTickAt = Date()
        updateLiveActivity(force: true)
    }

    func stop(reason: String = "用户停止".localized) async {
        guard isActive else { return }
        await flushHealthSteps()
        finish(reason: reason, phase: .completed)
    }

    func restoreRealLocation() async {
        if isActive {
            await stop(reason: "恢复真实定位".localized)
        }

        // 会话没在跑时也要停掉保活，否则后台定位和静音音频会一直挂着。
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()

        let pairingPath = PairingFileStore.url.path
        let code = await withCheckedContinuation { continuation in
            locationQueue.async {
                continuation.resume(returning: clear_simulated_location(
                    DeviceConnectionContext.targetIPAddress,
                    pairingPath
                ))
            }
        }
        if code == 0 {
            currentCoordinate = nil
            lastError = nil
        } else {
            lastError = String(format: "清除模拟定位失败（错误 %d），请确认设备仍然连接后重试".localized, code)
        }
    }

    func updateHeading(_ degrees: Double) {
        headingDegrees = degrees.truncatingRemainder(dividingBy: 360)
        if headingDegrees < 0 { headingDegrees += 360 }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard phase == .running,
              let config,
              let baseCoordinate = currentCoordinate,
              !isSendingLocation else {
            return
        }

        let now = Date()
        let delta = min(max(now.timeIntervalSince(lastTickAt ?? now), 0.25), 2.5)
        lastTickAt = now
        elapsedSeconds += delta

        let speedMultiplier = updateSpeedVariation(config: config, delta: delta)
        let currentSpeedMetersPerSecond = config.speedMetersPerSecond * speedMultiplier
        currentSpeedKilometersPerHour = currentSpeedMetersPerSecond * 3.6
        let traveled = currentSpeedMetersPerSecond * delta
        let nextBase: CLLocationCoordinate2D
        if config.mode == .route, routeCoordinates.count > 1 {
            nextBase = advanceAlongRoute(from: baseCoordinate, distance: traveled)
        } else {
            nextBase = MovementMath.destination(from: baseCoordinate, distance: traveled, bearingDegrees: headingDegrees)
        }
        distanceMeters += traveled

        let exactSteps = (traveled / max(config.strideMeters, 0.2)) + pendingFractionalSteps
        let wholeSteps = Int(exactSteps)
        pendingFractionalSteps = exactSteps - Double(wholeSteps)
        estimatedSteps += wholeSteps

        updateJitter(delta: delta)
        let simulatedCoordinate = MovementMath.offset(
            nextBase,
            eastMeters: jitterEast,
            northMeters: jitterNorth
        )
        currentCoordinate = nextBase
        updateLiveActivity()
        isSendingLocation = true

        Task {
            let code = await sendLocation(simulatedCoordinate)
            await MainActor.run {
                self.isSendingLocation = false
                self.handleLocationResult(code)
            }
        }

        if now.timeIntervalSince(batchStartedAt ?? now) >= 30 {
            let batchStart = batchStartedAt ?? now.addingTimeInterval(-30)
            batchStartedAt = now
            enqueueHealthBatch(from: batchStart, to: now)
        }

        if hasReachedGoal(config) {
            phase = .preparing
            Task {
                await flushHealthSteps()
                finish(reason: "目标完成".localized, phase: .completed)
            }
        }
    }

    private func writeHealthBatch(from start: Date, to end: Date) async {
        guard let sessionID else { return }
        let count = estimatedSteps - lastWrittenEstimatedSteps
        guard count > 0 else { return }
        if await HealthStepService.shared.writeSteps(count, from: start, to: end, sessionID: sessionID) {
            lastWrittenEstimatedSteps += count
            healthStepsWritten += count
        }
    }

    private func flushHealthSteps() async {
        await healthWriteTask?.value
        let start = batchStartedAt ?? Date()
        await writeHealthBatch(from: start, to: Date())
    }

    private func enqueueHealthBatch(from start: Date, to end: Date) {
        let previousTask = healthWriteTask
        healthWriteTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            await self.writeHealthBatch(from: start, to: end)
        }
    }

    private func hasReachedGoal(_ config: WalkingSessionConfig) -> Bool {
        switch config.goalKind {
        case .steps: Double(estimatedSteps) >= config.goalValue
        case .distance: distanceMeters >= config.goalValue
        case .duration: elapsedSeconds >= config.goalValue
        case .manual: false
        }
    }

    private func finish(reason: String, phase finalPhase: WalkingSessionPhase) {
        let finalSpeed = currentSpeedKilometersPerHour
        let finalCoordinate = currentCoordinate
        let finalSteps = estimatedSteps
        let finalDistance = distanceMeters
        timer?.cancel()
        timer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        currentSpeedKilometersPerHour = 0
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()

        if let id = sessionID, let startedAt, let config {
            let record = WalkingSessionRecord(
                id: id,
                startedAt: startedAt,
                endedAt: Date(),
                mode: config.mode,
                distanceMeters: distanceMeters,
                estimatedSteps: estimatedSteps,
                healthStepsWritten: healthStepsWritten,
                durationSeconds: elapsedSeconds,
                terminationReason: reason
            )
            modelContext?.insert(record)
            try? modelContext?.save()
        }

        phase = finalPhase
        Task {
            await LiveActivityManager.shared.end(
                phase: finalPhase,
                steps: finalSteps,
                distanceMeters: finalDistance,
                speedKilometersPerHour: finalSpeed,
                coordinate: finalCoordinate
            )
        }
        config = nil
        routeCoordinates = []
        routeIsLoop = false
        sessionID = nil
        startedAt = nil
        lastTickAt = nil
        batchStartedAt = nil
        healthWriteTask = nil
    }

    private func fail(_ message: String) {
        timer?.cancel()
        timer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        currentSpeedKilometersPerHour = 0
        phase = .failed
        lastError = message
        updateLiveActivity(force: true)
    }

    private func handleLocationResult(_ code: Int32) {
        guard phase == .running, config != nil else { return }
        guard code != 0 else { return }
        beginReconnect(after: code)
    }

    private func beginReconnect(after initialErrorCode: Int32) {
        guard config != nil, reconnectTask == nil else { return }
        phase = .reconnecting
        reconnectAttempt = 0
        lastError = String(
            format: "位置连接中断（错误 %d），正在自动重连".localized,
            initialErrorCode
        )
        SessionNotificationService.shared.notifyConnectionDropped()
        updateLiveActivity(force: true)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var latestErrorCode = initialErrorCode

            for (index, delay) in SessionReconnectPolicy.retryDelaysSeconds.enumerated() {
                guard !Task.isCancelled, self.config != nil else { return }
                self.reconnectAttempt = index + 1

                if !EmbeddedVPNService.shared.status.isConnected {
                    await EmbeddedVPNService.shared.connect()
                }

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      self.config != nil,
                      let coordinate = self.currentCoordinate else { return }

                latestErrorCode = await self.sendLocation(coordinate)
                if latestErrorCode == 0 {
                    self.reconnectTask = nil
                    self.reconnectAttempt = 0
                    self.lastError = nil
                    self.lastTickAt = Date()
                    self.phase = .running
                    self.updateLiveActivity(force: true)
                    SessionNotificationService.shared.notifyReconnected()
                    LogManager.shared.addInfoLog("位置连接已自动恢复")
                    return
                }
            }

            guard !Task.isCancelled, self.config != nil else { return }
            self.reconnectTask = nil
            self.phase = .paused
            self.lastError = String(
                format: "自动重连 %1$d 次后仍失败（错误 %2$d），会话已暂停".localized,
                SessionReconnectPolicy.maximumAttempts,
                latestErrorCode
            )
            SessionNotificationService.shared.notifyReconnectFailed()
            self.updateLiveActivity(force: true)
            LogManager.shared.addErrorLog(self.lastError ?? "位置自动重连失败".localized)
        }
    }

    private func sendLocation(_ coordinate: CLLocationCoordinate2D) async -> Int32 {
        let pairingPath = PairingFileStore.url.path
        return await withCheckedContinuation { continuation in
            locationQueue.async {
                continuation.resume(returning: simulate_location(
                    DeviceConnectionContext.targetIPAddress,
                    coordinate.latitude,
                    coordinate.longitude,
                    pairingPath
                ))
            }
        }
    }

    private func resetJitter() {
        jitterEast = 0
        jitterNorth = 0
        jitterTargetEast = 0
        jitterTargetNorth = 0
        jitterTargetAge = 10
    }

    private func resetSpeedVariation(for config: WalkingSessionConfig) {
        speedOffsetStart = 0
        speedOffsetTarget = config.usesNaturalSpeedVariation
            ? Double.random(in: -config.speedVariationFraction...config.speedVariationFraction)
            : 0
        speedVariationAge = 0
        speedVariationDuration = Double.random(in: 8...16)
        currentSpeedKilometersPerHour = config.speedKilometersPerHour
    }

    private func updateSpeedVariation(config: WalkingSessionConfig, delta: TimeInterval) -> Double {
        guard config.usesNaturalSpeedVariation, config.speedVariationFraction > 0 else { return 1 }
        speedVariationAge += delta
        if speedVariationAge >= speedVariationDuration {
            speedOffsetStart = speedOffsetTarget
            speedOffsetTarget = Double.random(
                in: -config.speedVariationFraction...config.speedVariationFraction
            )
            speedVariationAge = 0
            speedVariationDuration = Double.random(in: 8...16)
        }
        return NaturalSpeedVariation.multiplier(
            from: speedOffsetStart,
            to: speedOffsetTarget,
            progress: speedVariationAge / speedVariationDuration,
            maximumFraction: config.speedVariationFraction
        )
    }

    private func updateLiveActivity(force: Bool = false) {
        guard let coordinate = currentCoordinate else { return }
        let phase = phase
        let steps = estimatedSteps
        let distance = distanceMeters
        let speed = currentSpeedKilometersPerHour
        Task {
            await LiveActivityManager.shared.update(
                phase: phase,
                steps: steps,
                distanceMeters: distance,
                speedKilometersPerHour: speed,
                coordinate: coordinate,
                force: force
            )
        }
    }

    private func updateJitter(delta: TimeInterval) {
        jitterTargetAge += delta
        if jitterTargetAge >= 4 {
            let radius = Double.random(in: 2...3)
            let angle = Double.random(in: 0...(2 * .pi))
            jitterTargetEast = cos(angle) * radius
            jitterTargetNorth = sin(angle) * radius
            jitterTargetAge = 0
        }
        let smoothing = min(delta / 4, 0.35)
        jitterEast += (jitterTargetEast - jitterEast) * smoothing
        jitterNorth += (jitterTargetNorth - jitterNorth) * smoothing
    }

    private func advanceAlongRoute(
        from start: CLLocationCoordinate2D,
        distance: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        var current = start
        var remaining = distance
        var safetyCounter = 0

        while remaining > 0.001, safetyCounter < routeCoordinates.count * 2 {
            safetyCounter += 1
            let target = routeCoordinates[routeTargetIndex]
            let segmentDistance = CLLocation(latitude: current.latitude, longitude: current.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

            if segmentDistance > remaining {
                let bearing = MovementMath.bearing(from: current, to: target)
                current = MovementMath.destination(from: current, distance: remaining, bearingDegrees: bearing)
                remaining = 0
            } else {
                current = target
                remaining -= segmentDistance
                if routeIsLoop {
                    routeTargetIndex = (routeTargetIndex + 1) % routeCoordinates.count
                } else if routeDirection > 0, routeTargetIndex == routeCoordinates.count - 1 {
                    routeDirection = -1
                    routeTargetIndex = max(routeCoordinates.count - 2, 0)
                } else if routeDirection < 0, routeTargetIndex == 0 {
                    routeDirection = 1
                    routeTargetIndex = min(1, routeCoordinates.count - 1)
                } else {
                    routeTargetIndex += routeDirection
                }
            }
        }
        return current
    }

}
