import CryptoKit
import Foundation

@MainActor private final class Fixture {
    let udid = "00008110-0011223344556677", binding = "pairing-A|builtIn"
    let key = P256.Signing.PrivateKey()
    var wall = Date(timeIntervalSince1970: 1_800_000_000), server = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 1000
    var boot = "boot-A"
    var candidate: String? = "00008110-0011223344556677"
    var cache: LauncherBoundAuthorization?
    var state: DeviceAuthorizationSecurityState?
    var requests = 0, cacheWrites = 0, stateWrites = 0
    var failCacheWrite = false, ignoreCacheWrite = false, failStateWrite = false, failStateRead = false, failDelete = false
    var response: ((String, String) async throws -> Data)?
    func envelope(udid: String? = nil, nonce: String, status: String = "UNKNOWN", registered: Bool? = true,
                  vip: Bool = false, expiry: Double = 0, banned: Bool = false) throws -> Data {
        var value: [String: Any] = ["udid": udid ?? self.udid, "nonce": nonce, "status": status, "isVip": vip,
            "isBanned": banned, "expireAt": expiry, "ts": server.timeIntervalSince1970 * 1000]
        if let registered { value["isRegistered"] = registered }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(),
            "sig": key.signature(for: data).derRepresentation.base64EncodedString()])
    }
    func advance(_ seconds: TimeInterval) { wall += seconds; server += seconds; uptime += seconds }
    func request(_ udid: String, _ nonce: String) async throws -> Data {
        requests += 1
        try Tests.expect(state?.requiresOnline == true, "Network ran without durable barrier")
        return try await response?(udid, nonce) ?? envelope(udid: udid, nonce: nonce)
    }
    func session() -> LauncherDeviceAuthorization {
        LauncherDeviceAuthorization(dependencies: LauncherAuthorizationDependencies(
            request: { try await self.request($0, $1) }, load: { self.cache },
            save: { self.cacheWrites += 1; if self.failCacheWrite { throw DeviceAuthorizationPersistenceFailure.unavailable }; if !self.ignoreCacheWrite { self.cache = $0 } },
            remove: { if self.failDelete { throw DeviceAuthorizationPersistenceFailure.unavailable }; self.cache = nil },
            loadSecurity: { if self.failStateRead { throw DeviceAuthorizationPersistenceFailure.unavailable }; return self.state },
            saveSecurity: { self.stateWrites += 1; if self.failStateWrite { throw DeviceAuthorizationPersistenceFailure.unavailable }; self.state = $0 },
            verify: { try WowDeviceAccess.verifiedLicense($0, udid: $1, nonce: $2, now: $3, publicKey: self.key.publicKey.x963Representation) },
            now: { self.wall }, uptime: { self.uptime }, bootID: { self.boot }, candidate: { self.candidate }))
    }
    func seed() async throws { _ = try await session().authorize(actualUDID: udid, binding: binding) }
}
@main @MainActor enum Tests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    static func rejects(_ expected: WowDeviceAccessError? = nil, _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch let actual as WowDeviceAccessError {
            if let expected { try expect(actual == expected, "Expected \(expected), got \(actual)") }; return
        }
        throw Failure(description: "Expected refusal")
    }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        throw Failure(description: "Asynchronous transition missing")
    }
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Cold start and no hint are passive; real-device-only path still authorizes", {
                let f = Fixture(); f.candidate = nil; let s = f.session()
                let result = try await s.precheck(candidate: nil)
                try expect(result == .requiresDeviceIdentity && f.requests == 0 && f.cacheWrites == 0 && !s.isAuthorized(binding: f.binding), "Cold start did work")
                _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(f.requests == 1 && s.isAuthorized(binding: f.binding), "Real-device-only path failed")
            }),
            ("Precheck remains RAM-only; fresh matching real-device bind stays online without a second request", {
                let f = Fixture(); let s = f.session(); let precheck = try await s.precheck(candidate: f.udid)
                try expect(precheck == .setupVerified && f.cache == nil && f.cacheWrites == 0, "Candidate wrote bound grant")
                try expect(s.canContinueSetup(candidate: f.udid) && !s.isAuthorized(binding: f.binding), "Candidate opened tool lease")
                let result = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(result == .authorized(offline: false) && f.requests == 1 && f.cacheWrites == 1 && s.offlineValidUntil == nil, "Fresh local bind misreported offline")
            }),
            ("Wrong physical UDID cannot consume pending or write cache", {
                let f = Fixture(); let s = f.session(); _ = try await s.precheck(candidate: f.udid)
                try await rejects(.identityMismatch) { _ = try await s.authorize(actualUDID: "other-device", binding: f.binding) }
                try expect(f.cache == nil && f.cacheWrites == 0 && f.requests == 1, "Mismatch cached")
            }),
            ("Registered non-VIP and expired VIP keep full seven days", {
                for expired in [false, true] {
                    let f = Fixture()
                    f.response = { _, nonce in try f.envelope(nonce: nonce, status: expired ? "EXPIRED" : "UNKNOWN", vip: expired, expiry: expired ? 1 : 0) }
                    let s = f.session(); _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                    f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                    _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                    try expect(s.offlineValidUntil == f.server.addingTimeInterval(7 * 86400), "VIP expiry shortened JIT permission")
                }
            }),
            ("Each later operation rechecks online; outage retains only prior valid binding", {
                let f = Fixture(); let s = f.session(); _ = try await s.precheck(candidate: f.udid)
                _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(f.requests == 2, "New operation skipped request")
                let old = f.cache; f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                let result = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(result == .authorized(offline: true) && f.cache == old, "Outage renewed grant")
            }),
            ("Restored setup still waits for real UDID; different policy or binding cannot be reused", {
                let f = Fixture(); try await f.seed(); let s = f.session()
                try expect(s.canContinueSetup(candidate: f.udid, binding: f.binding) && !s.isAuthorized(binding: f.binding), "Cached setup opened tools")
                let result = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(result == .authorized(offline: true) && f.requests == 1, "Cached setup re-requested")
                f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                let another = f.session()
                try expect(!another.canContinueSetup(candidate: f.udid, binding: "B|external"), "Wrong pairing continued")
                try await rejects { _ = try await another.authorize(actualUDID: f.udid, binding: "B|external") }
                let old = f.cache!; f.cache = LauncherBoundAuthorization(policy: .vip, udid: old.udid, binding: old.binding, envelope: old.envelope)
                try await rejects { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
            }),
            ("Signed refusal survives failed deletion and restart", {
                for banned in [false, true] {
                    let f = Fixture(); try await f.seed(); f.failDelete = true
                    f.response = { _, nonce in try f.envelope(nonce: nonce, status: banned ? "BANNED" : "UNKNOWN", registered: banned, banned: banned) }
                    let s = f.session()
                    try await rejects(banned ? .banned : .notRegistered) { _ = try await s.authorize(actualUDID: f.udid, binding: f.binding) }
                    try expect(f.cache != nil && f.state?.requiresOnline == true && !s.isAuthorized(binding: f.binding), "Denied grant revived")
                    try expect(!f.session().canContinueSetup(candidate: f.udid), "Restart ignored barrier")
                }
            }),
            ("Old backend without signed registration cannot fall back to old cache", {
                let f = Fixture(); try await f.seed()
                f.response = { _, nonce in try f.envelope(nonce: nonce, registered: nil) }
                try await rejects(.serverUnsupported) { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                try expect(f.state?.requiresOnline == true && f.cache == nil, "Old schema allowed offline")
            }),
            ("Malformed response keeps only an independently verified old grant", {
                let f = Fixture(); try await f.seed(); let old = f.cache; f.response = { _, _ in Data("maintenance".utf8) }
                let result = try await f.session().authorize(actualUDID: f.udid, binding: f.binding)
                try expect(result == .authorized(offline: true) && f.cache == old, "Invalid data replaced grant")
                let empty = Fixture(); empty.response = f.response
                try await rejects { _ = try await empty.session().authorize(actualUDID: empty.udid, binding: empty.binding) }
            }),
            ("Cancelled precheck ignores late signed response and caches nothing", {
                let f = Fixture(); var continuation: CheckedContinuation<Data, Never>?; var reply = Data()
                f.response = { _, nonce in reply = try f.envelope(nonce: nonce); return await withCheckedContinuation { continuation = $0 } }
                let s = f.session(); let task = Task { try await s.precheck(candidate: f.udid) }
                try await wait { continuation != nil }; s.cancel(); continuation?.resume(returning: reply)
                try await rejects(.cancelled) { _ = try await task.value }
                try expect(f.cache == nil && !s.canContinueSetup(candidate: f.udid), "Late response granted")
            }),
            ("Already-cancelled caller cannot consume pending fast path or start precheck", {
                let f = Fixture(); let s = f.session(); _ = try await s.precheck(candidate: f.udid)
                let bind = Task { () throws -> LauncherDeviceAuthorization.Result in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await s.authorize(actualUDID: f.udid, binding: f.binding)
                }
                try await rejects(.cancelled) { _ = try await bind.value }
                try expect(f.cache == nil && f.cacheWrites == 0, "Cancelled fast path cached")
                let precheck = Task { () throws -> LauncherDeviceAuthorization.Result in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await s.precheck(candidate: f.udid)
                }
                try await rejects(.cancelled) { _ = try await precheck.value }
                try expect(f.requests == 1, "Cancelled precheck requested")
            }),
            ("Invalidated or expired pending cannot authorize offline", {
                for expire in [false, true] {
                    let f = Fixture(); let s = f.session(); _ = try await s.precheck(candidate: f.udid)
                    if expire { f.advance(7 * 86400) } else { s.invalidatePending() }
                    f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                    try await rejects { _ = try await s.authorize(actualUDID: f.udid, binding: f.binding) }
                    try expect(f.cache == nil, "Invalid pending persisted")
                }
            }),
            ("Seven-day boundary does not renew across retry or restart", {
                let f = Fixture(); try await f.seed(); let old = f.cache
                f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                f.advance(7 * 86400 - 1); _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding)
                f.advance(1); try await rejects { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                try expect(f.cache == old, "Retry renewed cache")
            }),
            ("Normal reboot preserves offline; rollback is repaired by fresh signed server time", {
                let f = Fixture(); try await f.seed(); f.advance(86400); f.boot = "B"; f.uptime = 20
                f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding)
                f.wall -= 3600
                try await rejects { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                try expect(f.state?.requiresOnline == true, "Rollback marker absent")
                f.response = nil; let s = f.session(); _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                try expect(s.isAuthorized(binding: f.binding), "Wrong clock prevented recovery")
            }),
            ("Repeated small rollback tolerance cannot refill after process restart", {
                let f = Fixture(); try await f.seed(); f.response = { _, _ in throw WowDeviceAccessError.networkUnavailable }
                for _ in 0..<2 { f.uptime += 50; _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                f.uptime += 50
                try await rejects { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                try expect(f.state?.requiresOnline == true, "Tolerance refilled")
            }),
            ("Keychain failures stop requests and unconfirmed cache writes fail closed", {
                let blocked = Fixture(); blocked.failStateWrite = true
                try await rejects(.persistenceUnavailable) { _ = try await blocked.session().authorize(actualUDID: blocked.udid, binding: blocked.binding) }
                try expect(blocked.requests == 0, "Network bypassed failed barrier")
                for silent in [false, true] {
                    let f = Fixture(); f.failCacheWrite = !silent; f.ignoreCacheWrite = silent; let s = f.session()
                    try await rejects(.persistenceUnavailable) { _ = try await s.authorize(actualUDID: f.udid, binding: f.binding) }
                    try expect(f.cache == nil && f.state?.requiresOnline == true && !s.isAuthorized(binding: f.binding), "Unconfirmed save allowed")
                }
            }),
            ("Failed final security commit leaves stored grant blocked", {
                let f = Fixture(); f.response = { _, nonce in f.failStateWrite = true; return try f.envelope(nonce: nonce) }
                try await rejects(.persistenceUnavailable) { _ = try await f.session().authorize(actualUDID: f.udid, binding: f.binding) }
                f.failStateWrite = false
                try expect(f.cache != nil && f.state?.requiresOnline == true && !f.session().canContinueSetup(candidate: f.udid), "Failed final commit revived")
            }),
            ("In-flight crash barrier blocks restart; deliberate cancellation preserves old cache", {
                let f = Fixture(); try await f.seed(); var continuation: CheckedContinuation<Data, Never>?
                f.response = { _, _ in await withCheckedContinuation { continuation = $0 } }
                let s = f.session(); let task = Task { try await s.authorize(actualUDID: f.udid, binding: f.binding) }
                try await wait { continuation != nil }; try expect(!f.session().canContinueSetup(candidate: f.udid), "Crash marker ignored")
                s.cancel(); continuation?.resume(returning: Data())
                try await rejects(.cancelled) { _ = try await task.value }
                try expect(f.session().canContinueSetup(candidate: f.udid), "Cancellation lost valid bound cache")
            }),
            ("Rendering gate is memory-only and enforces pairing and rollback", {
                let f = Fixture(); let s = f.session(); _ = try await s.authorize(actualUDID: f.udid, binding: f.binding)
                let writes = f.stateWrites; f.failStateRead = true
                for _ in 0..<100 { try expect(s.isAuthorized(binding: f.binding), "Valid lease failed") }
                try expect(f.stateWrites == writes && !s.isAuthorized(binding: "other"), "Rendering did persistence or ignored binding")
                f.wall -= 121; try expect(!s.isAuthorized(binding: f.binding), "Lease ignored rollback")
            }),
            ("Identity parser accepts one valid UDID and ignores permission knobs", {
                let f = Fixture()
                let plist = try PropertyListSerialization.data(fromPropertyList: ["udid": f.udid, "freeMode": true, "url": "https://evil.invalid"], format: .binary, options: 0)
                try expect(DeviceAuthorizationIdentity.candidate(wowVIPPlist: plist, mobileProvision: nil) == f.udid, "Hint parser failed")
                let many = try PropertyListSerialization.data(fromPropertyList: ["ProvisionedDevices": [f.udid, f.udid]], format: .xml, options: 0)
                try expect(DeviceAuthorizationIdentity.candidate(wowVIPPlist: nil, mobileProvision: many) == nil, "Ambiguous profile guessed")
            })
        ]
        do {
            for (name, test) in tests { try await test(); print("PASS " + name) }
            print("LauncherDeviceAuthorizationTests: \(tests.count) passed")
        } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
}
