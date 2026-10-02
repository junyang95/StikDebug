enum PairingGuidePolicy {
    static func shouldPresent(isSupported: Bool, hasValidPairing: Bool, presentedThisLaunch: Bool) -> Bool {
        isSupported && !hasValidPairing && !presentedThisLaunch
    }
}
