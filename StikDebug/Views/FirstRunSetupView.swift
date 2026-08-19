import SwiftUI
import UniformTypeIdentifiers

struct FirstRunSetupView: View {
    @EnvironmentObject private var permissions: PermissionChecklistService
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @EnvironmentObject private var onDevicePairing: OnDevicePairingService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void

    @State private var step: Step = .welcome
    @State private var showPairingImporter = false
    @State private var showOnDevicePairing = false
    @State private var pairingImportMessage: String?
    @State private var isConnectingVPN = false

    private enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case pairing
        case vpn
        case readiness

        var title: String {
            switch self {
            case .welcome: "欢迎"
            case .permissions: "权限"
            case .pairing: "配对"
            case .vpn: "本地隧道"
            case .readiness: "准备完成"
            }
        }
    }

    private var pairingFileExists: Bool {
        FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    }

    var body: some View {
        ZStack {
            PikminUI.pageBackground.ignoresSafeArea()
            backgroundGlow

            VStack(spacing: 0) {
                progressHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                ScrollView {
                    page
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                        .padding(.bottom, 124)
                }
                .scrollIndicators(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: step)
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importPairing
        )
        .sheet(isPresented: $showOnDevicePairing, onDismiss: refreshEnvironment) {
            OnDevicePairingView()
        }
        .task {
            await vpn.load()
            await permissions.refresh()
            await preflight.refresh()
        }
    }

    private var backgroundGlow: some View {
        GeometryReader { proxy in
            Circle()
                .fill(PikminUI.green.opacity(0.14))
                .frame(width: min(proxy.size.width * 0.9, 420))
                .blur(radius: 70)
                .offset(x: proxy.size.width * 0.48, y: -120)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }

    private var progressHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Pikmin Helper")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? PikminUI.green : PikminUI.hairline)
                        .frame(height: 4)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("设置进度，第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            welcomePage
        case .permissions:
            permissionsPage
        case .pairing:
            pairingPage
        case .vpn:
            vpnPage
        case .readiness:
            readinessPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 28)

            Image(systemName: "figure.walk.motion")
                .font(.system(size: 66, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PikminUI.green)
                .frame(width: 112, height: 112)
                .background(PikminUI.softGreen, in: Circle())

            VStack(spacing: 12) {
                Text("让每一次模拟步行\n都清楚、稳定、可恢复")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("接下来会依次准备系统权限、设备配对和本地隧道，大约需要两分钟。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            setupPromise
            Spacer(minLength: 0)
        }
    }

    private var setupPromise: some View {
        VStack(alignment: .leading, spacing: 14) {
            setupPromiseRow("本机保存", "配对文件、收藏与记录不会上传", "lock.shield.fill")
            setupPromiseRow("版本自适应", onDevicePairing.isSupported ? "iOS 27 使用本机配对" : "当前系统使用电脑生成的 pairing file", "iphone.gen3")
            setupPromiseRow("随时可重来", "可在设置中重新打开本向导", "arrow.clockwise")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func setupPromiseRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(PikminUI.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                "允许必要权限",
                "权限只在相关功能第一次使用时请求。点击未完成的项目即可继续设置。",
                symbol: "person.badge.key.fill"
            )
            PermissionChecklistView(service: permissions)
            setupNote("你可以先继续，未完成的权限会在最后一步再次显示；App 不会在没有说明的情况下连续弹出多个系统授权框。")
        }
    }

    private var pairingPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                onDevicePairing.isSupported ? "在这台 iPhone 上配对" : "导入设备配对文件",
                onDevicePairing.isSupported
                    ? "iOS 27 可以直接生成设备信任文件，不需要连接电脑。"
                    : "iOS 18–26 需要从电脑生成一次 pairing file，之后可一直保存在本机。",
                symbol: onDevicePairing.isSupported ? "iphone.and.arrow.forward" : "desktopcomputer"
            )

            setupStatusCard(
                ready: pairingFileExists,
                title: pairingFileExists ? "设备信任已准备" : "尚未完成设备配对",
                detail: pairingFileExists ? "pairing file 已通过校验并保存在受保护目录。" : "完成下面的版本对应步骤后才能建立定位通道。"
            )

            if onDevicePairing.isSupported {
                Button {
                    showOnDevicePairing = true
                } label: {
                    Label("打开 1–7 步本机配对", systemImage: "iphone.and.arrow.forward")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.green)

                Button {
                    showPairingImporter = true
                } label: {
                    Label("导入电脑生成的文件（备用）", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    numberedStep(1, "在 Mac 或 Windows 上运行 idevice_pair")
                    numberedStep(2, "连接这台 iPhone 并生成 pairing file")
                    numberedStep(3, "通过 AirDrop、文件 App 或共享导入")
                }
                .padding(18)
                .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    showPairingImporter = true
                } label: {
                    Label("导入 pairing file", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.green)
            }

            if let pairingImportMessage {
                Text(pairingImportMessage)
                    .font(.caption)
                    .foregroundStyle(pairingFileExists ? PikminUI.green : .red)
            }
        }
    }

    private var vpnPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                "连接内置本地隧道",
                "隧道只把 App 的设备通信映射到本机，不连接外部 VPN 服务器。",
                symbol: "network.badge.shield.half.filled"
            )

            setupStatusCard(
                ready: vpn.status.isConnected,
                title: vpn.status.isConnected ? "本地隧道已连接" : vpn.status.title,
                detail: vpn.status.isConnected
                    ? "Pikmin Helper 已可以尝试访问设备定位服务。"
                    : "首次连接时，iOS 会请求你允许添加 VPN 配置。"
            )

            if !vpn.status.isConnected {
                Button {
                    connectVPN()
                } label: {
                    HStack {
                        if isConnectingVPN { ProgressView().tint(.white) }
                        Label(isConnectingVPN ? "正在连接…" : "连接内置 VPN", systemImage: "shield.fill")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.green)
                .disabled(isConnectingVPN)
            }

            setupNote("VPN 图标出现只表示本地设备隧道正在工作，不代表你的互联网流量被发送到其他服务器。")
        }
    }

    private var readinessPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                preflight.canStartSession ? "已经可以开始" : "最后检查一次",
                preflight.canStartSession
                    ? "设备配对、本地隧道和定位通道均已准备。"
                    : "下方会明确标出仍需处理的项目；完成向导后也可以在设置中继续。",
                symbol: preflight.canStartSession ? "checkmark.seal.fill" : "checklist"
            )
            PreflightChecklistView(service: preflight)

            Button {
                refreshEnvironment()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func pageTitle(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PikminUI.green)
            Text(title)
                .font(.largeTitle.bold())
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupStatusCard(ready: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : "clock.fill")
                .font(.title2)
                .foregroundStyle(ready ? PikminUI.green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func setupNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func numberedStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(PikminUI.green, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if step != .welcome {
                    Button("返回") { moveBackward() }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 88)
                }

                Button(primaryActionTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(PikminUI.green)
                    .frame(maxWidth: .infinity)
                    .disabled(primaryActionDisabled)
            }
            .controlSize(.large)

            Text(step.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private var primaryActionTitle: String {
        switch step {
        case .welcome: "开始设置"
        case .permissions: "继续配对"
        case .pairing: pairingFileExists ? "继续设置隧道" : "请先完成配对"
        case .vpn: vpn.status.isConnected ? "继续检查" : "请先连接 VPN"
        case .readiness: preflight.canStartSession ? "完成并开始使用" : "完成，稍后继续处理"
        }
    }

    private var primaryActionDisabled: Bool {
        switch step {
        case .pairing: !pairingFileExists
        case .vpn: !vpn.status.isConnected
        default: false
        }
    }

    private func performPrimaryAction() {
        guard step != .readiness else {
            onFinished()
            return
        }
        moveForward()
    }

    private func moveForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { step = next }
        if next == .readiness { refreshEnvironment() }
        Haptic.light()
    }

    private func moveBackward() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { step = previous }
        Haptic.light()
    }

    private func connectVPN() {
        guard !isConnectingVPN else { return }
        isConnectingVPN = true
        Task {
            await vpn.connect()
            try? await Task.sleep(for: .seconds(1))
            await permissions.refresh()
            await preflight.refresh()
            isConnectingVPN = false
        }
    }

    private func refreshEnvironment() {
        Task {
            await permissions.refresh()
            await preflight.refresh()
        }
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try PairingFileStore.importFromPicker(url)
            pairingImportMessage = "导入成功，设备信任已准备。"
            Haptic.success()
            refreshEnvironment()
        } catch {
            pairingImportMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}
