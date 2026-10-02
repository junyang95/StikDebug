import SwiftUI
import UIKit

struct PreflightChecklistView: View {
    @ObservedObject var service: EnvironmentPreflightService
    @EnvironmentObject private var onDevicePairing: OnDevicePairingService
    var compact = false
    @Environment(\.openURL) private var openURL
    @State private var showOnDevicePairing = false
    @State private var showDDIInstallation = false

    private let idevicePairMacURL = URL(string: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/idevice_pair--macos-universal.dmg")!
    private let idevicePairWindowsURL = URL(string: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/idevice_pair--windows-x86_64.exe")!
    private let windowsITunesURL = URL(string: "https://www.apple.com/itunes/download/win64")!

    private var windowsDownloadChecklist: String {
        """
        \("StikDebug · Windows 下载清单".localized)

        \("请在 Windows 电脑按顺序打开：".localized)
        1. iTunes
        \(windowsITunesURL.absoluteString)

        2. idevice_pair
        \(idevicePairWindowsURL.absoluteString)
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Label("运行环境", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                if service.isRefreshing {
                    ProgressView()
                } else {
                    Button("检查") {
                        Task { await service.refresh() }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                }
            }

            ForEach(service.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if item.kind == .ddi {
                        Button { showDDIInstallation = true } label: {
                            HStack(spacing: 8) {
                                environmentRow(item)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("打开 DDI 安装"))
                    } else {
                        environmentRow(item)
                    }

                    if (!compact || item.kind == .ddi), !item.status.isReady {
                        environmentAction(for: item)
                    }
                }
            }


        }
        .padding(compact ? 12 : 16)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(compact ? 0.04 : 0.06), radius: compact ? 8 : 14, x: 0, y: compact ? 4 : 8)
        .sheet(isPresented: $showOnDevicePairing) {
            OnDevicePairingView()
                .environmentObject(onDevicePairing)
                .environmentObject(service)
                .environmentObject(EmbeddedVPNService.shared)
        }
        .sheet(isPresented: $showDDIInstallation) {
            DDIInstallationView()
        }
    }

    private func environmentRow(_ item: PreflightItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(color(for: item.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.title)
                    .font(.subheadline.weight(.medium))
                if !compact || !item.status.isReady {
                    Text(item.status.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: symbol(for: item.status))
                .foregroundStyle(color(for: item.status))
        }
    }

    private func actionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .background(PikminUI.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.leading, 32)
    }

    private func primaryActionButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(PikminUI.actionGreen)

    }

    private func secondaryActionButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)

    }

    private func waitingCard(_ message: LocalizedStringKey) -> some View {
        actionCard {
            Label(message, systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func preflightItem(for kind: PreflightKind) -> PreflightItem {
        service.items.first(where: { $0.kind == kind }) ?? PreflightItem(kind: kind, status: .unknown)
    }

    private func isReady(_ kind: PreflightKind) -> Bool {
        preflightItem(for: kind).status.isReady
    }

    @ViewBuilder
    private func environmentAction(for item: PreflightItem) -> some View {
        switch item.kind {
        case .wifi:
            actionCard {
                Text("下一步：连接和电脑同一网络的 Wi‑Fi。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryActionButton("打开 Wi‑Fi 设置", systemImage: "wifi") {
                    openWiFiSettings()
                }
            }

        case .vpnRoute:
            if !isReady(.wifi) {
                waitingCard("先连接 Wi‑Fi，再连接内置 VPN")
            } else if EmbeddedVPNService.shared.status.isConnected {
                // 隧道已连接却探测不到 :49152，问题在设备端开发服务，别再让用户「连 VPN」。
                // 实测最有效的修复：把「开发者模式」关掉再重新打开（会重启），让设备端服务重建。
                actionCard {
                    Text(String(format: "内置 VPN 已连接，但访问不到设备开发服务(%@:49152)。最有效的修复是重新开关一次「开发者模式」：".localized, DeviceConnectionContext.defaultTargetIPAddress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 打开 设置 → 隐私与安全 → 开发者模式")
                        Text("2. 关闭开发者模式（会提示重启）")
                        Text("3. 重启后重新打开开发者模式")
                        Text("4. 回到本 App 点下方「重新检查」")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    primaryActionButton("打开开发者模式设置", systemImage: "hammer") {
                        openDeveloperModeSettings()
                    }
                    Button {
                        Task {
                            await EmbeddedVPNService.shared.connect()
                            try? await Task.sleep(for: .seconds(1))
                            await service.refresh()
                        }
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                }
            } else {
                actionCard {
                    Text(String(format: "下一步：连接内置 LocalDevVPN 路由，让 App 访问 %@:49152。".localized, DeviceConnectionContext.defaultTargetIPAddress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    primaryActionButton("连接内置 VPN", systemImage: "network.badge.shield.half.filled") {
                        Task {
                            await EmbeddedVPNService.shared.connect()
                            try? await Task.sleep(for: .seconds(1))
                            await service.refresh()
                        }
                    }
                }
            }

        case .pairing:
            pairingHelp

        case .coreDeviceTunnel:
            if !isReady(.wifi) {
                waitingCard("等待 Wi‑Fi")
            } else if !isReady(.vpnRoute) {
                waitingCard("等待内置 VPN 路由")
            } else if !isReady(.pairing) {
                waitingCard("等待 pairing file")
            } else {
                actionCard {
                    Text("下一步：用 pairing file 和内置 VPN 路由建立 CoreDevice/RSD 定位通道。DDI 不是定位前置条件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    primaryActionButton("建立定位通道", systemImage: "point.3.connected.trianglepath.dotted") {
                        service.connectDevice()
                    }
                }
            }

        case .ddi:
            primaryActionButton("打开 DDI 安装", systemImage: "arrow.down.circle") {
                showDDIInstallation = true
            }
            .padding(.leading, compact ? 0 : 32)
        }
    }

    private var pairingHelp: some View {
        actionCard {
            HStack(spacing: 8) {
                Image(systemName: onDevicePairing.isSupported ? "iphone.and.arrow.forward" : "desktopcomputer")
                    .foregroundStyle(PikminUI.green)
                Text(onDevicePairing.isSupported ? "iOS 27 可直接在本机完成配对，无需连接电脑。" : "当前系统请使用电脑生成 pairing file。")
                    .font(.caption.weight(.medium))
            }

            if onDevicePairing.isSupported {
                primaryActionButton("打开 1–7 步本机配对", systemImage: "iphone.and.arrow.forward") {
                    showOnDevicePairing = true
                }
            }

            Text("电脑方案：用数据线连接 iPhone，把对应下载链接发送到电脑；Windows 会同时收到 iTunes 和 idevice_pair。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("这里不会在 iPhone 下载文件。点击后用 AirDrop、微信、邮件或“复制”把链接交给电脑。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ShareLink(
                item: idevicePairMacURL,
                subject: Text("StikDebug · Mac 配对工具"),
                message: Text("请在 Mac 上打开此链接，下载并运行 idevice_pair。")
            ) {
                Label("发送到 Mac", systemImage: "macbook.and.iphone")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)


            ShareLink(
                item: windowsDownloadChecklist,
                subject: Text("StikDebug · Windows 下载清单")
            ) {
                Label("发送到 Windows", systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)

        }
    }

    private func openWiFiSettings() {
        if let wifiURL = URL(string: "App-Prefs:root=WIFI") {
            openURL(wifiURL)
        } else if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        }
    }

    /// 尽量跳到「隐私与安全」（开发者模式在这里）。iOS 无公开深链直达开发者模式开关，
    /// 失败则退回本 App 设置页，由用户返回上一级自行进入。
    private func openDeveloperModeSettings() {
        if let privacyURL = URL(string: "App-Prefs:root=Privacy") {
            openURL(privacyURL)
        } else if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        }
    }

    private func symbol(for status: PreflightStatus) -> String {
        switch status {
        case .unknown: "questionmark.circle"
        case .checking: "clock"
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(for status: PreflightStatus) -> Color {
        switch status {
        case .unknown, .checking: .secondary
        case .ready: PikminUI.green
        case .warning: .orange
        case .failed: .red
        }
    }
}
