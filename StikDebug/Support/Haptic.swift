import UIKit

/// 地图连点这类高频操作需要即时反馈，否则用户不确定这一下点上没有。
enum Haptic {
    @MainActor
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
