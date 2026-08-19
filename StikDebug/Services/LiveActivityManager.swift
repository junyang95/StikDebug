import ActivityKit
import CoreLocation
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<PikminSessionAttributes>?
    private var lastUpdateAt = Date.distantPast

    private init() {}

    func start(
        config: WalkingSessionConfig,
        coordinate: CLLocationCoordinate2D,
        phase: WalkingSessionPhase
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await end(
            state: makeState(
                phase: phase,
                steps: 0,
                distanceMeters: 0,
                speedKilometersPerHour: config.speedKilometersPerHour,
                coordinate: coordinate
            ),
            immediate: true
        )

        let attributes = PikminSessionAttributes(
            mode: config.mode.title,
            startedAt: Date()
        )
        let state = makeState(
            phase: phase,
            steps: 0,
            distanceMeters: 0,
            speedKilometersPerHour: config.speedKilometersPerHour,
            coordinate: coordinate
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(20)),
                pushType: nil
            )
            lastUpdateAt = Date()
        } catch {
            LogManager.shared.addWarningLog("无法启动实时活动：\(error.localizedDescription)")
        }
    }

    func update(
        phase: WalkingSessionPhase,
        steps: Int,
        distanceMeters: Double,
        speedKilometersPerHour: Double,
        coordinate: CLLocationCoordinate2D,
        force: Bool = false
    ) async {
        guard let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdateAt) >= 5 else { return }
        lastUpdateAt = now
        let state = makeState(
            phase: phase,
            steps: steps,
            distanceMeters: distanceMeters,
            speedKilometersPerHour: speedKilometersPerHour,
            coordinate: coordinate
        )
        await activity.update(
            ActivityContent(state: state, staleDate: now.addingTimeInterval(20))
        )
    }

    func end(
        state: PikminSessionAttributes.ContentState,
        immediate: Bool = false
    ) async {
        guard let activity else { return }
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: immediate ? .immediate : .after(Date().addingTimeInterval(30))
        )
        self.activity = nil
        lastUpdateAt = .distantPast
    }

    func end(
        phase: WalkingSessionPhase,
        steps: Int,
        distanceMeters: Double,
        speedKilometersPerHour: Double,
        coordinate: CLLocationCoordinate2D?
    ) async {
        let fallback = coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        await end(
            state: makeState(
                phase: phase,
                steps: steps,
                distanceMeters: distanceMeters,
                speedKilometersPerHour: speedKilometersPerHour,
                coordinate: fallback
            )
        )
    }

    private func makeState(
        phase: WalkingSessionPhase,
        steps: Int,
        distanceMeters: Double,
        speedKilometersPerHour: Double,
        coordinate: CLLocationCoordinate2D
    ) -> PikminSessionAttributes.ContentState {
        PikminSessionAttributes.ContentState(
            phase: phase.activityTitle,
            steps: steps,
            distanceMeters: distanceMeters,
            speedKilometersPerHour: speedKilometersPerHour,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

private extension WalkingSessionPhase {
    var activityTitle: String {
        switch self {
        case .idle: "未开始".localized
        case .preparing: "准备中".localized
        case .running: "模拟中".localized
        case .reconnecting: "重连中".localized
        case .paused: "已暂停".localized
        case .completed: "已完成".localized
        case .failed: "已中断".localized
        }
    }
}
