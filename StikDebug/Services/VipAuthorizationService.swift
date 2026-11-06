import Combine
import CryptoKit
import Darwin
import Foundation
import Security

struct VipDeviceBinding: Codable, Equatable, Sendable {
    let targetIP: String
    let pairingPath: String
    let pairingSignature: String

    // App updates may relocate the sandbox. The pairing contents identify the binding.
    func matches(_ other: Self?) -> Bool {
        guard let other else { return false }
        return targetIP == other.targetIP && pairingSignature == other.pairingSignature
    }
}

struct CachedVipAuthorization: Codable, Equatable {
    let binding: VipDeviceBinding
    let udid: String
    let envelope: Data
}

/// A server-signed setup result is not proof of the connected device's identity.
/// Keep it out of the persistent, physically verified device cache.
private struct PendingVipSetupAuthorization {
    let udid: String
    let envelope: Data
}

typealias VipAuthorizationSecurityState = DeviceAuthorizationSecurityState
typealias VipPersistenceFailure = DeviceAuthorizationPersistenceFailure

private enum VipBootSession {
    static let identifier: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else {
            return UUID().uuidString
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return UUID().uuidString }
        return String(cString: bytes)
    }()
}

@MainActor
struct VipAuthorizationDependencies {
    var binding: () -> VipDeviceBinding?
    var canReadDevice: () -> Bool
    var readDevice: @Sendable (VipDeviceBinding) async throws -> String
    var request: @Sendable (String, String, @escaping @Sendable () -> Void) async throws -> Data
    var load: () -> CachedVipAuthorization?
    var loadLegacy: (String) -> Data?
    var save: (CachedVipAuthorization) throws -> Void
    var remove: () throws -> Void
    var loadSecurityState: () throws -> VipAuthorizationSecurityState?
    var saveSecurityState: (VipAuthorizationSecurityState) throws -> Void
    var verify: (Data, String, String?, Date) throws -> VipLicense
    var now: () -> Date = Date.init
    var revoked: () -> Void
    var deviceTimeout: TimeInterval = 8
    var requestTimeout: TimeInterval = 60
    var setupIdentity: () -> String? = { nil }
    var monitoringInterval: TimeInterval = 60
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var bootID: () -> String = { VipBootSession.identifier }

    static var live: Self {
        Self(
            binding: {
                let url = PairingFileStore.prepareURL()
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return VipDeviceBinding(targetIP: DeviceConnectionContext.targetIPAddress,
                    pairingPath: url.path, pairingSignature: digest)
            },
            canReadDevice: { EmbeddedVPNService.shared.status.isConnected && !DeveloperConnectionGate.isBlocked },
            readDevice: { binding in
                try await AuthorizationDeviceReader.shared.read {
                    try readAuthorizationDeviceUDID(deviceIP: binding.targetIP, pairingFile: binding.pairingPath)
                }
            },
            request: { try await AuthorizationHTTPClient.request(udid: $0, nonce: $1, waiting: $2) },
            load: VipLicenseCache.load,
            loadLegacy: VipLicenseCache.loadLegacy,
            save: VipLicenseCache.save,
            remove: VipLicenseCache.remove,
            loadSecurityState: VipLicenseCache.loadSecurityState,
            saveSecurityState: VipLicenseCache.saveSecurityState,
            verify: { try VipLicenseVerifier.verify($0, udid: $1, nonce: $2, now: $3, trustFreshServerTime: $2 != nil) },
            revoked: {
                Task {
                    await WalkingSessionController.shared.stop(
                        reason: "授权验证失败，请检查连接并重新验证".localized, holdLocation: false)
                    FixedLocationSessionController.shared.stop()
                }
            },
            setupIdentity: { VipSetupIdentity.candidate() }
        )
    }
}

