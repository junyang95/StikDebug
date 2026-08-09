import Foundation
import ObjectiveC.runtime
import SwiftUI

extension String {
    /// 本地化查找。源语言是简体中文，因此键本身就是界面上的中文原文；
    /// 查不到时回退成键，界面仍显示中文而不是空白。
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
}

// MARK: - 支持的语言

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    /// 除「跟随系统」外，每个选项都用它所代表的语言书写，
    /// 这样无论当前界面是哪种语言都认得出来。
    var displayName: String {
        switch self {
        case .system: return "跟随系统".localized
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    /// nil 表示交给 iOS 按设备的偏好语言决定。
    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

// MARK: - 运行时切换

/// 把 Bundle.main 的查表重定向到指定 .lproj，让切换语言立即生效，
/// 而不是要等下次启动。
private final class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let overrideBundle = LocalizationBundle.overrideBundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return overrideBundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

enum LocalizationBundle {
    fileprivate static var overrideBundle: Bundle?
    private static var isSwizzled = false

    /// 传 nil 表示跟随设备语言。
    static func setLanguage(_ identifier: String?) {
        installOverrideIfNeeded()

        guard let identifier else {
            overrideBundle = nil
            return
        }
        overrideBundle = languageBundle(for: identifier)
    }

    private static func installOverrideIfNeeded() {
        guard !isSwizzled else { return }
        object_setClass(Bundle.main, LocalizedBundle.self)
        isSwizzled = true
    }

    /// 逐级回退，让 "zh-Hant-TW" 仍能落到 "zh-Hant" 或 "zh"。
    private static func languageBundle(for identifier: String) -> Bundle? {
        var candidate = identifier
        while !candidate.isEmpty {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
            guard let separator = candidate.lastIndex(of: "-") else { break }
            candidate = String(candidate[candidate.startIndex..<separator])
        }
        return nil
    }
}

// MARK: - 管理器

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: UserDefaults.Keys.appLanguage)
            apply()
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: UserDefaults.Keys.appLanguage)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        apply()
    }

    /// 交给 SwiftUI，让日期、数字、复数规则也跟着选定语言走。
    var locale: Locale {
        guard let identifier = language.localeIdentifier else {
            return Locale.autoupdatingCurrent
        }
        return Locale(identifier: identifier)
    }

    private func apply() {
        LocalizationBundle.setLanguage(language.localeIdentifier)

        // Bundle 覆盖管本次启动；AppleLanguages 让系统自己的界面
        // （权限弹窗、分享面板、键盘）在下次启动时跟上。
        if let identifier = language.localeIdentifier {
            UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}
