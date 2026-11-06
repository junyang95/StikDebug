import Combine
import CryptoKit
import Darwin
import Foundation
import Security

struct LauncherBoundAuthorization: Codable, Equatable {
    let policy: DeviceAuthorizationPolicy
    let udid: String
    let binding: String
    let envelope: Data
}

@MainActor struct LauncherAuthorizationDependencies {
    var request: @Sendable (String, String) async throws -> Data
    var load: () -> LauncherBoundAuthorization?
    var save: (LauncherBoundAuthorization) throws -> Void
    var remove: () throws -> Void
    var loadSecurity: () throws -> DeviceAuthorizationSecurityState?
    var saveSecurity: (DeviceAuthorizationSecurityState) throws -> Void
    var verify: (Data, String, String?, Date) throws -> SignedDeviceLicense
    var now: () -> Date = Date.init
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var bootID: () -> String = { LauncherAccessBoot.identifier }
    var candidate: () -> String? = { DeviceAuthorizationIdentity.candidate() }

    static var live: Self {
        Self(request: { try await WowDeviceAccessClient().requestLicense(udid: $0, nonce: $1) },
             load: LauncherAccessKeychain.load, save: LauncherAccessKeychain.save,
             remove: LauncherAccessKeychain.remove, loadSecurity: LauncherAccessKeychain.loadSecurity,
             saveSecurity: LauncherAccessKeychain.saveSecurity,
             verify: { try WowDeviceAccess.verifiedLicense($0, udid: $1, nonce: $2, now: $3) })
    }
}

/// Candidate prechecks enable setup only. Every tool operation must supply the
/// UDID read from the paired device and the current pairing/mode binding.
@MainActor final class LauncherDeviceAuthorization: ObservableObject {
    static let shared = LauncherDeviceAuthorization(dependencies: .live)
    enum Result: Equatable { case setupVerified, authorized(offline: Bool), requiresDeviceIdentity }
    @Published private(set) var offlineValidUntil: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var messageKey: String?
    private let dependencies: LauncherAuthorizationDependencies
    private let policy = DeviceAuthorizationPolicy.registeredUnbanned
    private var expectedCandidate: String?
    private var pending: (udid: String, envelope: Data, license: SignedDeviceLicense, offline: Bool)?
    private var requestID = UUID()
    private var requestTask: Task<Data, Error>?
    private var previousSecurity: DeviceAuthorizationSecurityState?
    private var writeFailed = false
    private var grant: Grant?

    private struct Grant {
        let binding: String
        let digest: String
        let license: SignedDeviceLicense
        let trusted: TimeInterval
        let wall: TimeInterval
        let uptime: TimeInterval
        let deadline: TimeInterval
    }

    init(dependencies: LauncherAuthorizationDependencies) { self.dependencies = dependencies }
    static func candidateIdentity() -> String? { DeviceAuthorizationIdentity.candidate() }

    func precheck(candidate: String?) async throws -> Result {
        guard !Task.isCancelled else { throw WowDeviceAccessError.cancelled }
        cancel()
        guard let candidate else { return .requiresDeviceIdentity }
        try WowDeviceAccess.validateDeviceIdentifier(candidate)
        expectedCandidate = candidate.lowercased()
        let id = requestID
        isChecking = true
        defer { if requestID == id { isChecking = false; requestTask = nil } }
        do {
            let (data, license) = try await freshLicense(udid: candidate, id: id)
            try ensureCurrent(id)
            try commitFresh(data, license: license)
            pending = (candidate.lowercased(), data, license, false)
            offlineValidUntil = nil
            return .setupVerified
        } catch {
            guard requestID == id else { throw WowDeviceAccessError.cancelled }
            let failure = map(error)
            if isAuthoritative(failure) { reject(); throw failure }
            restorePreviousSecurity()
            if failure == .cancelled { pending = nil; grant = nil; throw failure }
            if let cached = validCache(udid: candidate, binding: nil) {
                pending = (cached.0.udid, cached.0.envelope, cached.1, true)
                offlineValidUntil = cached.1.validUntil(for: policy)
                return .setupVerified
            }
            messageKey = failure.localizationKey
            throw failure
        }
    }

