import SwiftUI
import UIKit

struct PermissionChecklistView: View {
    @ObservedObject var service: PermissionChecklistService
    var compact = false
    @Environment(\.openURL) private var openURL
    @State private var permissionAlert: PermissionAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Label("系统权限", systemImage: "person.badge.key.fill")
                    .font(.headline)
                Spacer()
                if service.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("检查") {
                        Task { await service.refresh() }
                    }
                    .font(.subheadline)
                }
            }

            ForEach(service.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        handleTap(item)
                    } label: {
                        permissionRow(item)
                    }
                    .buttonStyle(.plain)

                    if !compact, !item.status.isReady {
                        permissionAction(for: item)
                    }
                }
            }
        }
        .padding(compact ? 12 : 16)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(compact ? 0.04 : 0.06), radius: compact ? 8 : 14, x: 0, y: compact ? 4 : 8)
        .alert(item: $permissionAlert) { alert in
            if alert.opensSettings {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("打开设置"), action: openAppSettings),
                    secondaryButton: .cancel(Text("取消"))
                )
            } else {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }

    private func permissionRow(_ item: PermissionItem) -> some View {
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
        .contentShape(Rectangle())
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
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(PikminUI.green)
        .controlSize(.small)
    }

    @ViewBuilder
    private func permissionAction(for item: PermissionItem) -> some View {
        switch item.kind {
        case .vpn:
            actionCard {
                Text("下一步：允许本 App 添加 VPN 配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryActionButton("请求 VPN 配置权限", systemImage: "shield") {
                    handleTap(item)
                }
            }
        case .healthSteps:
            actionCard {
                Text("下一步：授权读取/写入步数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryActionButton("请求 HealthKit 步数权限", systemImage: "heart") {
                    handleTap(item)
                }
            }
        case .network:
            actionCard {
                Text("下一步：检查 App 是否允许使用无线局域网与蜂窝数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryActionButton("打开 App 无线数据设置", systemImage: "gear") {
                    handleTap(item)
                }
            }
        case .locationAlways:
            actionCard {
                Text("下一步：选择“始终允许”，后台行走保活需要它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryActionButton("请求位置始终允许", systemImage: "location") {
                    handleTap(item)
                }
            }
        }
    }

    private func handleTap(_ item: PermissionItem) {
        switch item.kind {
        case .vpn:
            Task { await service.requestVPNPermission() }
        case .healthSteps:
            if service.canRequestHealthPromptNow {
                Task { await service.requestHealthPermission() }
            } else {
                permissionAlert = .init(
                    title: "需要在设置中开启健康权限".localized,
                    message: "HealthKit 权限被拒绝后，系统通常不会重复弹出授权页。请到系统设置或健康 App 的数据访问权限中为本 App 打开步数读写。".localized,
                    opensSettings: true
                )
            }
        case .locationAlways:
            if service.canRequestLocationPromptNow {
                service.requestLocationAlwaysPermission()
            } else if item.status.isReady {
                permissionAlert = .init(
                    title: "位置权限已开启".localized,
                    message: item.status.message,
                    opensSettings: false
                )
            } else {
                permissionAlert = .init(
                    title: "需要在设置中开启位置权限".localized,
                    message: "iOS 不会在拒绝后重复弹出位置授权框。请到系统设置中把位置权限改为“始终允许”。".localized,
                    opensSettings: true
                )
            }
        case .network:
            permissionAlert = .init(
                title: "无线局域网与蜂窝网络".localized,
                message: "iOS 不提供让 App 主动弹出“无线局域网与蜂窝网络”授权框的 API。请确认本 App 允许使用无线局域网与蜂窝数据；如果系统需要本地网络授权，会在实际网络访问时自动弹出。".localized,
                opensSettings: true
            )
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
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

private struct PermissionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let opensSettings: Bool
}
