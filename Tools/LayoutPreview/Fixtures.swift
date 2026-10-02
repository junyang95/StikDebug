// Layout-only fixtures. This executable never starts device services or contacts a server.
import SwiftUI

enum MainTab { case home, route, history, settings }
extension String { var localized: String { NSLocalizedString(self, comment: "") } }
enum WalkingSessionPhase { case idle, preparing, running, reconnecting, paused, completed, failed }
@MainActor final class WalkingSessionController: ObservableObject {
    var phase = WalkingSessionPhase.running
    var isActive = true
    var progress: Double? = 0.42
    var distanceMeters = 2350.0
    var estimatedSteps = 3248
    var elapsedSeconds = 1540.0
}
struct FixtureStatus { var isReady = true }
struct FixtureItem { var status = FixtureStatus() }
enum PreflightKind: String, CaseIterable, Identifiable {
    case wifi
    case vpnRoute
    case pairing
    case ddi
    case coreDeviceTunnel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi 网络".localized
        case .vpnRoute: "内置 VPN 路由".localized
        case .pairing: "设备配对文件".localized
        case .coreDeviceTunnel: "CoreDevice 隧道".localized
        case .ddi: "Developer Disk Image（可选）".localized
        }
    }

    var systemImage: String {
        switch self {
        case .wifi: "wifi"
        case .vpnRoute: "network.badge.shield.half.filled"
        case .pairing: "checkmark.shield"
        case .coreDeviceTunnel: "point.3.connected.trianglepath.dotted"
        case .ddi: "externaldrive.badge.checkmark"
        }
    }
}

enum PreflightStatus: Equatable {
    case unknown
    case checking
    case ready(String)
    case warning(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }

    var message: String {
        switch self {
        case .unknown: "尚未检查".localized
        case .checking: "正在检查…".localized
        case .ready(let message), .warning(let message), .failed(let message): message
        }
    }
}

struct PreflightItem: Identifiable, Equatable {
    let kind: PreflightKind
    var status: PreflightStatus
    var id: String { kind.id }
}

