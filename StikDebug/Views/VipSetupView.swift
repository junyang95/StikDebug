import SwiftUI
import UIKit

private struct DeviceSetupEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct BeginDeviceSetupKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// A valid license alone must not start connection or permission work on launch.
    var deviceSetupEnabled: Bool {
        get { self[DeviceSetupEnabledKey.self] }
        set { self[DeviceSetupEnabledKey.self] = newValue }
    }

    var beginDeviceSetup: () -> Void {
        get { self[BeginDeviceSetupKey.self] }
        set { self[BeginDeviceSetupKey.self] = newValue }
    }
}

struct DeviceSetupPrompt: View {
    @Environment(\.beginDeviceSetup) private var beginDeviceSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("准备使用时，点开始设置验证 VIP 并连接设备。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("开始设置", action: beginDeviceSetup)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("begin-device-setup")
        }
    }
}

/// Presented by an explicit setup action, never automatically when the app opens.
struct VipSetupView: View {
    @ObservedObject var authorization: VipAuthorizationService
    var restoreLocation: (() async -> String?)? = nil
    var verify: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @State private var isRestoringLocation = false
    @State private var recoveryMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    setupSteps
                    verificationCard
                    if let restoreLocation {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                isRestoringLocation = true
                                Task {
                                    recoveryMessage = await restoreLocation() ?? "已恢复真实定位".localized
                                    isRestoringLocation = false
                                }
                            } label: {
                                HStack {
                                    if isRestoringLocation { ProgressView() }
                                    Text("恢复真实定位")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(minHeight: 44)
                            }
                            .disabled(isRestoringLocation)
                            if let recoveryMessage {
                                Text(recoveryMessage).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(PikminUI.pageBackground.ignoresSafeArea())
            .navigationTitle("开始设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: close)
                            .accessibilityIdentifier("close-vip-setup")
                    }
                }
            }
        }
        .tint(PikminUI.green)
        .preferredColorScheme(AppearancePreference(rawValue: appearanceRaw)?.colorScheme)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(PikminUI.green)
                .accessibilityHidden(true)
            Text("先验证 VIP")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("验证通过后，再设置设备连接与系统权限。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupStep(number: 1, title: "VIP 验证", current: true)
            setupStep(number: 2, title: "设备连接", current: false)
            setupStep(number: 3, title: "系统权限", current: false)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func setupStep(number: Int, title: LocalizedStringKey, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number.formatted())
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(current ? PikminUI.deepGreen : .secondary)
                .frame(minWidth: 30, minHeight: 30)
                .background(current ? PikminUI.softGreen : PikminUI.hairline, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if authorization.isChecking {
                    ProgressView()
                        .padding(.top, 3)
                        .accessibilityLabel("正在验证授权…")
                } else {
                    Image(systemName: authorization.needsSetupIdentity ? "exclamationmark.triangle" : "shield.lefthalf.filled")
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
                Text(authorization.needsSetupIdentity
                    ? "当前安装包缺少设备标识，请获取为本设备签名的安装包后重试".localized
                    : authorization.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: verify ?? authorization.verifyManually) {
                Text(authorization.isChecking ? "取消验证".localized : "验证 VIP".localized)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(PikminUI.actionGreen)

            if authorization.needsNetworkSettings {
                Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                    Text("打开网络设置")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PikminUI.green)
                .fixedSize(horizontal: false, vertical: true)
            }
            Link(destination: URL(string: "https://app-shop.cn/vip")!) {
                Text("购买或续费")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PikminUI.green)
            .fixedSize(horizontal: false, vertical: true)

            Text("完成设备连接后，会自动核对当前设备与 VIP 授权是否匹配。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }
}