    /// Call only as an explicit setup continuation; this may checkpoint trusted
    /// local time, but never requests the network or grants access to a tool.
    func canContinueSetup(candidate: String?, binding: String? = nil) -> Bool {
        guard !isChecking, let candidate else { return false }
        expectedCandidate = candidate.lowercased()
        if let pending, pending.udid.caseInsensitiveCompare(candidate) == .orderedSame,
           let now = try? trustedNow(pending.envelope), pending.license.permitsUse(policy: policy, at: now) {
            return true
        }
        guard let cached = validCache(udid: candidate, binding: binding) else { return false }
        pending = (cached.0.udid, cached.0.envelope, cached.1, true)
        offlineValidUntil = cached.1.validUntil(for: policy)
        return true
    }

    func authorize(actualUDID: String, binding: String) async throws -> Result {
        guard !Task.isCancelled else { throw WowDeviceAccessError.cancelled }
        try WowDeviceAccess.validateDeviceIdentifier(actualUDID)
        guard !binding.isEmpty else { throw WowDeviceAccessError.deviceUnavailable }
        guard !isChecking else { throw WowDeviceAccessError.cancelled }
        let candidate = expectedCandidate ?? dependencies.candidate()
        if let candidate, candidate.caseInsensitiveCompare(actualUDID) != .orderedSame {
            invalidatePending()
            throw WowDeviceAccessError.identityMismatch
        }
        if let pending {
            guard pending.udid.caseInsensitiveCompare(actualUDID) == .orderedSame else {
                invalidatePending(); throw WowDeviceAccessError.identityMismatch
            }
            if let now = try? trustedNow(pending.envelope), pending.license.permitsUse(policy: policy, at: now) {
                let record = LauncherBoundAuthorization(policy: policy, udid: actualUDID.lowercased(), binding: binding, envelope: pending.envelope)
                do {
                    try ensureCurrent(requestID)
                    try saveBound(record)
                    self.pending = nil
                    try allow(record, license: pending.license, offline: pending.offline)
                    return .authorized(offline: pending.offline)
                } catch { grant = nil; throw map(error) }
            }
            self.pending = nil
        }
        let id = UUID(); requestID = id
        isChecking = true
        defer { if requestID == id { isChecking = false; requestTask = nil } }
        do {
            let (data, license) = try await freshLicense(udid: actualUDID, id: id)
            try ensureCurrent(id)
            let record = LauncherBoundAuthorization(policy: policy, udid: actualUDID.lowercased(), binding: binding, envelope: data)
            try saveBound(record)
            try commitFresh(data, license: license)
            try allow(record, license: license, offline: false)
            return .authorized(offline: false)
        } catch {
            guard requestID == id else { throw WowDeviceAccessError.cancelled }
            let failure = map(error)
            if isAuthoritative(failure) { reject(); throw failure }
            restorePreviousSecurity()
            if failure != .cancelled, let cached = validCache(udid: actualUDID, binding: binding) {
                try allow(cached.0, license: cached.1, offline: true)
                return .authorized(offline: true)
            }
            grant = nil; offlineValidUntil = nil
            messageKey = failure.localizationKey
            throw failure
        }
    }

    /// Rendering and cached icon reads use this cheap in-memory check. A new
    /// protected operation still calls authorize with a freshly read real UDID.
    func isAuthorized(binding: String) -> Bool {
        guard let grant, grant.binding == binding else { return false }
        let uptime = dependencies.uptime()
        let floor = grant.trusted + max(0, uptime - grant.uptime)
        let projected = grant.trusted + dependencies.now().timeIntervalSince1970 - grant.wall
        return projected + 120 >= floor && uptime < grant.deadline
            && grant.license.permitsUse(policy: policy, at: Date(timeIntervalSince1970: max(floor, projected)))
    }