@MainActor
final class VipAuthorizationService: ObservableObject {
    static let shared = VipAuthorizationService(dependencies: .live, observePairing: true)
    @Published private(set) var message = "首先验证 VIP 授权，验证通过后继续设置".localized
    @Published private(set) var isChecking = false
    @Published private(set) var isAuthorized = false
    /// Per-launch user intent. Restoring a cached license never starts setup or networking.
    @Published private(set) var hasStartedSetup = false
    @Published private(set) var isSetupVerified = false
    @Published private(set) var needsSetupIdentity = false
    @Published private(set) var offlineValidUntil: Date?
    @Published private(set) var needsNetworkSettings = false
    @Published private(set) var lastDiagnostic = "idle"
    private let dependencies: VipAuthorizationDependencies
    private let gate: VipLocationGate
    private var memoryCache: CachedVipAuthorization?
    private var pendingSetup: PendingVipSetupAuthorization?
    private var lastCheckAt = Date.distantPast
    private var lastCheckUptime: TimeInterval = -.infinity
    private var monitor: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var pairingObserver: NSObjectProtocol?
    private var connectivityObserver: AuthorizationConnectivityObserver?
    private var retryWhenAvailable = false
    private var recoveryPending = false
    private var previousRequestSecurityState: VipAuthorizationSecurityState?
    private var persistenceFailure: VipPersistenceFailure?
    private var securityWriteFailed = false

