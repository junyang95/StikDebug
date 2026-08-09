import SwiftUI

enum PikminUI {
    /// 随浅色/深色自动切换的颜色。深色模式下才能真正适配夜览，而不是把浅色底硬套上去。
    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // 主色在深色下略微提亮，保证在深色卡片上仍清晰。
    static let green = adaptive(light: (0.12, 0.72, 0.30), dark: (0.28, 0.82, 0.44))
    static let deepGreen = adaptive(light: (0.04, 0.48, 0.22), dark: (0.42, 0.86, 0.54))
    static let softGreen = adaptive(light: (0.92, 0.98, 0.91), dark: (0.12, 0.22, 0.15))
    static let pageBackground = adaptive(light: (0.965, 0.985, 0.955), dark: (0.055, 0.075, 0.06))
    static let cardBackground = adaptive(light: (0.99, 1.0, 0.99), dark: (0.13, 0.16, 0.14))

    /// 卡片内的浅色分隔/进度轨道，随主题自动明暗。
    static let hairline = Color.primary.opacity(0.08)

    static let cardCornerRadius: CGFloat = 22
    static let tileCornerRadius: CGFloat = 16

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.80, blue: 0.36),
                Color(red: 0.10, green: 0.68, blue: 0.28)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension View {
    func pikminCard(cornerRadius: CGFloat = PikminUI.cardCornerRadius) -> some View {
        padding()
            .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
    }
}

extension View {
    /// 覆盖在地图上的操作面板样式。摇杆页和路线/定点页共用同一张不透明卡片，
    /// 保证两个界面观感一致，而不是一个卡片、一个半透明浮层。
    func pikminControlCard() -> some View {
        padding()
            .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }
}

/// 今日步数所处的区间。以皮克敏花苗每日 5 万步上限为参照，
/// 用绿/黄/红让用户一眼看出今天的力度是否合理、是否快到上限。
enum StepStage {
    case healthy   // 0 – 3 万：合理
    case elevated  // 3 – 4 万：偏多
    case high      // 4 – 5 万：接近上限
    case capped    // ≥ 5 万：已达上限

    static func stage(for steps: Int) -> StepStage {
        switch steps {
        case ..<30_000: .healthy
        case ..<40_000: .elevated
        case ..<HealthStepService.dailySeedlingStepCap: .high
        default: .capped
        }
    }

    var label: String {
        switch self {
        case .healthy: "合理范围".localized
        case .elevated: "偏多".localized
        case .high: "接近上限".localized
        case .capped: "已达上限".localized
        }
    }

    /// 区间说明，用于图例。
    var rangeText: String {
        switch self {
        case .healthy: "0–3 万 合理".localized
        case .elevated: "3–4 万 偏多".localized
        case .high: "4–5 万 接近上限".localized
        case .capped: "≥5 万 已达上限".localized
        }
    }

    var tint: Color {
        switch self {
        case .healthy: Color(red: 0.13, green: 0.70, blue: 0.32)
        case .elevated: Color(red: 0.86, green: 0.62, blue: 0.10)
        case .high: Color(red: 0.93, green: 0.50, blue: 0.14)
        case .capped: Color(red: 0.88, green: 0.24, blue: 0.22)
        }
    }