    func cancel() {
        requestID = UUID()
        requestTask?.cancel(); requestTask = nil
        restorePreviousSecurity()
        pending = nil; grant = nil; expectedCandidate = nil
        offlineValidUntil = nil; isChecking = false
    }
    func invalidatePending() { cancel() }

    private func freshLicense(udid: String, id: UUID) async throws -> (Data, SignedDeviceLicense) {
        try prepareBarrier()
        let nonce = UUID().uuidString
        let request = dependencies.request
        let task = Task { try await request(udid, nonce) }; requestTask = task
        do {
            let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try ensureCurrent(id)
            let license = try dependencies.verify(data, udid, nonce, dependencies.now())
            // No persistence/clock/decoder failure after an authentic decision may
            // restore the old permit. This includes authenticated unsupported schema.
            previousSecurity = nil
            guard license.permitsUse(policy: policy, at: Date(timeIntervalSince1970: license.ts / 1000)) else {
                throw WowDeviceAccessError.invalidResponse
            }
            return (data, license)
        } catch {
            if requestID == id, isAuthoritative(map(error)) { previousSecurity = nil }
            throw error
        }
    }

    private func ensureCurrent(_ id: UUID) throws {
        guard id == requestID, !Task.isCancelled else { throw WowDeviceAccessError.cancelled }
    }

    private func validCache(udid: String, binding: String?) -> (LauncherBoundAuthorization, SignedDeviceLicense)? {
        guard let record = dependencies.load(), record.policy == policy,
              record.udid.caseInsensitiveCompare(udid) == .orderedSame,
              binding == nil || record.binding == binding,
              let license = try? dependencies.verify(record.envelope, udid, nil, dependencies.now()),
              let now = try? trustedNow(record.envelope), license.permitsUse(policy: policy, at: now) else { return nil }
        return (record, license)
    }

    private func allow(_ record: LauncherBoundAuthorization, license: SignedDeviceLicense, offline: Bool) throws {
        let now = try trustedNow(record.envelope)
        guard license.permitsUse(policy: policy, at: now) else { throw WowDeviceAccessError.invalidResponse }
        let uptime = dependencies.uptime()
        let digest = DeviceAuthorizationSecurityState.digest(record.envelope)
        var deadline = uptime + max(0, license.validUntil(for: policy).timeIntervalSince(now))
        if let grant, grant.digest == digest { deadline = min(deadline, grant.deadline) }
        grant = Grant(binding: record.binding, digest: digest, license: license, trusted: now.timeIntervalSince1970,
                      wall: dependencies.now().timeIntervalSince1970, uptime: uptime, deadline: deadline)
        offlineValidUntil = offline ? license.validUntil(for: policy) : nil
        messageKey = nil
    }

