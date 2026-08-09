import CoreLocation
import MapKit
import SwiftUI

struct MovementControlView: View {
    @EnvironmentObject private var session: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService

    @AppStorage(MovementDefaultsKey.profile) private var profileRaw = MovementProfile.walking.rawValue
    @AppStorage(MovementDefaultsKey.walkingSpeed) private var walkingSpeedKPH = 8.0
    @AppStorage(MovementDefaultsKey.cyclingSpeed) private var cyclingSpeedKPH = 16.0
    @State private var selectedMode: MovementMode = .joystick
    @State private var goalKind: SessionGoalKind = .steps
    @State private var goalValue = 10_000.0
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    private var profile: MovementProfile {
        MovementProfile(rawValue: profileRaw) ?? .walking
    }

    /// 当前方式下用来显示的速度（步行读步行速度，骑行读骑行速度）。
    private var displaySpeedKPH: Double {
        profile == .cycling ? cyclingSpeedKPH : walkingSpeedKPH
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("移动模式", selection: $selectedMode) {
                    Text("摇杆").tag(MovementMode.joystick)
                    Text("路线与定点").tag(MovementMode.route)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedMode == .joystick {
                    joystickContent
                } else {
                    LocationSimulationView()
                }
            }
            .navigationTitle("移动")
            .navigationBarTitleDisplayMode(.inline)
            .tint(PikminUI.green)
        }
    }

    private var joystickContent: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $mapPosition) {
                    if let coordinate = session.currentCoordinate {
                        Marker("当前位置", coordinate: coordinate)
                            .tint(.green)
                    }
                }
                // 平面地图，避免 3D 真实地形渲染在长时间会话中持续吃 GPU/CPU 发热。
                .mapStyle(.standard(elevation: .flat))
                .onTapGesture { point in
                    guard !session.isActive,
                          let coordinate = proxy.convert(point, from: .local) else { return }
                    session.setStartingCoordinate(coordinate)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 12) {
                if !preflight.canStartSession {
                    PreflightChecklistView(service: preflight, compact: true)
                }

                sessionControls

                if session.phase == .running || session.phase == .paused {
                    JoystickPad(heading: session.headingDegrees) { heading in
                        session.updateHeading(heading)
                        if session.phase == .paused { session.resume() }
                    } onRelease: {
                        if !session.cruiseLocked { session.pause() }
                    }
                    .frame(width: 150, height: 150)
                }
            }
            .padding()
        }
    }

    private var sessionControls: some View {
        VStack(spacing: 10) {
            if session.isActive {
                HStack {
                    Label(String(format: "%.2f km", session.distanceMeters / 1000), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Spacer()
                    Label(session.estimatedSteps.formatted(), systemImage: "figure.walk")
                    Spacer()
                    Label(String(format: "%.0f°", session.headingDegrees), systemImage: "location.north.fill")
                }
                .font(.caption.weight(.medium))

                Toggle("锁定方向并在后台巡航", isOn: $session.cruiseLocked)
                    .tint(.green)

                HStack {
                    Button(session.phase == .paused ? "继续" : "暂停") {
                        session.phase == .paused ? session.resume() : session.pause()
                    }
                    .buttonStyle(.bordered)

                    Button("结束") {
                        Task { await session.stop() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button("恢复真实定位", role: .destructive) {
                        Task { await session.restoreRealLocation() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Picker("目标", selection: $goalKind) {
                        ForEach(SessionGoalKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if goalKind != .manual {
                        TextField("目标", value: $goalValue, format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                    }
                }

                Button {
                    startSession()
                } label: {
                    Label(profile.startActionTitle, systemImage: profile == .cycling ? "bicycle" : "figure.walk.motion")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.green)
                .disabled(session.currentCoordinate == nil || !preflight.canStartSession)

                Text(session.currentCoordinate == nil
                     ? "点击地图选择起点".localized
                     : String(format: "起点已选择 · %1$@ %2$@ km/h".localized, profile.title, displaySpeedKPH.formatted()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = session.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .pikminControlCard()
    }

    private func startSession() {
        guard let coordinate = session.currentCoordinate else { return }
        let normalizedGoal: Double
        switch goalKind {
        case .steps, .manual: normalizedGoal = goalValue
        case .distance: normalizedGoal = goalValue * 1000
        case .duration: normalizedGoal = goalValue * 60
        }
        let movement = MovementParameters.current()
        let config = WalkingSessionConfig(
            mode: .joystick,
            goalKind: goalKind,
            goalValue: normalizedGoal,
            speedKilometersPerHour: movement.speedKPH,
            strideMeters: movement.strideMeters,
            startLatitude: coordinate.latitude,
            startLongitude: coordinate.longitude
        )
        Task { await session.start(config: config) }
    }
}

private struct JoystickPad: View {
    let heading: Double
    let onHeadingChange: (Double) -> Void
    let onRelease: () -> Void
    @State private var knobOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().stroke(PikminUI.green.opacity(0.5), lineWidth: 2)
                Image(systemName: "location.north.fill")
                    .foregroundStyle(PikminUI.green.opacity(0.35))
                    .rotationEffect(.degrees(heading))
                Circle()
                    .fill(PikminUI.green.gradient)
                    .frame(width: radius * 0.7, height: radius * 0.7)
                    .offset(knobOffset)
                    .shadow(radius: 5)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - proxy.size.width / 2
                        let dy = value.location.y - proxy.size.height / 2
                        let length = max(hypot(dx, dy), 0.001)
                        let limit = radius * 0.62
                        let scale = min(1, limit / length)
                        knobOffset = CGSize(width: dx * scale, height: dy * scale)
                        var degrees = atan2(dx, -dy) * 180 / .pi
                        if degrees < 0 { degrees += 360 }
                        onHeadingChange(degrees)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.25)) { knobOffset = .zero }
                        onRelease()
                    }
            )
        }
        .accessibilityLabel("移动摇杆")
    }
}