    init(dependencies: VipAuthorizationDependencies, gate: VipLocationGate = .shared, observePairing: Bool = false) {
        self.dependencies = dependencies
        self.gate = gate
        if observePairing {
            connectivityObserver = AuthorizationConnectivityObserver { [weak self] in
                Task { @MainActor in self?.connectionDidBecomeAvailable() }
            }
            pairingObserver = NotificationCenter.default.addObserver(
                forName: PairingFileStore.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pairingDidChange()
                }
            }
        }
    }

    func startMonitoring() {
        guard hasStartedSetup, monitor == nil else { return }
        restoreCachedAuthorization()
        let interval = dependencies.monitoringInterval
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard self?.hasStartedSetup == true else { return }
                await self?.refresh()
            }
        }
    }

    /// Only an explicit user action starts device reads, server requests and monitoring.
    func startSetup() {
        guard !isChecking else { return }
        hasStartedSetup = true
        startMonitoring()
        beginVerification()
    }

    /// Used by both verification buttons; updates UI before any asynchronous work.
    func verifyManually() {
        guard !isChecking else { cancelVerification(); return }
        startSetup()
    }

    func cancelVerification() {
        cancelCurrentRequest()
        let restored = restoreCachedAuthorization()
        // Cancelling the first step withdraws consent to automatic retries. An existing
        // physically bound grant remains usable; ongoing use keeps its normal monitoring.
        if restored == nil || !hasStartedSetup {
            hasStartedSetup = false
            monitor?.cancel()
            monitor = nil
        }
        if restored == nil {
            message = "已取消验证，可重新尝试".localized
        }
    }

    private func cancelCurrentRequest() {
        retryWhenAvailable = false
        recoveryPending = false
        needsNetworkSettings = false
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        isChecking = false
        restoreRequestSecurityState()
    }

    /// Pairing invalidates device binding, but cannot substitute for the user's setup action.
    func pairingDidChange() {
        cancelCurrentRequest()
        restoreCachedAuthorization()
        guard hasStartedSetup else { return }
        beginVerification()
    }

    /// Permission, network, VPN and foreground changes bypass the normal polling throttle.
    /// An event during a request is retained so a just-failed request cannot lose recovery.
    func connectionDidBecomeAvailable() {
        guard hasStartedSetup else { return }
        if isChecking {
            recoveryPending = true
        } else if retryWhenAvailable {
            beginVerification()
        }
    }

    func refresh(force: Bool = false) async {
        guard hasStartedSetup else { return }
        if isChecking {
            await requestTask?.value
            return
        }
        guard force || max(dependencies.now().timeIntervalSince(lastCheckAt),
                           dependencies.uptime() - lastCheckUptime) >= 30 else { return }
        beginVerification()
        await requestTask?.value
    }

    private func beginVerification() {
        guard hasStartedSetup else { return }
        let id = UUID()
        requestID = id
        isChecking = true
        needsNetworkSettings = false
        needsSetupIdentity = false
        recoveryPending = false
        lastCheckAt = dependencies.now()
        lastCheckUptime = dependencies.uptime()
        let cached = restoreCachedAuthorization()
        message = "正在验证授权…".localized
        requestTask = Task { await performVerification(id: id, cached: cached) }
    }

    private func performVerification(id: UUID, cached: CachedVipAuthorization?) async {
        guard hasStartedSetup, requestID == id, !Task.isCancelled else { return }
        var stage = "device"
        defer {
            if requestID == id {
                isChecking = false
                requestTask = nil
                let shouldRetry = recoveryPending && retryWhenAvailable
                recoveryPending = false
                if shouldRetry { beginVerification() }
            }
        }
        do {
            let currentBinding = dependencies.binding()
            let identity = currentBinding.flatMap { binding in
                cached?.binding.matches(binding) == true ? cached : verifiedDeviceIdentity(binding: binding)
            }
            if identity == nil, let candidate = dependencies.setupIdentity() {
                // Signing metadata is only an automatic lookup hint. It never opens the
                // location gate or becomes a trusted identity until the device agrees.
                if let pending = pendingSetup, pending.udid.caseInsensitiveCompare(candidate) == .orderedSame,
                   let license = validSetupLicense(), let binding = currentBinding, dependencies.canReadDevice() {
                    message = "正在核对已连接设备…".localized
                    let read = dependencies.readDevice
                    let actualUDID = try await withAuthorizationDeadline(seconds: dependencies.deviceTimeout) {
                        try await read(binding)
                    }
                    try ensureCurrent(id, binding: binding)
                    guard dependencies.setupIdentity()?.caseInsensitiveCompare(candidate) == .orderedSame else {
                        throw CancellationError()
                    }
                    guard actualUDID.caseInsensitiveCompare(pending.udid) == .orderedSame else {
                        retryWhenAvailable = false
                        lastDiagnostic = "device: setup identity mismatch"
                        deny("安装包授权与已连接设备不一致，请获取为本设备签名的安装包".localized)
                        return
                    }
                    // Recheck expiry after the physical read; setup never extends the
                    // server's original seven-day deadline.
                    guard license.permitsUse(at: try trustedNow(for: pending.envelope)) else {
                        throw VipLicenseVerifier.Failure.timestamp
                    }
                    let record = CachedVipAuthorization(binding: binding, udid: actualUDID, envelope: pending.envelope)
                    try persistBound(record, license: license, fresh: false)
                    pendingSetup = nil
                    lastDiagnostic = "verified: device bound"
                    allow(license, offline: true)
                    retryWhenAvailable = false
                    return
                }
                stage = "network"
                let (data, license) = try await requestLicense(udid: candidate, id: id)
                guard dependencies.setupIdentity()?.caseInsensitiveCompare(candidate) == .orderedSame else {
                    throw CancellationError()
                }
                if license.permitsUse(at: Date(timeIntervalSince1970: license.ts / 1000)) {
                    try commitFreshSecurityState(envelope: data, license: license)
                    pendingSetup = PendingVipSetupAuthorization(udid: candidate, envelope: data)
                    isSetupVerified = true
                    retryWhenAvailable = true // VPN becoming available must bind the real device immediately.
                    needsNetworkSettings = false
                    lastDiagnostic = "verified: setup pending device"
                    message = "VIP 已验证，请继续配置设备连接".localized
                } else {
                    reject(license)
                }
                return
            }
            guard let binding = currentBinding else {
                retryWhenAvailable = false
                needsSetupIdentity = true
                lastDiagnostic = "device: setup identity unavailable"
                deny("当前安装包缺少设备标识，请获取为本设备签名的安装包后重试".localized)
                return
            }
            let udid: String
            if let identity {
                // This signed license was bound to this exact pairing when its device was read.
                // The simulation command layer independently checks the actual device UDID.
                udid = identity.udid
            } else {
                guard dependencies.canReadDevice() else {
                    retryWhenAvailable = true
                    needsSetupIdentity = true
                    lastDiagnostic = "device: VPN unavailable"
                    deny("当前安装包缺少设备标识，请获取为本设备签名的安装包后重试".localized)
                    return
                }
                message = "正在读取设备信息…".localized
                let read = dependencies.readDevice
                udid = try await withAuthorizationDeadline(seconds: dependencies.deviceTimeout) {
                    try await read(binding)
                }
            }
            try ensureCurrent(id, binding: binding)
            // Older caches lack a trusted clock and durable revocation barrier.
            // They may not create an offline grant until a fresh online verification.
            stage = "network"
            let (data, license) = try await requestLicense(udid: udid, id: id)
            try ensureCurrent(id, binding: binding)
            stage = "signature"
            lastDiagnostic = "verified: \(license.status)"
            if license.permitsUse(at: Date(timeIntervalSince1970: license.ts / 1000)) {
                let record = CachedVipAuthorization(binding: binding, udid: udid, envelope: data)
                try persistBound(record, license: license, fresh: true)
                allow(license, offline: false)
            } else {
                reject(license)
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            restoreRequestSecurityState()
            // Codes only: do not include UDIDs, request headers or server response bodies.
            if let url = error as? URLError {
                lastDiagnostic = "\(stage): URL \(url.code.rawValue)"
            } else if let http = error as? AuthorizationHTTPError {
                lastDiagnostic = "\(stage): HTTP \(http.status)"
            } else {
                lastDiagnostic = "\(stage): \(error is AuthorizationOperationError ? "timeout/busy" : "invalid response")"
            }
            retryWhenAvailable = true
            let networkUnavailable = (error as? URLError).map {
                [.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost,
                 .internationalRoamingOff, .callIsActive].contains($0.code)
            } ?? false
            needsNetworkSettings = needsNetworkSettings || networkUnavailable
            // Timeout, DNS, HTTP errors, malformed maintenance pages or failed verification
            // cannot create a grant or erase a previously verified seven-day entitlement.
            if restoreCachedAuthorization() == nil, !isSetupVerified {
                let message = persistenceMessage ?? (needsNetworkSettings
                    ? "暂时无法联网验证。请允许 App 使用网络；恢复联网后会自动重试，也可前往设置检查权限".localized
                    : error is AuthorizationOperationError
                        ? "验证超时，请检查网络后重试".localized
                        : "暂时无法验证授权，本机没有有效的离线授权，请联网重试".localized)
                deny(message)
            }
        }
    }

    private func requestLicense(udid: String, id: UUID) async throws -> (Data, VipLicense) {
        try prepareRequestSecurityState()
        message = "正在连接授权服务器…".localized
        let nonce = UUID().uuidString
        let request = dependencies.request
        let waiting: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.requestID == id, self.isChecking else { return }
                self.retryWhenAvailable = true
                self.needsNetworkSettings = true
                self.message = "等待联网；如出现系统弹窗，请允许网络访问，允许后会自动验证".localized
            }
        }
        let data = try await withAuthorizationDeadline(seconds: dependencies.requestTimeout) {
            try await request(udid, nonce, waiting)
        }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        let license = try dependencies.verify(data, udid, nonce, dependencies.now())
        // Once any authentic decision arrives, never roll back to the old grant.
        previousRequestSecurityState = nil
        return (data, license)
    }

    private func validSetupLicense() -> VipLicense? {
        guard let pending = pendingSetup,
              dependencies.setupIdentity()?.caseInsensitiveCompare(pending.udid) == .orderedSame,
              let license = try? dependencies.verify(pending.envelope, pending.udid, nil, dependencies.now()),
              let now = try? trustedNow(for: pending.envelope), license.permitsUse(at: now) else { return nil }
        return license
    }

    private func reject(_ license: VipLicense) {
        // Only an authenticated denial revokes the saved entitlement.
        retryWhenAvailable = false
        needsNetworkSettings = false
        // The request barrier was confirmed BEFORE contacting the server. Deletion
        // is cleanup only; failure cannot re-enable the old envelope after restart.
        do { try dependencies.remove() }
        catch { lastDiagnostic += "; cache cleanup failed (offline blocked)" }
        memoryCache = nil
        deny(license.isBanned || license.status == "BANNED"
            ? "此设备已被封禁，请联系商家".localized
            : license.status == "EXPIRED" || (license.expireAt > 0 && license.expireAt <= license.ts)
                ? "VIP 已过期，请续费后重新验证".localized
                : "此设备尚未获得 VIP 授权".localized)
    }

    private var persistenceMessage: String? {
        switch persistenceFailure {
        case .clockRollback: "检测到设备时间回拨，请联网重新验证授权".localized
        case .unavailable, .invalidState: "无法安全保存授权状态，请解锁设备后联网重试".localized
        case .onlineRequired: "授权缓存需要联网重新验证".localized
        case nil: nil
        }
    }

    private func writeSecurityState(_ state: VipAuthorizationSecurityState) throws {
        do {
            try dependencies.saveSecurityState(state)
            guard try dependencies.loadSecurityState() == state else { throw VipPersistenceFailure.unavailable }
            securityWriteFailed = false
        } catch {
            securityWriteFailed = true
            persistenceFailure = .unavailable
            throw VipPersistenceFailure.unavailable
        }
    }

    private func trustedNow(for envelope: Data) throws -> Date {
        do {
            guard !securityWriteFailed else { throw VipPersistenceFailure.unavailable }
            guard var state = try dependencies.loadSecurityState(), !state.requiresOnline,
                  state.allowedEnvelopeDigest == VipAuthorizationSecurityState.digest(envelope) else {
                throw VipPersistenceFailure.onlineRequired
            }
            let now: Date
            do {
                now = try state.observe(wallTime: dependencies.now(), uptime: dependencies.uptime(), bootID: dependencies.bootID())
            } catch {
                state.requiresOnline = true
                try writeSecurityState(state)
                throw error
            }
            try writeSecurityState(state)
            persistenceFailure = nil
            return now
        } catch {
            persistenceFailure = (error as? VipPersistenceFailure) ?? .unavailable
            throw error
        }
    }

    private func prepareRequestSecurityState() throws {
        previousRequestSecurityState = nil
        do {
            let stored: VipAuthorizationSecurityState?
            do { stored = try dependencies.loadSecurityState() }
            catch VipPersistenceFailure.invalidState { stored = nil }
            var state = stored ?? .anchored(
                serverTime: max(1, dependencies.now().timeIntervalSince1970), wallTime: dependencies.now(),
                uptime: dependencies.uptime(), bootID: dependencies.bootID(), envelope: nil)
            if !state.requiresOnline {
                if (try? state.observe(wallTime: dependencies.now(), uptime: dependencies.uptime(), bootID: dependencies.bootID())) != nil {
                    previousRequestSecurityState = state
                }
            }
            state.requiresOnline = true
            try writeSecurityState(state)
        } catch {
            previousRequestSecurityState = nil
            persistenceFailure = .unavailable
            throw VipPersistenceFailure.unavailable
        }
    }

    /// Transport errors/cancellation may keep a previously trusted grant. A signed
    /// decision clears this snapshot before any subsequent persistence operation.
    private func restoreRequestSecurityState() {
        guard let state = previousRequestSecurityState else { return }
        previousRequestSecurityState = nil
        do { try writeSecurityState(state) }
        catch { gate.update(nil); isAuthorized = false; isSetupVerified = false }
    }

    private func commitFreshSecurityState(envelope: Data, license: VipLicense) throws {
        let state = VipAuthorizationSecurityState.anchored(
            serverTime: license.ts / 1000, wallTime: dependencies.now(), uptime: dependencies.uptime(),
            bootID: dependencies.bootID(), envelope: envelope)
        try writeSecurityState(state)
        persistenceFailure = nil
    }

    private func persistBound(_ record: CachedVipAuthorization, license: VipLicense, fresh: Bool) throws {
        do {
            try dependencies.save(record)
            guard dependencies.load() == record else { throw VipPersistenceFailure.unavailable }
            if fresh { try commitFreshSecurityState(envelope: record.envelope, license: license) }
            else { _ = try trustedNow(for: record.envelope) }
            memoryCache = record
        } catch {
            persistenceFailure = .unavailable
            throw VipPersistenceFailure.unavailable
        }
    }

    private func ensureCurrent(_ id: UUID, binding: VipDeviceBinding) throws {
        try Task.checkCancellation()
        guard requestID == id, binding.matches(dependencies.binding()) else { throw CancellationError() }
    }

    /// An expired signed grant can identify this pairing for an online renewal; it cannot
    /// authorize location commands or extend the offline window. Never trust an unsigned UDID.
    private func verifiedDeviceIdentity(binding: VipDeviceBinding) -> CachedVipAuthorization? {
        guard let record = memoryCache ?? dependencies.load(), record.binding.matches(binding),
              let license = try? dependencies.verify(record.envelope, record.udid, nil, dependencies.now()),
              license.status == "VALID", license.isVip, !license.isBanned else { return nil }
        return record
    }

    /// Synchronous, local-only restoration: runs before network/preflight on every launch.
    @discardableResult
    func restoreCachedAuthorization() -> CachedVipAuthorization? {
        guard let cached = memoryCache ?? dependencies.load(), cached.binding.matches(dependencies.binding()),
              let license = try? dependencies.verify(cached.envelope, cached.udid, nil, dependencies.now()),
              let now = try? trustedNow(for: cached.envelope), license.permitsUse(at: now) else {
            gate.update(nil)
            isAuthorized = false
            isSetupVerified = validSetupLicense() != nil
            if !isSetupVerified { pendingSetup = nil }
            offlineValidUntil = nil
            if isSetupVerified { message = "VIP 已验证，请继续配置设备连接".localized }
            else if let persistenceMessage { message = persistenceMessage }
            return nil
        }
        allow(license, offline: true)
        return cached
    }

    private func allow(_ license: VipLicense, offline: Bool) {
        guard let envelope = memoryCache?.envelope ?? dependencies.load()?.envelope,
              let now = try? trustedNow(for: envelope), license.permitsUse(at: now) else {
            deny(persistenceMessage ?? "请联网重新验证授权".localized)
            return
        }
        if !offline {
            retryWhenAvailable = false
            needsNetworkSettings = false
        }
        gate.update(license, now: now, wallNow: dependencies.now(), uptime: dependencies.uptime())
        isAuthorized = true
        isSetupVerified = true
        needsSetupIdentity = false
        offlineValidUntil = offline ? license.validUntil : nil
        message = offline ? "服务器暂不可用时可继续使用本地授权，最多保留 7 天".localized : "VIP 授权有效".localized
    }

    private func deny(_ message: String) {
        gate.update(nil)
        isAuthorized = false
        isSetupVerified = false
        pendingSetup = nil
        offlineValidUntil = nil
        self.message = message
        // Do not leave the verification button waiting for a HealthKit/session shutdown.
        dependencies.revoked()
    }
}

