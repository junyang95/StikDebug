import Foundation

enum AppBootstrapper {
    @MainActor
    static func configure() {
        // 先装好语言覆盖，保证任何界面读取文案之前语言就已生效。
        _ = LocalizationManager.shared

        var defaults: [String: Any] = [
            "autoConnectEmbeddedVPN": true,
            "keepAliveAudio": true,
            "keepAliveLocation": true,
            AppearancePreference.storageKey: AppearancePreference.system.rawValue,
            UserDefaults.Keys.targetDeviceIP: DeviceConnectionContext.defaultTargetIPAddress
        ]
        defaults.merge(MovementDefaultsKey.defaults) { current, _ in current }
        UserDefaults.standard.register(defaults: defaults)
    }
}
