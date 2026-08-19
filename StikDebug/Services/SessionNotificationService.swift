import UIKit
import UserNotifications

@MainActor
final class SessionNotificationService {
    static let shared = SessionNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let dropIdentifier = "pikmin.session.connection-drop"

    private init() {}

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func notifyConnectionDropped() {
        guard UIApplication.shared.applicationState != .active else { return }
        post(
            title: "Pikmin Helper 连接中断".localized,
            body: "正在后台尝试重新连接设备，位置模拟暂时停止。".localized,
            sound: nil
        )
    }

    func notifyReconnectFailed() {
        guard UIApplication.shared.applicationState != .active else { return }
        post(
            title: "位置模拟已暂停".localized,
            body: "多次重连仍未恢复。请打开 Pikmin Helper 检查 VPN 和设备通道。".localized,
            sound: .default
        )
    }

    func notifyReconnected() {
        guard UIApplication.shared.applicationState != .active else { return }
        post(
            title: "设备连接已恢复".localized,
            body: "位置模拟已从中断处继续。".localized,
            sound: nil
        )
    }

    private func post(title: String, body: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        let request = UNNotificationRequest(
            identifier: dropIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
