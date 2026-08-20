import SwiftUI

struct HelperSettingsView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var permissions: PermissionChecklistService
    @EnvironmentObject private var health: HealthStepService
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @EnvironmentObject private var onDevicePairing: OnDevicePairingService
    @AppStorage(MovementDefaultsKey.profile) private var profileRaw = MovementProfile.walking.rawValue
    @AppStorage(MovementDefaultsKey.walkingSpeed) private var walkingSpeedKPH = 5.0
    @AppStorage(MovementDefaultsKey.walkingStride) private var strideMeters = 0.75
    @AppStorage(MovementDefaultsKey.walkingPace) private var walkingPaceRaw = WalkingPace.natural.rawValue
    @AppStorage(MovementDefaultsKey.naturalSpeedVariation) private var naturalSpeedVariation = true
    @AppStorage(MovementDefaultsKey.cyclingSpeed) private var cyclingSpeedKPH = 16.0
    @AppStorage(MovementDefaultsKey.cyclingDevelopment) private var cyclingDevelopment = 5.0
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("autoConnectEmbeddedVPN") private var autoConnectVPN = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage(SetupGate.completedKey) private var setupCompleted = false
    @AppStorage(SetupGate.forceShowKey) private var forceShowSetup = false
    @State private var showPairingImporter = false
    @State private var showOnDevicePairing = false
    @State private var importMessage: String?
    @State private var isGeneratingDiagnostics = false
    @State private var diagnosticsText: String?
    @State private var showDiagnostics = false
    @State private var showPrivacyDetails = false

    private var profile: MovementProfile {
        get { MovementProfile(rawValue: profileRaw) ?? .walking }
        nonmutating set { profileRaw = newValue.rawValue }
    }

    /// 当前速度下的步频（每分钟步数）。步幅固定时随速度线性变化。
    private var walkingCadence: Double {
        (walkingSpeedKPH / 3.6) / max(strideMeters, 0.1) * 60
    }

    private var walkingPaceBinding: Binding<WalkingPace> {
        Binding(
            get: {
                let stored = WalkingPace(rawValue: walkingPaceRaw) ?? .natural
                guard let presetSpeed = stored.speedKilometersPerHour else { return .custom }
                return abs(presetSpeed - walkingSpeedKPH) < 0.01 ? stored : .custom
            },
            set: { pace in
                walkingPaceRaw = pace.rawValue
                if let speed = pace.speedKilometersPerHour {
                    walkingSpeedKPH = speed
                }
            }
        )
    }

    /// 当前速度下的骑行踏频（每分钟转数）。展开固定时，踏频 = 速度 ÷ 展开，随速度线性变化。
    private var cyclingCadence: Double {
        (cyclingSpeedKPH / 3.6) / max(cyclingDevelopment, 0.1) * 60
    }

    /// 踏频滑块：调节它相当于「换挡」——在当前速度下改变展开；
    /// 而调节速度时展开不变，踏频便随速度线性升降。
    private var cyclingCadenceBinding: Binding<Double> {
        Binding(
            get: { cyclingCadence },
            set: { newCadence in
                let clampedRPM = min(max(newCadence, 40), 130)
                let metersPerSecond = max(cyclingSpeedKPH / 3.6, 0.28)
                let development = metersPerSecond / (clampedRPM / 60)
                cyclingDevelopment = min(max(development, 1), 12)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("移动方式") {
                    Picker("方式", selection: Binding(
                        get: { profile },
                        set: { profile = $0 }
                    )) {
                        ForEach(MovementProfile.allCases) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if profile == .walking {
                    Section("步行参数") {
                        Picker("自然档位", selection: walkingPaceBinding) {
                            ForEach(WalkingPace.allCases) { pace in
                                Text(pace.title).tag(pace)
                            }
                        }
                        .pickerStyle(.segmented)
                        LabeledContent("速度") {
                            Text("\(walkingSpeedKPH, specifier: "%.1f") km/h")
                        }
                        Slider(value: $walkingSpeedKPH, in: 1...10, step: 0.5)
                            .onChange(of: walkingSpeedKPH) { _, speed in
                                walkingPaceRaw = WalkingPace.matching(
                                    speedKilometersPerHour: speed
                                ).rawValue
                            }
                        Toggle("轻微自然变速", isOn: $naturalSpeedVariation)
                        LabeledContent("步幅") {
                            Text("\(strideMeters, specifier: "%.2f") m")
                        }
                        Slider(value: $strideMeters, in: 0.4...1.5, step: 0.01)
                        LabeledContent("步频") {
                            Text("\(walkingCadence, specifier: "%.0f") 步/分")
                        }
                        Text("推荐使用 5.0 km/h 的自然档。开启自然变速后，速度会每 8–16 秒平滑变化，幅度不超过 ±6%，避免机械恒速。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("骑行参数") {
                        LabeledContent("速度") {
                            Text("\(cyclingSpeedKPH, specifier: "%.1f") km/h")
                        }
                        Slider(value: $cyclingSpeedKPH, in: 1...20, step: 0.5)
                        LabeledContent("踏频") {
                            Text("\(cyclingCadence, specifier: "%.0f") 转/分")
                        }
                        Slider(value: cyclingCadenceBinding, in: 40...130, step: 1)
                        Text("踏频跟速度线性相关：拖动速度时踏频同步升降（齿比不变），拖动踏频相当于换挡。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("语言") {
                    Picker(selection: $localization.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    } label: {
                        Label("界面语言", systemImage: "globe")
                    }
                    Text("默认跟随系统语言。切换后立即生效，系统弹窗等界面在下次启动后跟上。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("外观") {
                    Picker("主题", selection: $appearanceRaw) {
                        ForEach(AppearancePreference.allCases) { item in
                            Label(item.title, systemImage: item.symbol).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("深色模式适配 iOS 夜览。选「跟随系统」则随系统自动切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("内置本地隧道") {
                    LabeledContent("VPN 状态", value: vpn.status.title)
                    Toggle("启动 App 时自动连接", isOn: $autoConnectVPN)
                    if vpn.status.isConnected {
                        Button("断开内置 VPN", role: .destructive) {
                            vpn.disconnect()
                            Task { await preflight.refresh() }
                        }
                    } else {
                        Button("连接内置 VPN") {
                            Task {
                                await vpn.connect()
                                try? await Task.sleep(for: .seconds(1))
                                await preflight.refresh()
                            }
                        }
                    }
                    Text("首次连接时，iOS 会请求添加 VPN 配置。隧道仅在本机映射 10.7.0.1，不连接外部 VPN 服务器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("后台运行") {
                    Toggle("使用低精度定位保活", isOn: $keepAliveLocation)
                        .onChange(of: keepAliveLocation) { _, _ in
                            BackgroundLocationManager.shared.refreshPreferences()
                        }
                    Toggle("使用静音音频兜底", isOn: $keepAliveAudio)
                        .onChange(of: keepAliveAudio) { _, _ in
                            BackgroundAudioManager.shared.refreshPreferences()
                        }
                    Text("定位保活能耗较低，建议开启。静音音频仅在系统容易暂停后台任务时作为兜底；关闭后锁屏期间可能更容易中断。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: pairingStatusSymbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(pairingStatusColor)
                            .frame(width: 36, height: 36)
                            .background(pairingStatusColor.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设备信任")
                                .font(.subheadline.weight(.semibold))
                            Text(pairingStatusTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if onDevicePairing.isSupported {
                        Button {
                            showOnDevicePairing = true
                        } label: {
                            Label("iOS 27 本机配对（1–7 步）", systemImage: "iphone.and.arrow.forward")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PikminUI.green)
                        .listRowBackground(Color.clear)
                    }

                    Button {
                        showPairingImporter = true
                    } label: {
                        Label(onDevicePairing.isSupported ? "导入电脑生成的文件（备用）" : "导入 pairing file", systemImage: "square.and.arrow.down")
                    }
                    if let importMessage {
                        Text(importMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        preflight.connectDevice()
                    } label: {
                        Label("连接设备并检查定位通道", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                } header: {
                    Text("设备连接")
                } footer: {
                    Text("本机配对需要 iOS 27 或更高版本；旧系统仍可用电脑生成文件。DDI 为可选能力，不再阻塞定位模拟。")
                }

                Section("健康") {
                    Button("请求 HealthKit 权限") {
                        Task { _ = await health.requestAuthorization() }
                    }
                    LabeledContent("本 App 今日写入", value: String(format: "%d 步".localized, health.todayAppSteps))
                    Button("删除本 App 写入的步数", role: .destructive) {
                        Task { _ = await health.deleteAppWrittenSteps() }
                    }
                }

                Section("环境诊断") {
                    PermissionChecklistView(service: permissions)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    PreflightChecklistView(service: preflight)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("设置向导") {
                    Button {
                        SetupGate.restart()
                        setupCompleted = false
                        forceShowSetup = true
                    } label: {
                        Label("重新运行首次设置", systemImage: "arrow.clockwise.circle")
                    }
                    Text("重新打开欢迎、权限、配对、内置 VPN 和环境检查流程；不会删除现有 pairing file 或历史记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("问题反馈") {
                    Button {
                        generateDiagnostics()
                    } label: {
                        HStack {
                            Label("生成诊断日志", systemImage: "stethoscope")
                            if isGeneratingDiagnostics {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isGeneratingDiagnostics)
                    Text("遇到「VPN 未连接 / 等待 VPN」等问题时，点这里生成核心状态快照，再分享给开发者排查。日志不含 pairing file 内容或定位数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("隐私") {
                    Button {
                        showPrivacyDetails = true
                    } label: {
                        Label("隐私与网络说明", systemImage: "hand.raised.fill")
                    }
                    Text("无分析、广告或遥测。地图搜索/路线使用 Apple MapKit；可选 DDI 仅在你确认后下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("StikDebug 仅供内部学习使用。模拟定位可能违反游戏服务条款。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("内置隧道基于 LocalDevVPN / StosVPN（SideStore Team）", destination: URL(string: "https://github.com/StephenDev0/LocalDevVPN")!)
                        .font(.footnote)
                    Link("iOS 27 本机配对参考 Locus（MIT）", destination: URL(string: "https://github.com/ChrisMack32/Locus")!)
                        .font(.footnote)
                    Link("设备通信基于 idevice（MIT）", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
                        .font(.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PikminUI.pageBackground.ignoresSafeArea())
            .navigationTitle("设置")
            .tint(PikminUI.green)
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try PairingFileStore.importFromPicker(url)
                importMessage = "导入成功".localized
                Task { await preflight.refresh() }
            } catch {
                importMessage = String(format: "导入失败：%@".localized, error.localizedDescription)
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsReportView(text: diagnosticsText ?? "")
        }
        .sheet(isPresented: $showOnDevicePairing) {
            OnDevicePairingView()
        }
        .sheet(isPresented: $showPrivacyDetails) {
            PrivacyNetworkView()
        }
    }

    private var pairingItem: PreflightItem? {
        preflight.items.first { $0.kind == .pairing }
    }

    private var pairingStatusTitle: String {
        if onDevicePairing.isBusy { return "正在等待本机配对".localized }
        if onDevicePairing.phase == .succeeded { return "本机配对已完成".localized }
        if case .failed(let message) = onDevicePairing.phase { return message }
        return pairingItem?.status.message ?? "尚未检查".localized
    }

    private var pairingStatusSymbol: String {
        if onDevicePairing.isBusy { return "dot.radiowaves.left.and.right" }
        if case .failed = onDevicePairing.phase { return "exclamationmark.triangle.fill" }
        if onDevicePairing.phase == .succeeded || pairingItem?.status.isReady == true {
            return "checkmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private var pairingStatusColor: Color {
        if onDevicePairing.isBusy { return .orange }
        if case .failed = onDevicePairing.phase { return .red }
        if onDevicePairing.phase == .succeeded || pairingItem?.status.isReady == true {
            return PikminUI.green
        }
        return .secondary
    }

    private func generateDiagnostics() {
        isGeneratingDiagnostics = true
        Task {
            let report = await DiagnosticsReport.generate()
            diagnosticsText = report
            isGeneratingDiagnostics = false
            showDiagnostics = true
        }
    }
}

/// 诊断日志预览页：可先看内容，再复制或通过系统分享发给开发者。
private struct DiagnosticsReportView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = text
                        didCopy = true
                    } label: {
                        Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    ShareLink(item: text) {
                        Label("分享给开发者", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PikminUI.green)
                }
                .padding()
                .background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
