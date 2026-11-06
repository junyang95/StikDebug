import Foundation

typealias VipLicense = SignedDeviceLicense
typealias VipLicenseVerifier = DeviceAuthorizationVerifier

extension SignedDeviceLicense {
    var validUntil: Date { validUntil(for: .vip) }
    func permitsUse(at now: Date) -> Bool { permitsUse(policy: .vip, at: now) }
}

/// Enforced by the device command layer, including timer resends. UI is not the gate.
final class VipLocationGate: @unchecked Sendable {
    static let shared = VipLocationGate()
    private let lock = NSLock()
    private var license: VipLicense?
    private var uptimeDeadline: TimeInterval = 0
    private var trustedTime: TimeInterval = 0
    private var observationUptime: TimeInterval = 0
    private var wallOffset: TimeInterval = 0

    func update(_ license: VipLicense?, now: Date = Date(), wallNow: Date? = nil,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        let deadline = uptime + max(0, license?.validUntil.timeIntervalSince(now) ?? 0)
        // Re-reading the same cache cannot refill its remaining monotonic lifetime.
        uptimeDeadline = self.license == license ? min(uptimeDeadline, deadline) : deadline
        self.license = license
        trustedTime = now.timeIntervalSince1970
        observationUptime = uptime
        wallOffset = trustedTime - (wallNow ?? now).timeIntervalSince1970
    }

    func allows(udid: String? = nil, now: Date = Date(),
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let floor = trustedTime + max(0, uptime - observationUptime)
        let projected = now.timeIntervalSince1970 + wallOffset
        guard let license, projected + 120 >= floor,
              license.permitsUse(at: Date(timeIntervalSince1970: max(projected, floor))),
              uptime < uptimeDeadline else { return false }
        return udid.map { license.udid.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }
}
