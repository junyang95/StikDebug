import Combine
import CryptoKit
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

struct CachedVipAuthorization: Codable {
    let binding: VipDeviceBinding
    let udid: String
    let envelope: Data
}

@MainActor
struct VipAuthorizationDependencies {
    var binding: () -> VipDeviceBinding?
    var canReadDevice: () -> Bool
    var readDevice: @Sendable (VipDeviceBinding) async throws -> String
    var request: @Sendable (String, String, @escaping @Sendable () -> Void) async throws -> Data
    var load: () -> CachedVipAuthorization?
    var loadLegacy: (String) -> Data?
    var save: (CachedVipAuthorization) -> Void
    var remove: () -> Void
    var verify: (Data, String, String?, Date) throws -> VipLicense
    var now: () -> Date = Date.init
    var revoked: () -> Void
    var deviceTimeout: TimeInterval = 8
    var requestTimeout: TimeInterval = 60

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
            verify: { try VipLicenseVerifier.verify($0, udid: $1, nonce: $2, now: $3) },
            revoked: {
                Task {
                    await WalkingSessionController.shared.stop(
                        reason: "授权验证失败，请检查连接并重新验证".localized, holdLocation: false)
                    FixedLocationSessionController.shared.stop()
                }
            }
        )
    }
}

@MainActor
final class VipAuthorizationService: ObservableObject {
    static let shared = VipAuthorizationService(dependencies: .live, observePairing: true)
    @Published private(set) var message = "请完成设备连接后验证 VIP".localized
    @Published private(set) var isChecking = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var offlineValidUntil: Date?
    @Published private(set) var needsNetworkSettings = false
    @Published private(set) var lastDiagnostic = "idle"
    private let dependencies: VipAuthorizationDependencies
    private let gate: VipLocationGate
    private var memoryCache: CachedVipAuthorization?
    private var lastCheckAt = Date.distantPast
    private var monitor: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var pairingObserver: NSObjectProtocol?
    private var connectivityObserver: AuthorizationConnectivityObserver?
    private var retryWhenAvailable = false
    private var recoveryPending = false

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
                    self.cancelVerification()
                    self.gate.update(nil)
                    self.isAuthorized = false
                    await self.refresh(force: true)
                }
            }
        }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        restoreCachedAuthorization()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    /// Used by both verification buttons; updates UI before any asynchronous work.
    func verifyManually() {
        guard !isChecking else { cancelVerification(); return }
        beginVerification()
    }

    func cancelVerification() {
        retryWhenAvailable = false
        recoveryPending = false
        needsNetworkSettings = false
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        isChecking = false
        if restoreCachedAuthorization() == nil {
            message = "已取消验证，可重新尝试".localized
        }
    }

    /// Permission, network, VPN and foreground changes bypass the normal polling throttle.
    /// An event during a request is retained so a just-failed request cannot lose recovery.
    func connectionDidBecomeAvailable() {
        if isChecking {
            recoveryPending = true
        } else if retryWhenAvailable {
            beginVerification()
        }
    }

    func refresh(force: Bool = false) async {
        guard !isChecking, force || dependencies.now().timeIntervalSince(lastCheckAt) >= 30 else { return }
        beginVerification()
        await requestTask?.value
    }

    private func beginVerification() {
        let id = UUID()
        requestID = id
        isChecking = true
        needsNetworkSettings = false
        recoveryPending = false
        lastCheckAt = dependencies.now()
        let cached = restoreCachedAuthorization()
        message = "正在验证授权…".localized
        requestTask = Task { await performVerification(id: id, cached: cached) }
    }

    private func performVerification(id: UUID, cached: CachedVipAuthorization?) async {
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
        guard let binding = dependencies.binding() else {
            retryWhenAvailable = false
            lastDiagnostic = "device: pairing required"
            deny("请先完成设备配对，再验证 VIP".localized)
            return
        }
        do {
            let udid: String
            let identity = cached?.binding.matches(binding) == true ? cached : verifiedDeviceIdentity(binding: binding)
            if let identity {
                // This signed license was bound to this exact pairing when its device was read.
                // The simulation command layer independently checks the actual device UDID.
                udid = identity.udid
            } else {
                guard dependencies.canReadDevice() else {
                    retryWhenAvailable = true
                    lastDiagnostic = "device: VPN unavailable"
                    deny("请先连接内置 VPN，再验证 VIP".localized)
                    return
                }
                message = "正在读取设备信息…".localized
                let read = dependencies.readDevice
                udid = try await withAuthorizationDeadline(seconds: dependencies.deviceTimeout) {
                    try await read(binding)
                }
            }
            try ensureCurrent(id, binding: binding)
            // Migrate 0.1.1's signed per-device cache after a real device read, including offline.
            if cached == nil, let raw = dependencies.loadLegacy(udid),
               let license = try? dependencies.verify(raw, udid, nil, dependencies.now()),
               license.permitsUse(at: dependencies.now()) {
                let record = CachedVipAuthorization(binding: binding, udid: udid, envelope: raw)
                memoryCache = record
                dependencies.save(record)
                allow(license, offline: true)
            }
            message = "正在连接授权服务器…".localized
            stage = "network"
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
            try ensureCurrent(id, binding: binding)
            stage = "signature"
            let license = try dependencies.verify(data, udid, nonce, dependencies.now())
            lastDiagnostic = "verified: \(license.status)"
            if license.permitsUse(at: dependencies.now()) {
                let record = CachedVipAuthorization(binding: binding, udid: udid, envelope: data)
                memoryCache = record
                dependencies.save(record)
                allow(license, offline: false)
            } else {
                // Only an authenticated denial revokes the saved entitlement.
                retryWhenAvailable = false
                needsNetworkSettings = false
                dependencies.remove()
                memoryCache = nil
                deny(license.isBanned || license.status == "BANNED"
                    ? "此设备已被封禁，请联系商家".localized
                    : license.status == "EXPIRED" || (license.expireAt > 0 && license.expireAt <= dependencies.now().timeIntervalSince1970 * 1000)
                        ? "VIP 已过期，请续费后重新验证".localized
                        : "此设备尚未获得 VIP 授权".localized)
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
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
            // cannot create a grant or erase a previously verified three-day entitlement.
            if restoreCachedAuthorization() == nil {
                let message = needsNetworkSettings
                    ? "暂时无法联网验证。请允许 App 使用网络；恢复联网后会自动重试，也可前往设置检查权限".localized
                    : error is AuthorizationOperationError
                        ? "验证超时，请检查 VPN 和网络后重试".localized
                        : "暂时无法验证授权，本机没有有效的离线授权，请联网重试".localized
                deny(message)
            }
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
              license.permitsUse(at: dependencies.now()) else {
            gate.update(nil)
            isAuthorized = false
            offlineValidUntil = nil
            return nil
        }
        allow(license, offline: true)
        return cached
    }

    private func allow(_ license: VipLicense, offline: Bool) {
        if !offline {
            retryWhenAvailable = false
            needsNetworkSettings = false
        }
        gate.update(license, now: dependencies.now())
        isAuthorized = true
        offlineValidUntil = offline ? license.validUntil : nil
        message = offline ? "服务器暂不可用时可继续使用本地授权，最多保留 3 天".localized : "VIP 授权有效".localized
    }

    private func deny(_ message: String) {
        gate.update(nil)
        isAuthorized = false
        offlineValidUntil = nil
        self.message = message
        // Do not leave the verification button waiting for a HealthKit/session shutdown.
        dependencies.revoked()
    }
}

private enum VipLicenseCache {
    static let service = "com.pikminhelper.native-vip"
    static let recordAccount = "verified-device-v2"
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
    static func save(_ record: CachedVipAuthorization) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let q = query(account: recordAccount)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        // Keep the old signed cache until the v2 write has actually succeeded.
        if let persisted = read(account: recordAccount), persisted == data {
            SecItemDelete(query(account: record.udid.lowercased()) as CFDictionary)
        }
    }
    static func remove() { SecItemDelete(query() as CFDictionary) }
}
