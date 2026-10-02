import SwiftUI

enum PikminUI {
    /// 随浅色/深色自动切换的颜色。深色模式下才能真正适配夜览，而不是把浅色底硬套上去。
    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // 主色在深色下略微提亮，保证在深色卡片上仍清晰。
    static let green = adaptive(light: (0.157, 0.49, 0.275), dark: (0.42, 0.86, 0.54))
    static let actionGreen = Color(red: 0.157, green: 0.49, blue: 0.275)
    static let deepGreen = adaptive(light: (0.04, 0.48, 0.22), dark: (0.42, 0.86, 0.54))
    static let softGreen = adaptive(light: (0.92, 0.98, 0.91), dark: (0.12, 0.22, 0.15))
    static let pageBackground = adaptive(light: (0.965, 0.985, 0.955), dark: (0.055, 0.075, 0.06))
    static let cardBackground = adaptive(light: (0.99, 1.0, 0.99), dark: (0.13, 0.16, 0.14))

    /// 卡片内的浅色分隔/进度轨道，随主题自动明暗。
    static let hairline = Color.primary.opacity(0.08)

    static let cardCornerRadius: CGFloat = 22
    static let tileCornerRadius: CGFloat = 16

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.157, green: 0.49, blue: 0.275),
                Color(red: 0.09, green: 0.36, blue: 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    func pikminCard(cornerRadius: CGFloat = PikminUI.cardCornerRadius) -> some View {
        padding()
            .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).stroke(PikminUI.hairline, lineWidth: 0.5) }
    }
}

extension View {
    /// 覆盖在地图上的操作面板样式。摇杆页和路线/定点页共用同一张不透明卡片，
    /// 保证两个界面观感一致，而不是一个卡片、一个半透明浮层。
    func pikminControlCard() -> some View {
        padding()
            .background(PikminUI.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }
}