private enum VipLicenseCache {
    static let service = "com.pikminhelper.native-vip"
    static let recordAccount = "verified-device-v2"
    static let securityAccount = "trusted-state-v1"
    static func query(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }
    static func read(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func load() -> CachedVipAuthorization? {
        guard let data = read(account: recordAccount) else { return nil }
        return try? JSONDecoder().decode(CachedVipAuthorization.self, from: data)
    }
    static func loadLegacy(udid: String) -> Data? { read(account: udid.lowercased()) }
    private static func securityQuery() -> [String: Any] {
        var q = query(account: securityAccount)
        // Bulk deletion of old grants must never delete the request/revocation barrier.
        q[kSecAttrService as String] = service + ".security"
        return q
    }
    private static func checkedRead(_ query: [String: Any]) throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VipPersistenceFailure.unavailable }
        return data
    }
    private static func checkedWrite(_ data: Data, query q: [String: Any]) throws {
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess, try checkedRead(q) == data else { throw VipPersistenceFailure.unavailable }
    }
    static func loadSecurityState() throws -> VipAuthorizationSecurityState? {
        guard let data = try checkedRead(securityQuery()) else { return nil }
        do { return try JSONDecoder().decode(VipAuthorizationSecurityState.self, from: data) }
        catch { throw VipPersistenceFailure.invalidState }
    }
    static func saveSecurityState(_ state: VipAuthorizationSecurityState) throws {
        try checkedWrite(JSONEncoder().encode(state), query: securityQuery())
    }
    static func save(_ record: CachedVipAuthorization) throws {
        try checkedWrite(JSONEncoder().encode(record), query: query(account: recordAccount))
        // Legacy entries no longer authorize offline use; retained leftovers are harmless.
    }
    static func remove() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound,
              try checkedRead(query()) == nil else { throw VipPersistenceFailure.unavailable }
    }
}