@MainActor final class EnvironmentPreflightService: ObservableObject {
    static let shared = EnvironmentPreflightService()
    var items = PreflightKind.allCases.map { PreflightItem(kind: $0, status: $0 == .ddi ? .warning("未安装 DDI；不影响定位模拟，仅额外开发服务需要。") : .ready("已就绪")) }
    var isRefreshing = false
    var ddiFilesMissing = true
    func refresh() async {}
    func connectDevice() {}
}
@MainActor final class PermissionChecklistService: ObservableObject {
    var items = Array(repeating: FixtureItem(), count: 4)
    func refresh() async {}
}
@MainActor final class HealthStepService: ObservableObject {
    static let dailySeedlingStepCap = 50_000
    var todayTotalSteps = 12_468
    var todayAppSteps = 3248
    func refreshToday() async {}
}
// Permission diagnostics are a placeholder; environment actions use the production view.
struct PermissionChecklistView: View {
    var service: PermissionChecklistService
    var compact = false
    var body: some View { Label("系统权限", systemImage: "checkmark.shield").frame(maxWidth: .infinity, alignment: .leading).pikminCard() }
}
@MainActor final class EmbeddedVPNService: ObservableObject {
    static let shared = EmbeddedVPNService()
    struct Status { var isConnected = true }
    var status = Status()
    func connect() async {}
}
enum DeviceConnectionContext { static let defaultTargetIPAddress = "10.7.0.1" }
extension DDIInstallationController {
    static let shared = preview()
    static func preview(failing: Bool = false) -> DDIInstallationController {
        DDIInstallationController(dependencies: .init(
            prepare: {},
            download: { _, callback in
                callback(0.42, "2/3 · Image.dmg")
                if failing { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已下载，但未确认 DDI 挂载成功。请检查内置 VPN 和开发者模式后重试。"]) }
                try await Task.sleep(for: .seconds(30))
            }, mount: {}, finish: {}))
    }
}
@MainActor final class OnDevicePairingService: ObservableObject {
    enum Phase: Equatable { case idle, advertising, deviceConnected, awaitingPIN, installing, succeeded, failed(String) }
    @Published var phase = Phase.idle
    var pin: String? { phase == .awaitingPIN ? "123456" : nil }
    var isBusy = false
    var isSupported = true
    func start() { phase = .awaitingPIN }
    func reset() { phase = .idle }
}

struct RouteLayoutFixture: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State var active = false
    var joystick = false
    @State private var style = 0
    @State private var loop = false
    @State private var searchText = ""
    var body: some View {
        NavigationStack {
            MapWorkspace(title: joystick ? "摇杆选项" : "路线选项") {
                // Offline backdrop: tests geometry, not map rendering or location services.
                ZStack {
                    Color(red: 0.85, green: 0.91, blue: 0.84)
                    Path { p in
                        p.move(to: CGPoint(x: 60, y: 60)); p.addLine(to: CGPoint(x: 140, y: 150)); p.addLine(to: CGPoint(x: 250, y: 80))
                    }.stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    VStack { Text("地图预览").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.top, 130)
                }
            } tools: {
                if !joystick {
                HStack {
                    Image(systemName: "magnifyingglass").font(.system(size: 18))
                    TextField("搜索地点或输入经纬度", text: $searchText)
                    Spacer(minLength: 0)
                    Image(systemName: "numbers.rectangle").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                }
            } options: {
                VStack(spacing: 10) {
                    Picker("路线规划", selection: $style) {
                        Text("步道优先").tag(0); Text("直线优先").tag(1)
                    }.adaptivePicker()
                    Text("使用 MapKit 步行路线，优先人行道和步道").font(.caption).foregroundStyle(.secondary)
                    Text("2 个路标 · 350 公尺 · 约 4 分").font(.footnote).monospacedDigit()
                    Toggle("闭环：至少需要 3 个点", isOn: $loop).font(.footnote)
                    AdaptiveControlGrid {
                        ForEach(["撤销", "保存", "GPX", "清空"], id: \.self) { title in
                            Button(title) {}.frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                        }
                    }
                }
            } actions: {
                if joystick {
                    VStack(spacing: 12) {
                        AdaptiveControlGrid(minimumWidth: 120) {
                            Button("暂停") {}.accessibleControl()
                            Button("停止行走") {}.accessibleControl()
                        }.buttonStyle(.bordered)
                        Circle().fill(PikminUI.green.opacity(0.2)).overlay(Image(systemName: "location.north.fill")).frame(width: 140, height: 140)
                        Button("恢复真实定位", role: .destructive) {}.accessibleControl()
                    }
                } else {
                    RouteActionBar(startTitle: "开始步行".localized, isActive: active, canStart: true, canRestore: true, start: { active = true }, stop: { active = false }, restore: {})
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Picker("移动模式", selection: $style) {
                        Text("定点").tag(2); Text("摇杆").tag(1); Text("路线").tag(0)
                    }.adaptivePicker().labelsHidden()
                    HStack {
                        Image(systemName: "leaf.fill").font(.system(size: 20)).frame(width: 34, height: 34).foregroundStyle(PikminUI.green)
                        VStack(alignment: .leading) {
                            Text(active ? "正在行走" : "已准备好").font(.subheadline.weight(.semibold))
                            if !typeSize.isAccessibilitySize {
                                Text("选择位置即可开始").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .padding(12)
                    .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .navigationTitle("模拟位置")
            .navigationBarTitleDisplayMode(.inline)
            .tint(PikminUI.green)
        }
    }
}

struct PreviewTabs: View {
    let content: AnyView
    let route: Bool
    var body: some View {
        TabView {
            content.tabItem { Label(route ? "路线" : "首页", systemImage: route ? "location" : "house.fill") }
            Text("Preview").tabItem { Label(route ? "首页" : "路线", systemImage: route ? "house" : "location") }
            Text("Preview").tabItem { Label("记录", systemImage: "calendar.badge.clock") }
            Text("Preview").tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
