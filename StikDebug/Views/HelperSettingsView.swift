import SwiftUI

struct HelperSettingsView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var permissions: PermissionChecklistService
    @EnvironmentObject private var health: HealthStepService
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @AppStorage(MovementDefaultsKey.profile) private var profileRaw = MovementProfile.walking.rawValue
    @AppStorage(MovementDefaultsKey.walkingSpeed) private var walkingSpeedKPH = 8.0
    @AppStorage(MovementDefaultsKey.walkingStride) private var strideMeters = 0.75
    @AppStorage(MovementDefaultsKey.cyclingSpeed) private var cyclingSpeedKPH = 16.0
    @AppStorage(MovementDefaultsKey.cyclingDevelopment) private var cyclingDevelopment = 5.0
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("autoConnectEmbeddedVPN") private var autoConnectVPN = true
    @State private var showPairingImporter = false
    @State private var importMessage: String?
    @State private var isGeneratingDiagnostics = false
    @State private var diagnosticsText: String?
    @State private var showDiagnostics = false

    private var profile: MovementProfile {
        get { MovementProfile(rawValue: profileRaw) ?? .walking }
        nonmutating set { profileRaw = newValue.rawValue }
    }

    /// 当前速度下的步频（每分钟步数）。步幅固定时随速度线性变化。
    private var walkingCadence: Double {
        (walkingSpeedKPH / 3.6) / max(strideMeters, 0.1) * 60
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
                        LabeledContent("速度") {
                            Text("\(walkingSpeedKPH, specifier: "%.1f") km/h")
                        }
                        Slider(value: $walkingSpeedKPH, in: 1...10, step: 0.5)
                        LabeledContent("步幅") {
                            Text("\(strideMeters, specifier: "%.2f") m")
                        }
                        Slider(value: $strideMeters, in: 0.4...1.5, step: 0.01)
                        LabeledContent("步频") {
                            Text("\(walkingCadence, specifier: "%.0f") 步/分")
                        }
                        Text("步频由速度和步幅换算：速度越快步频越高。")
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

                Section("设备连接") {
                    Button("导入 pairing file") { showPairingImporter = true }
                    if let importMessage {
                        Text(importMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("连接并挂载 DDI") { preflight.connectAndMount() }
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

                Section {
                    Text("Pikmin Helper 仅供内部学习使用。模拟定位可能违反游戏服务条款。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("内置隧道基于 LocalDevVPN / StosVPN（SideStore Team）", destination: URL(string: "https://github.com/StephenDev0/LocalDevVPN")!)
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
