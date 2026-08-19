import Foundation

enum SetupGate {
    static let completedKey = "pikminHelper.setup.completed"
    static let forceShowKey = "pikminHelper.setup.forceShow"

    static func shouldPresent(
        completed: Bool,
        forceShow: Bool,
        pairingFileExists: Bool
    ) -> Bool {
        forceShow || (!completed && !pairingFileExists)
    }

    static func markComplete(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
        defaults.set(false, forKey: forceShowKey)
    }

    static func restart(_ defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: completedKey)
        defaults.set(true, forKey: forceShowKey)
    }
}
