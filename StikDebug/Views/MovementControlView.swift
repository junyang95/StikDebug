import CoreLocation
import MapKit
import SwiftUI

struct MovementControlView: View {
    @EnvironmentObject private var session: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var vpn: EmbeddedVPNService

    @AppStorage(MovementDefaultsKey.profile) private var profileRaw = MovementProfile.walking.rawValue
    @AppStorage(MovementDefaultsKey.walkingSpeed) private var walkingSpeedKPH = 5.0
    @AppStorage(MovementDefaultsKey.cyclingSpeed) private var cyclingSpeedKPH = 16.0
    @State private var selectedMode: MovementMode = .fixedLocation
    @State private var goalKind: SessionGoalKind = .steps
    @State private var goalValue = 10_000.0
    @FocusState private var goalFocused: Bool
    @AppStorage(MapCoordinateSystem.storageKey) private var mapCoordinatesRaw = MapCoordinateSystem.wgs84.rawValue
    private var mapCoordinates: MapCoordinateSystem { MapCoordinateSystem(rawValue: mapCoordinatesRaw) ?? .wgs84 }
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
            Group {
                if selectedMode == .joystick {
                    joystickContent
                } else {
                    LocationSimulationView(selectedMode: $selectedMode)
                }

            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Picker("移动模式", selection: $selectedMode) {
                        Label("定点", systemImage: "mappin").tag(MovementMode.fixedLocation)
                        Label("摇杆", systemImage: "move.3d").tag(MovementMode.joystick)
                        Label("路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .tag(MovementMode.route)
                    }
                    .adaptivePicker()
                    .labelsHidden()
                    .disabled(session.isActive)

                    MovementStatusCapsule(
                        selectedMode: selectedMode,
                        selectedProfile: profile,
                        selectedSpeedKilometersPerHour: displaySpeedKPH
                    )
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .toolbar {
                if selectedMode == .joystick {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { goalFocused = false }
                    }
                }
            }
            .navigationTitle("模拟位置")
            .navigationBarTitleDisplayMode(.inline)
            .tint(PikminUI.green)
        }
    }

    private var joystickContent: some View {
        MapWorkspace(title: "摇杆选项") {
            MapReader { proxy in
                Map(position: $mapPosition) {
                    if let coordinate = session.currentCoordinate {
                        Marker("当前位置", coordinate: mapCoordinates.toMap(coordinate))
                            .tint(.green)
                    }
                }
                // 平面地图，避免 3D 真实地形渲染在长时间会话中持续吃 GPU/CPU 发热。
                .mapStyle(.standard(elevation: .flat))
                .onTapGesture { point in
                    guard !session.isActive,
                          let coordinate = proxy.convert(point, from: .local) else { return }
                    session.setStartingCoordinate(mapCoordinates.fromMap(coordinate))
                }
            }
        } tools: {
            EmptyView()
        } options: {
            sessionControls
        } actions: {
            VStack(spacing: 12) {
                if !session.isActive {
                    Button(action: startSession) {
                        Label(profile.startActionTitle, systemImage: profile == .cycling ? "bicycle" : "figure.walk.motion")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PikminUI.actionGreen)
                    .disabled(session.currentCoordinate == nil || !preflight.canStartSession)
                } else {
                    AdaptiveControlGrid(minimumWidth: 120) {
                        Button {
                            session.phase == .paused ? session.resume() : session.pause()
                        } label: {
                            Text(session.phase == .paused ? "继续" : "暂停")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(session.phase == .preparing || session.phase == .reconnecting)
                        Button { Task { await session.stop() } } label: {
                            Text("停止行走").frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if session.phase == .running || session.phase == .paused {
                    JoystickPad(heading: session.headingDegrees) { heading in
                        session.updateHeading(heading)
                        if session.phase == .paused { session.resume() }
                    } onRelease: {
                        if !session.cruiseLocked { session.pause() }
                    } onPause: {
                        session.pause()
                    }
                    .frame(width: 140, height: 140)
                }
                Button(role: .destructive) {
                    Task { await session.restoreRealLocation() }
                } label: {
                    Text("恢复真实定位").frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private var sessionControls: some View {
        VStack(spacing: 10) {
            if session.isActive {
                AdaptiveControlGrid(minimumWidth: 100) {
                    Label(String(format: "%.2f km", session.distanceMeters / 1000), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(session.estimatedSteps.formatted(), systemImage: "figure.walk")
                    Label(String(format: "%.0f°", session.headingDegrees), systemImage: "location.north.fill")
                }
                .font(.caption.weight(.medium))

                Toggle("锁定方向并在后台巡航", isOn: $session.cruiseLocked)
                    .tint(.green)

                if session.phase == .reconnecting {
                    Label(String(format: "正在重连（%1$d/%2$d）".localized,
                                 max(session.reconnectAttempt, 1), SessionReconnectPolicy.maximumAttempts),
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
            } else {
                AdaptiveActionStack {
                    Picker("目标", selection: $goalKind) {
                        ForEach(SessionGoalKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if goalKind != .manual {
                        TextField("目标", value: $goalValue, format: .number)
                            .focused($goalFocused)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 100, maxWidth: .infinity)
                            .accessibilityLabel("目标数值")
                    }
                }

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
            usesNaturalSpeedVariation: movement.usesNaturalSpeedVariation,
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
    let onPause: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        withAnimation(reduceMotion ? nil : .spring(response: 0.25)) { knobOffset = .zero }
                        onRelease()
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("移动摇杆")
        .accessibilityValue(String(format: "%.0f°", heading))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onHeadingChange((heading + 15).truncatingRemainder(dividingBy: 360))
            case .decrement: onHeadingChange((heading + 345).truncatingRemainder(dividingBy: 360))
            @unknown default: break
            }
        }
        .accessibilityAction(named: "暂停移动", onPause)
    }
}