    private func writeSecurity(_ state: DeviceAuthorizationSecurityState) throws {
        do {
            try dependencies.saveSecurity(state)
            guard try dependencies.loadSecurity() == state else { throw DeviceAuthorizationPersistenceFailure.unavailable }
            writeFailed = false
        } catch { writeFailed = true; throw WowDeviceAccessError.persistenceUnavailable }
    }
    private func trustedNow(_ envelope: Data) throws -> Date {
        guard !writeFailed else { throw WowDeviceAccessError.persistenceUnavailable }
        guard var state = try dependencies.loadSecurity(), !state.requiresOnline,
              state.allowedEnvelopeDigest == DeviceAuthorizationSecurityState.digest(envelope) else {
            throw DeviceAuthorizationPersistenceFailure.onlineRequired
        }
        do {
            let now = try state.observe(wallTime: dependencies.now(), uptime: dependencies.uptime(), bootID: dependencies.bootID())
            try writeSecurity(state)
            return now
        } catch DeviceAuthorizationPersistenceFailure.clockRollback {
            state.requiresOnline = true
            try writeSecurity(state)
            throw WowDeviceAccessError.clockRollback
        }
    }
    private func prepareBarrier() throws {
        previousSecurity = nil
        let stored: DeviceAuthorizationSecurityState?
        do { stored = try dependencies.loadSecurity() }
        catch DeviceAuthorizationPersistenceFailure.invalidState { stored = nil }
        var state = stored ?? .anchored(serverTime: max(1, dependencies.now().timeIntervalSince1970),
            wallTime: dependencies.now(), uptime: dependencies.uptime(), bootID: dependencies.bootID(), envelope: nil)
        if !state.requiresOnline,
           (try? state.observe(wallTime: dependencies.now(), uptime: dependencies.uptime(), bootID: dependencies.bootID())) != nil {
            previousSecurity = state
        }
        state.requiresOnline = true
        do { try writeSecurity(state) }
        catch { previousSecurity = nil; throw error }
    }
    private func restorePreviousSecurity() {
        guard let previousSecurity else { return }
        self.previousSecurity = nil
        do { try writeSecurity(previousSecurity) }
        catch { grant = nil }
    }
    private func commitFresh(_ envelope: Data, license: SignedDeviceLicense) throws {
        try writeSecurity(.anchored(serverTime: license.ts / 1000, wallTime: dependencies.now(),
            uptime: dependencies.uptime(), bootID: dependencies.bootID(), envelope: envelope))
    }
    private func saveBound(_ record: LauncherBoundAuthorization) throws {
        do {
            try dependencies.save(record)
            guard dependencies.load() == record else { throw WowDeviceAccessError.persistenceUnavailable }
        } catch { writeFailed = true; throw WowDeviceAccessError.persistenceUnavailable }
    }
    private func reject() {
        // The already-confirmed barrier lives in a different Keychain service.
        try? dependencies.remove()
        grant = nil; pending = nil; offlineValidUntil = nil
    }
    private func isAuthoritative(_ error: WowDeviceAccessError) -> Bool {
        error == .banned || error == .notRegistered || error == .serverUnsupported
    }
    private func map(_ error: Error) -> WowDeviceAccessError {
        if let error = error as? WowDeviceAccessError { return error }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if error is DeviceAuthorizationPersistenceFailure { return .persistenceUnavailable }
        return .networkUnavailable
    }
}

private enum LauncherAccessBoot {
    static let identifier: String = {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1, count < 256 else { return UUID().uuidString }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { return UUID().uuidString }
        return String(cString: bytes)
    }()
}

private enum LauncherAccessKeychain {
    private static let service = "com.wow.jit-launcher.registered-device.v1"
    private static func query(security: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + (security ? ".security" : ""),
         kSecAttrAccount as String: "registered-unbanned-v1"]
    }
    private static func read(security: Bool) throws -> Data? {
        var q = query(security: security)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DeviceAuthorizationPersistenceFailure.unavailable }
        return data
    }
    private static func write(_ data: Data, security: Bool) throws {
        let q = query(security: security)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess, try read(security: security) == data else { throw DeviceAuthorizationPersistenceFailure.unavailable }
    }
    static func load() -> LauncherBoundAuthorization? {
        guard let data = try? read(security: false) else { return nil }
        return try? JSONDecoder().decode(LauncherBoundAuthorization.self, from: data)
    }
    static func save(_ record: LauncherBoundAuthorization) throws { try write(JSONEncoder().encode(record), security: false) }
    static func remove() throws {
        let status = SecItemDelete(query(security: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound,
              try read(security: false) == nil else { throw DeviceAuthorizationPersistenceFailure.unavailable }
    }
    static func loadSecurity() throws -> DeviceAuthorizationSecurityState? {
        guard let data = try read(security: true) else { return nil }
        do { return try JSONDecoder().decode(DeviceAuthorizationSecurityState.self, from: data) }
        catch { throw DeviceAuthorizationPersistenceFailure.invalidState }
    }
    static func saveSecurity(_ state: DeviceAuthorizationSecurityState) throws { try write(JSONEncoder().encode(state), security: true) }
}
