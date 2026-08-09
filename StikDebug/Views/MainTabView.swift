import SwiftData
import SwiftUI

enum MainTab: Hashable {
    case home
    case route
    case history
    case settings
}

/// 进程级保存当前标签页。切换语言会重建整棵视图树，
/// 没有它的话用户会被从设置页弹回首页。
private enum TabState {
    @MainActor static var selected: MainTab = .home
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var session: WalkingSessionController
    @EnvironmentObject private var health: HealthStepService
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @State private var selectedTab: MainTab = TabState.selected

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    private let seedlingFAQURL = URL(string: "https://niantic.helpshift.com/hc/en/23-pikmin-bloom/faq/3343-faq-about-seedlings/")!

    private var capNoticePresented: Binding<Bool> {
        Binding(
            get: { health.pendingCapNotice != nil },
            set: { if !$0 { health.pendingCapNotice = nil } }
        )
    }

    private var capNoticeTitle: String {
        switch health.pendingCapNotice {
        case .reached: "今天步数已达每日上限".localized
        case .approaching: "今天步数接近每日上限".localized
        case nil: "关于今天的步数".localized
        }
    }

    private func capNoticeMessage(for stage: HealthStepService.DailyCapStage) -> String {
        let steps = health.todayTotalSteps.formatted()
        let cap = HealthStepService.dailySeedlingStepCap.formatted()
        switch stage {
        case .approaching:
            return String(
                format: "皮克敏官方规定：盆栽花苗每天最多只反映 %1$@ 步。你今天已经 %2$@ 步，快到上限了。\n\n超过后，今天多走的步数不会再让花苗成长，要等隔天重置。是否继续由你决定，App 不会自动停止或停写。".localized,
                cap, steps
            )
        case .reached:
            return String(
                format: "皮克敏官方规定：盆栽花苗每天最多只反映 %1$@ 步。你今天已经 %2$@ 步，已达上限。\n\n之后多走的步数今天不会再计入花苗成长，要等隔天重置；继续使用也不会加快花苗，还可能让数据显得异常。是否继续由你决定，App 不会自动停止或停写。".localized,
                cap, steps
            )
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayDashboardView(selectedTab: $selectedTab)
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(MainTab.home)

            MovementControlView()
                .tabItem { Label("路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(MainTab.route)

            SessionHistoryView()
                .tabItem { Label("记录", systemImage: "calendar.badge.clock") }
                .tag(MainTab.history)

            HelperSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(MainTab.settings)
        }
        .tint(PikminUI.green)
        .preferredColorScheme(appearance.colorScheme)
        .alert(
            capNoticeTitle,
            isPresented: capNoticePresented,
            presenting: health.pendingCapNotice
        ) { _ in
            Button("继续使用", role: .cancel) {
                health.pendingCapNotice = nil
            }
            if session.isActive {
                Button("结束当前会话", role: .destructive) {
                    health.pendingCapNotice = nil
                    Task { await session.stop(reason: "达到每日花苗上限".localized) }
                }
            }
            Button("查看官方说明") {
                health.pendingCapNotice = nil
                openURL(seedlingFAQURL)
            }
        } message: { stage in
            Text(capNoticeMessage(for: stage))
        }
        .onChange(of: selectedTab) { _, tab in
            TabState.selected = tab
        }
        .onAppear {
            session.attach(modelContext: modelContext)
        }
    }
}
