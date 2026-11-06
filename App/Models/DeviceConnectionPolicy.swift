import Foundation

enum DeviceConnectionMode: String, CaseIterable, Sendable {
    case builtIn, external

    init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? .builtIn
    }
}

/// External VPN ownership cannot be inferred from this app's tunnel profile.
/// Admission permits a real device check; readiness records its last success.
enum DeviceConnectionPolicy {
    static func canAttempt(mode: DeviceConnectionMode, builtInConnected: Bool) -> Bool {
        mode == .external || builtInConnected
    }

    static func isReady(mode: DeviceConnectionMode, builtInConnected: Bool,
                        external: ExternalConnectionValidation) -> Bool {
        mode == .external ? external.phase == .verified : builtInConnected
    }
}

/// A ticket binds one actual paired-device check to the current connection.
/// Network, foreground, pairing, and mode changes discard it, so a late native
/// response cannot restore trust in a path that has already been invalidated.
struct ExternalConnectionValidation {
    enum Phase: Equatable { case unverified, checking, verified }
    private(set) var phase: Phase = .unverified
    private var ticket: UUID?

    mutating func beginChecking() -> UUID {
        let next = UUID()
        ticket = next
        phase = .checking
        return next
    }

    @discardableResult
    mutating func recordPairedDeviceResponse(for expected: UUID) -> Bool {
        guard ticket == expected, phase == .checking else { return false }
        phase = .verified
        return true
    }

    func isCurrent(_ expected: UUID) -> Bool { ticket == expected }

    mutating func invalidate() {
        ticket = nil
        phase = .unverified
    }
}
