import Foundation
import SwiftUI

/// 移动方式：步行或骑行。两者共用同一套坐标推进引擎，
/// 差别只在速度范围，以及「每一步 / 每一踏前进多少米」。
enum MovementProfile: String, CaseIterable, Identifiable, Codable {
    case walking
    case cycling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: "步行".localized
        case .cycling: "骑行".localized
        }
    }

    var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        }
    }

    /// 开始按钮文案，随方式变化。
    var startActionTitle: String {
        switch self {
        case .walking: "开始步行".localized
        case .cycling: "开始骑行".localized
        }
    }

    /// 进行中的状态词。
    var movingStatus: String {
        switch self {
        case .walking: "步行中".localized
        case .cycling: "骑行中".localized
        }
    }

    var minSpeedKPH: Double { 1 }

    var maxSpeedKPH: Double {
        switch self {
        case .walking: 10
        case .cycling: 20
        }
    }

    var defaultSpeedKPH: Double {
        switch self {
        case .walking: 8
        case .cycling: 16
        }
    }

    func clampSpeed(_ value: Double) -> Double {
        min(max(value, minSpeedKPH), maxSpeedKPH)
    }
}

enum WalkingPace: String, CaseIterable, Identifiable {
    case stroll
    case natural
    case brisk
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stroll: "散步".localized
        case .natural: "自然".localized
        case .brisk: "快走".localized
        case .custom: "自定".localized
        }
    }

    var speedKilometersPerHour: Double? {
        switch self {
        case .stroll: 3.5
        case .natural: 5.0
        case .brisk: 6.5
        case .custom: nil
        }
    }

    static func matching(speedKilometersPerHour speed: Double) -> WalkingPace {
        allCases.first {
            guard let presetSpeed = $0.speedKilometersPerHour else { return false }
            return abs(presetSpeed - speed) < 0.01
        } ?? .custom
    }
}

/// 移动方式在 UserDefaults 里的键，集中管理避免各处硬编码字符串。
enum MovementDefaultsKey {
    static let profile = "movementProfile"
    static let walkingSpeed = "walkingSpeedKPH"
    static let walkingStride = "walkingStrideMeters"
    static let walkingPace = "walkingPace"
    static let naturalSpeedVariation = "walkingNaturalSpeedVariation"
    static let cyclingSpeed = "cyclingSpeedKPH"
    /// 骑行「展开」：固定齿比下每踏板转前进的距离（米/转）。
    /// 存这个而不是踏频，是因为踏频要跟速度线性相关——
    /// 展开固定时，踏频 = 速度 ÷ 展开，天然随速度线性变化。
    static let cyclingDevelopment = "cyclingDevelopmentMeters"

    static let defaults: [String: Any] = [
        profile: MovementProfile.walking.rawValue,
        walkingSpeed: 5.0,
        walkingStride: 0.75,
        walkingPace: WalkingPace.natural.rawValue,
        naturalSpeedVariation: true,
        cyclingSpeed: 16.0,
        cyclingDevelopment: 5.0
    ]
}

/// 从设置里解析出的「本次要用的移动参数」，供开始会话时统一读取，
/// 避免每个视图各写一遍限速和步幅换算。
struct MovementParameters {
    let profile: MovementProfile
    /// 已按方式夹到合理范围的速度。
    let speedKPH: Double
    /// 每一步 / 每一踏前进的米数（步行=步幅，骑行=展开）。
    let strideMeters: Double
    let usesNaturalSpeedVariation: Bool

    var speedMetersPerSecond: Double { speedKPH / 3.6 }

    /// 当前速度下的踏频 / 步频（每分钟次数）。展开固定时随速度线性变化。
    var cadencePerMinute: Double {
        guard strideMeters > 0 else { return 0 }
        return speedMetersPerSecond / strideMeters * 60
    }

    static func current(_ defaults: UserDefaults = .standard) -> MovementParameters {
        let profile = MovementProfile(
            rawValue: defaults.string(forKey: MovementDefaultsKey.profile) ?? ""
        ) ?? .walking

        switch profile {
        case .walking:
            let speed = nonZero(defaults.double(forKey: MovementDefaultsKey.walkingSpeed), fallback: 8)
            let stride = nonZero(defaults.double(forKey: MovementDefaultsKey.walkingStride), fallback: 0.75)
            return MovementParameters(
                profile: .walking,
                speedKPH: profile.clampSpeed(speed),
                strideMeters: min(max(stride, 0.2), 3),
                usesNaturalSpeedVariation: defaults.object(forKey: MovementDefaultsKey.naturalSpeedVariation) as? Bool ?? true
            )
        case .cycling:
            let speed = nonZero(defaults.double(forKey: MovementDefaultsKey.cyclingSpeed), fallback: 16)
            let development = nonZero(defaults.double(forKey: MovementDefaultsKey.cyclingDevelopment), fallback: 5)
            return MovementParameters(
                profile: .cycling,
                speedKPH: profile.clampSpeed(speed),
                strideMeters: min(max(development, 1), 12),
                usesNaturalSpeedVariation: false
            )
        }
    }

    private static func nonZero(_ value: Double, fallback: Double) -> Double {
        value == 0 ? fallback : value
    }
}

/// 外观偏好：跟随系统 / 强制浅色 / 强制深色。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static let storageKey = "appearancePreference"

    var title: String {
        switch self {
        case .system: "跟随系统".localized
        case .light: "浅色".localized
        case .dark: "深色".localized
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
