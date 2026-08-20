import SwiftUI
import UIKit

struct OnDevicePairingView: View {
    @EnvironmentObject private var pairing: OnDevicePairingService
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if let pin = pairing.pin {
                        pinCard(pin)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    }
                    stepsCard
                    compatibilityNote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 112)
            }
            .background(PikminUI.pageBackground.ignoresSafeArea())
            .navigationTitle("本机配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: pairing.phase)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle)
                        .font(.title3.weight(.bold))
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Label("无需电脑", systemImage: "iphone")
                Text("·")
                Label("iOS 27+", systemImage: "checkmark.seal")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusGradient, in: RoundedRectangle(cornerRadius: PikminUI.cardCornerRadius, style: .continuous))
        .shadow(color: statusColor.opacity(0.22), radius: 18, x: 0, y: 10)
    }

    private func pinCard(_ pin: String) -> some View {
        VStack(spacing: 8) {
            Label("第 7 步 · 在系统设置中输入", systemImage: "number.square.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(pin)
                .font(.system(size: 42, weight: .bold, design: .monospaced))
                .tracking(8)
                .contentTransition(.numericText())
                .accessibilityLabel("配对码 \(pin)")
            Text("通知中也会保留这组号码")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: PikminUI.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PikminUI.cardCornerRadius, style: .continuous)
                .stroke(PikminUI.green.opacity(0.28), lineWidth: 1)
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("1 步到 7 步")
                    .font(.headline)
                Text("开始后需要短暂切换到系统设置；StikDebug 会在后台等待连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepRow(number: index + 1, title: step.title, detail: step.detail)
            }
        }
        .padding(18)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: PikminUI.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private func stepRow(number: Int, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(number <= currentStep ? PikminUI.green : PikminUI.hairline)
                if number < currentStep || pairing.phase == .succeeded {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(number == currentStep ? .white : .secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(number == currentStep ? .semibold : .regular))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var compatibilityNote: some View {
        Label(
            pairing.isSupported
                ? "如果系统中没有“与主机配对”，仍可返回设置导入电脑生成的 pairing file。"
                : "当前系统不支持本机配对，请返回设置导入电脑生成的 pairing file。",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Button(action: primaryAction) {
                HStack {
                    if isConnecting || pairing.phase == .installing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: primarySymbol)
                    }
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(PikminUI.green)
            .disabled(primaryDisabled)

            if pairing.isBusy {
                Text("可以关闭此页面；配对会继续在后台等待。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private var steps: [(title: String, detail: String?)] {
        [
            ("点“开始本机配对”", "允许通知和本地网络权限，以便在系统设置中看到主机与配对码。"),
            ("保持 Wi‑Fi 开启", "无需连接电脑；本机服务只在当前 iPhone 上运行。"),
            ("打开“设置”", nil),
            ("进入“隐私与安全”", nil),
            ("打开“开发者模式”", nil),
            ("选择“与主机配对” → StikDebug", "按系统提示输入本机解锁密码。"),
            ("输入通知中的 6 位配对码", "完成后回到 StikDebug，连接本地隧道。")
        ]
    }

    private var currentStep: Int {
        switch pairing.phase {
        case .idle, .failed: 1
        case .advertising: 3
        case .deviceConnected: 6
        case .awaitingPIN, .installing: 7
        case .succeeded: 8
        }
    }

    private var statusTitle: String {
        switch pairing.phase {
        case .idle: "准备在本机配对"
        case .advertising: "正在等待系统设置"
        case .deviceConnected: "设备已连接"
        case .awaitingPIN: "配对码已生成"
        case .installing: "正在安全安装配对文件"
        case .succeeded: "本机配对完成"
        case .failed: "本机配对未完成"
        }
    }

    private var statusDetail: String {
        switch pairing.phase {
        case .idle: "iOS 27 可以直接生成设备信任文件，不再需要电脑配对。"
        case .advertising: "前往“隐私与安全 → 开发者模式 → 与主机配对”。"
        case .deviceConnected: "请完成解锁验证，配对码马上出现。"
        case .awaitingPIN: "在系统设置的配对弹窗中输入下方 6 位号码。"
        case .installing: "正在校验并原子替换 pairing file，请稍候。"
        case .succeeded: "配对文件已就绪。下一步连接内置 LocalDevVPN。"
        case .failed(let message): message
        }
    }

    private var statusSymbol: String {
        switch pairing.phase {
        case .idle: "iphone.and.arrow.forward"
        case .advertising: "dot.radiowaves.left.and.right"
        case .deviceConnected: "link"
        case .awaitingPIN: "number.square.fill"
        case .installing: "arrow.down.doc.fill"
        case .succeeded: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch pairing.phase {
        case .failed: .orange
        default: PikminUI.green
        }
    }

    private var statusGradient: LinearGradient {
        switch pairing.phase {
        case .failed:
            LinearGradient(colors: [.orange, .red.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            PikminUI.heroGradient
        }
    }

    private var primaryTitle: String {
        if isConnecting { return "正在连接本地隧道…" }
        switch pairing.phase {
        case .idle: return "开始本机配对"
        case .advertising, .deviceConnected, .awaitingPIN: return "打开“隐私与安全”"
        case .installing: return "正在安装配对文件…"
        case .succeeded: return "连接本地隧道并检查"
        case .failed: return "重新开始"
        }
    }

    private var primarySymbol: String {
        switch pairing.phase {
        case .idle, .failed: "play.fill"
        case .advertising, .deviceConnected, .awaitingPIN: "gear"
        case .installing: "arrow.down.doc.fill"
        case .succeeded: "network.badge.shield.half.filled"
        }
    }

    private var primaryDisabled: Bool {
        isConnecting || pairing.phase == .installing || (!pairing.isSupported && pairing.phase == .idle)
    }

    private func primaryAction() {
        switch pairing.phase {
        case .idle:
            pairing.start()
        case .advertising, .deviceConnected, .awaitingPIN:
            openPrivacySettings()
        case .installing:
            break
        case .succeeded:
            isConnecting = true
            Task {
                await vpn.connect()
                try? await Task.sleep(for: .seconds(1))
                await preflight.refresh()
                isConnecting = false
                dismiss()
            }
        case .failed:
            pairing.reset()
            pairing.start()
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "App-Prefs:root=Privacy") {
            openURL(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