    /// 卡片渐变——足够深，保证白字清晰。
    var gradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .healthy:
            stops = [Color(red: 0.16, green: 0.80, blue: 0.36), Color(red: 0.08, green: 0.62, blue: 0.26)]
        case .elevated:
            stops = [Color(red: 0.90, green: 0.66, blue: 0.14), Color(red: 0.74, green: 0.50, blue: 0.06)]
        case .high:
            stops = [Color(red: 0.96, green: 0.55, blue: 0.16), Color(red: 0.82, green: 0.38, blue: 0.08)]
        case .capped:
            stops = [Color(red: 0.92, green: 0.30, blue: 0.26), Color(red: 0.78, green: 0.16, blue: 0.16)]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct TodayDashboardView: View {
    @Binding var selectedTab: MainTab
    @EnvironmentObject private var session: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var permissions: PermissionChecklistService
    @EnvironmentObject private var health: HealthStepService

    /// 首页以皮克敏花苗每日 5 万步上限作为满格参照，而不是原来的 1 万。
    private let dailyStepGoal = HealthStepService.dailySeedlingStepCap

    /// 皮克敏官方帮助中心：iOS 步数来自 Apple 健康、可能有几小时延迟。
    private let stepDelayFAQURL = URL(string: "https://niantic.helpshift.com/hc/en/23-pikmin-bloom/faq/2861-my-steps-aren-t-being-counted-correctly-ios/")!

    private var stepStage: StepStage {
        StepStage.stage(for: health.todayTotalSteps)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    overviewCard
                    stageLegend

                    LazyVGrid(columns: cardColumns, spacing: 14) {
                        statusTile(
                            emoji: "🌱",
                            title: "Helper 写入",
                            value: String(format: "%@ 步".localized, health.todayAppSteps.formatted()),
                            progress: helperWriteProgress,
                            accent: PikminUI.green
                        )
                        statusTile(
                            emoji: "🚶",
                            title: "行走状态",
                            value: phaseTitle,
                            progress: session.progress ?? 0,
                            accent: .green
                        )
                        statusTile(
                            emoji: "🛡️",
                            title: "系统权限",
                            value: "\(readyPermissionCount) / \(permissions.items.count)",
                            progress: permissionProgress,
                            accent: .mint
                        )
                        statusTile(
                            emoji: "🍀",
                            title: "运行环境",
                            value: "\(readyPreflightCount) / \(preflight.items.count)",
                            progress: preflightProgress,
                            accent: .green
                        )
                    }

                    if session.isActive || session.phase == .completed || session.phase == .failed {
                        activeSessionCard
                    }

                    quickActionsCard
                    compactChecklistCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await permissions.refresh()
                await health.refreshToday()
                await preflight.refresh()
            }
            .task {
                await permissions.refresh()
                await health.refreshToday()
                await preflight.refresh()
            }
        }
    }

    private var cardColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    private var background: some View {
        ZStack {
            PikminUI.pageBackground.ignoresSafeArea()
            LinearGradient(
                colors: [
                    PikminUI.softGreen.opacity(0.55),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // 原来左上角的叶子只是装饰、右上角齿轮和底部「设置」标签重复，都移除；
    // 改成标题 + 今天日期，让这块留白有实际信息。
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pikmin 日常助手")
                    .font(.title3.weight(.bold))
                Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("今日总步数")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(stepStage.label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.24), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(health.todayTotalSteps.formatted())
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("步")
                            .font(.headline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }

                Spacer()

                progressRing(progress: dailyStepProgress, text: "\(Int(dailyStepProgress * 100))%")
                    .frame(width: 76, height: 76)
            }

            // 到 5 万上限的进度条，并在 3 万 / 4 万处标出阶段分界。
            VStack(alignment: .leading, spacing: 6) {
                thresholdBar
                Text(String(format: "上限 %@ 步 · 超过后当天不再计入花苗成长".localized, dailyStepGoal.formatted()))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
            }

            Divider().overlay(.white.opacity(0.3))

            // 官方说明：步数来自 Apple 健康，同步有延迟。
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("步数来自 Apple 健康，皮克敏同步可能有几小时延迟，不会马上显示。")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.88))
                    Link("查看官方说明", destination: stepDelayFAQURL)
                        .font(.caption.weight(.semibold))
                        .tint(.white)
                }
            }
        }
        // 黄/红阶段底色偏亮，给白字加一层淡阴影保证清晰。
        .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
        .padding(20)
        .background(stepStage.gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 140, height: 140)
                .offset(x: 34, y: -54)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: stepStage.tint.opacity(0.28), radius: 22, x: 0, y: 12)
        .animation(.easeInOut(duration: 0.35), value: health.todayTotalSteps)
    }

    /// 到 5 万的进度条，白色填充；在 3 万、4 万分界处画竖线，让用户看清自己落在哪一段。
    private var thresholdBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = min(Double(health.todayTotalSteps) / Double(dailyStepGoal), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(height: 10)
                Capsule()
                    .fill(.white)
                    .frame(width: max(width * progress, progress > 0 ? 6 : 0), height: 10)
                ForEach([30_000, 40_000], id: \.self) { threshold in
                    Rectangle()
                        .fill(.white.opacity(0.75))
                        .frame(width: 2, height: 16)
                        .offset(x: width * Double(threshold) / Double(dailyStepGoal) - 1)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
    }

    /// 阶段图例：绿/黄/红分别代表哪一段步数，放在概览卡下方，在浅底上颜色更清楚。
    private var stageLegend: some View {
        HStack(spacing: 10) {
            ForEach([StepStage.healthy, .elevated, .high], id: \.rangeText) { stage in
                HStack(spacing: 5) {
                    Circle()
                        .fill(stage.tint)
                        .frame(width: 9, height: 9)
                    Text(stage.rangeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statusTile(
        emoji: String,
        title: LocalizedStringKey,
        value: String,
        progress: Double,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(emoji).font(.system(size: 30))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()

            ProgressView(value: min(max(progress, 0), 1))
                .tint(accent)
                .background(PikminUI.hairline, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pikminCard(cornerRadius: PikminUI.tileCornerRadius)
    }

    private var activeSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("行走会话", systemImage: "location.fill")
                    .font(.headline)
                    .foregroundStyle(PikminUI.deepGreen)
                Spacer()
                Text(phaseTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(PikminUI.softGreen, in: Capsule())
                    .foregroundStyle(PikminUI.deepGreen)
            }

            if let progress = session.progress {
                ProgressView(value: progress)
                    .tint(PikminUI.green)
            }

            HStack {
                sessionMetric("距离", String(format: "%.2f km", session.distanceMeters / 1000))
                sessionMetric("步数", session.estimatedSteps.formatted())
                sessionMetric("时间", durationText(session.elapsedSeconds))
            }
        }
        .pikminCard()
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷功能")
                .font(.headline.weight(.bold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                quickAction("路线模拟", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                    selectedTab = .route
                }
                quickAction("虚拟步行", icon: "figure.walk.motion") {
                    selectedTab = .route
                }
                quickAction("步数辅助", icon: "heart.text.square") {
                    selectedTab = .settings
                }
                quickAction("种花路线", icon: "camera.macro") {
                    selectedTab = .route
                }
                quickAction("定位场景", icon: "mappin.and.ellipse") {
                    selectedTab = .route
                }
                quickAction("环境检查", icon: "checkmark.shield") {
                    selectedTab = .settings
                }
            }
        }
        .pikminCard()
    }

    private func quickAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PikminUI.green)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(PikminUI.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var compactChecklistCard: some View {
        VStack(spacing: 14) {
            PermissionChecklistView(service: permissions, compact: true)
            PreflightChecklistView(service: preflight, compact: true)
        }
    }

    private func progressRing(progress: Double, text: String) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private func sessionMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var dailyStepProgress: Double {
        min(Double(health.todayTotalSteps) / Double(dailyStepGoal), 1)
    }

    private var helperWriteProgress: Double {
        min(Double(health.todayAppSteps) / max(Double(dailyStepGoal), 1), 1)
    }

    private var readyPermissionCount: Int {
        permissions.items.filter(\.status.isReady).count
    }

    private var readyPreflightCount: Int {
        preflight.items.filter(\.status.isReady).count
    }

    private var permissionProgress: Double {
        guard !permissions.items.isEmpty else { return 0 }
        return Double(readyPermissionCount) / Double(permissions.items.count)
    }

    private var preflightProgress: Double {
        guard !preflight.items.isEmpty else { return 0 }
        return Double(readyPreflightCount) / Double(preflight.items.count)
    }

    private var phaseTitle: String {
        switch session.phase {
        case .idle: "未开始".localized
        case .preparing: "准备中".localized
        case .running: "运行中".localized
        case .paused: "已暂停".localized
        case .completed: "已完成".localized
        case .failed: "失败".localized
        }
    }

    private func durationText(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
