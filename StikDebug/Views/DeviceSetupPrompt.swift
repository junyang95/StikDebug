import SwiftUI

private struct DeviceSetupEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct BeginDeviceSetupKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Device and permission work starts only after an explicit setup action.
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
            Text("准备使用时，点开始设置完成设备连接与系统权限。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("开始设置", action: beginDeviceSetup)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("begin-device-setup")
        }
    }
}
