import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

@MainActor private final class PersistentAuthorizationFixture {
    let key = P256.Signing.PrivateKey()
    let gate = VipLocationGate()
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    var server = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 1_000
    var boot = "boot-A"
    let binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/fixture", pairingSignature: "fixture-A")
    var cache: CachedVipAuthorization?
    var state: VipAuthorizationSecurityState?
    var requests = 0
    var failStateRead = false
    var corruptState = false
    var failStateWrite = false
    var ignoreStateWrite = false
    var failCacheWrite = false
    var ignoreCacheWrite = false
    var failDelete = false
    var response: ((String, String) async throws -> Data)?

    func envelope(nonce: String, status: String = "VALID") throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "udid": "test-device", "nonce": nonce, "status": status, "isVip": status == "VALID",
            "isBanned": status == "BANNED", "expireAt": 0, "ts": server.timeIntervalSince1970 * 1000
        ])
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(),
            "sig": key.signature(for: payload).derRepresentation.base64EncodedString()])
    }

    func seed() throws {
        cache = CachedVipAuthorization(binding: binding, udid: "test-device", envelope: try envelope(nonce: "old"))
        state = .anchored(serverTime: server.timeIntervalSince1970, wallTime: wall,
                          uptime: uptime, bootID: boot, envelope: cache!.envelope)
    }

    func advance(_ seconds: TimeInterval) {
        wall += seconds; server += seconds; uptime += seconds
    }

    func request(_ udid: String, nonce: String) async throws -> Data {
        requests += 1
        // This assertion exercises the durable barrier before *every* transport call.
        #expect(state?.requiresOnline == true)
        return try await response?(udid, nonce) ?? envelope(nonce: nonce)
    }

    func service() -> VipAuthorizationService {
        let dependencies = VipAuthorizationDependencies(
            binding: { self.binding }, canReadDevice: { true }, readDevice: { _ in "test-device" },
            request: { udid, nonce, _ in try await self.request(udid, nonce: nonce) }, load: { self.cache }, loadLegacy: { _ in nil },
            save: {
                if self.failCacheWrite { throw VipPersistenceFailure.unavailable }
                if !self.ignoreCacheWrite { self.cache = $0 }
            },
            remove: {
                if self.failDelete { throw VipPersistenceFailure.unavailable }
                self.cache = nil
            },
            loadSecurityState: {
                if self.failStateRead { throw VipPersistenceFailure.unavailable }
                if self.corruptState { throw VipPersistenceFailure.invalidState }
                return self.state
            },
            saveSecurityState: {
                if self.failStateWrite { throw VipPersistenceFailure.unavailable }
                if !self.ignoreStateWrite { self.state = $0; self.corruptState = false }
            },
            verify: { try VipLicenseVerifier.verify($0, udid: $1, nonce: $2, now: $3,
                publicKey: self.key.publicKey.x963Representation, trustFreshServerTime: $2 != nil) },
            now: { self.wall }, revoked: {}, deviceTimeout: 1, requestTimeout: 2,
            uptime: { self.uptime }, bootID: { self.boot })
        return VipAuthorizationService(dependencies: dependencies, gate: gate)
    }

    func activate(_ service: VipAuthorizationService) async {
        service.startSetup()
        await service.refresh(force: true)
    }
}

@Suite(.serialized) @MainActor struct AuthorizationPersistenceTests {
    @Test func appRestartCannotForgetElapsedUptimeOrRefillOfflineWeek() throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        #expect(f.service().restoreCachedAuthorization() != nil)
        // No more checkpoints before the process dies. Persisted uptime still accounts for elapsed time.
        f.uptime += 7 * 86400
        #expect(f.service().restoreCachedAuthorization() == nil)
        #expect(f.state?.requiresOnline == true)
    }

    @Test func accumulatedSmallRollbacksExceedToleranceInsteadOfRefillingIt() throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        for _ in 0..<2 {
            f.uptime += 50
            #expect(f.service().restoreCachedAuthorization() != nil)
        }
        f.uptime += 50
        #expect(f.service().restoreCachedAuthorization() == nil)
        #expect(f.state?.requiresOnline == true)
    }

    @Test func rebootAndWallRollbackCannotRestorePreviousHighwater() throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        f.advance(6 * 86400)
        #expect(f.service().restoreCachedAuthorization() != nil)
        f.boot = "boot-B"; f.uptime = 10; f.wall -= 5 * 86400
        #expect(f.service().restoreCachedAuthorization() == nil)
    }

    @Test func ordinaryDeviceRebootKeepsUnexpiredOfflineLicense() throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        f.advance(2 * 86400)
        #expect(f.service().restoreCachedAuthorization() != nil)
        f.advance(86400)
        f.boot = "boot-B"; f.uptime = 30
        #expect(f.service().restoreCachedAuthorization() != nil)
        #expect(f.requests == 0)
    }

    @Test func freshSignedNonceRestoresWrongClockWithoutGrantingExtraOfflineTime() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        f.advance(86400)
        f.wall -= 30 * 86400
        let service = f.service()
        #expect(service.restoreCachedAuthorization() == nil)
        await f.activate(service)
        #expect(service.isAuthorized && f.requests == 1)
        #expect(f.gate.allows(udid: "test-device", now: f.wall, uptime: f.uptime))
        let expires = f.server + 7 * 86400
        #expect(f.state?.serverAnchor == f.server.timeIntervalSince1970)
        f.advance(7 * 86400)
        #expect(f.server == expires)
        #expect(f.service().restoreCachedAuthorization() == nil)
        #expect(!f.gate.allows(now: f.wall, uptime: f.uptime))
    }

    @Test func clockForwardThenCorrectedCanRecoverOnline() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        f.wall += 30 * 86400
        #expect(f.service().restoreCachedAuthorization() == nil)
        f.wall = f.server
        let service = f.service()
        #expect(service.restoreCachedAuthorization() == nil)
        await f.activate(service)
        #expect(service.isAuthorized && f.state?.requiresOnline == false)
    }

    @Test func cacheWithoutSecurityStateRequiresFreshOnlineMigration() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed(); f.state = nil
        let service = f.service()
        #expect(service.restoreCachedAuthorization() == nil)
        await f.activate(service)
        #expect(service.isAuthorized && f.requests == 1)
    }

    @Test func failedDeletionAndAllSubsequentWritesCannotRestoreSignedBan() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        f.failDelete = true
        f.response = { _, nonce in
            f.failStateWrite = true
            return try f.envelope(nonce: nonce, status: "BANNED")
        }
        let service = f.service()
        await f.activate(service)
        #expect(!service.isAuthorized && f.cache != nil && f.state?.requiresOnline == true)
        f.failStateWrite = false
        #expect(service.restoreCachedAuthorization() == nil)
        #expect(f.service().restoreCachedAuthorization() == nil)
        #expect(f.requests == 1)
    }

    @Test func unavailablePersistencePreventsRequestAndOfflineGrant() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed(); f.failStateWrite = true
        let service = f.service()
        await f.activate(service)
        #expect(!service.isAuthorized && f.requests == 0)
        #expect(f.service().restoreCachedAuthorization() == nil)
    }

    @Test func unreadableSecurityStateIsNotTreatedAsFirstInstall() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed(); f.failStateRead = true
        let service = f.service()
        await f.activate(service)
        #expect(!service.isAuthorized && f.requests == 0)
    }

    @Test func corruptStateRequiresConfirmedReplacementAndOnlineRecovery() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed(); f.corruptState = true
        let service = f.service()
        #expect(service.restoreCachedAuthorization() == nil)
        await f.activate(service)
        #expect(service.isAuthorized && f.requests == 1 && !f.corruptState)
    }

    @Test func unconfirmedRequestBarrierDoesNotSendRequest() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed(); f.ignoreStateWrite = true
        let service = f.service()
        await f.activate(service)
        #expect(f.requests == 0 && !service.isAuthorized)
    }

    @Test(arguments: [false, true]) func failedOrUnconfirmedCacheSaveCannotAuthorize(_ silently: Bool) async {
        let f = PersistentAuthorizationFixture()
        f.failCacheWrite = !silently; f.ignoreCacheWrite = silently
        let service = f.service()
        await f.activate(service)
        #expect(!service.isAuthorized && f.cache == nil && f.state?.requiresOnline == true)
        #expect(f.service().restoreCachedAuthorization() == nil)
    }

    @Test func failedFinalSecurityCommitLeavesPersistedGrantBlocked() async {
        let f = PersistentAuthorizationFixture()
        f.response = { _, nonce in
            f.failStateWrite = true
            return try f.envelope(nonce: nonce)
        }
        let service = f.service()
        await f.activate(service)
        #expect(!service.isAuthorized && f.cache != nil && f.state?.requiresOnline == true)
        f.failStateWrite = false
        #expect(f.service().restoreCachedAuthorization() == nil)
    }

    @Test func interruptedRequestLeavesDurableBarrierForNextProcess() async throws {
        let f = PersistentAuthorizationFixture()
        try f.seed()
        var pending: CheckedContinuation<Data, Never>?
        f.response = { _, _ in await withCheckedContinuation { pending = $0 } }
        let service = f.service()
        service.startSetup()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        #expect(pending != nil && f.state?.requiresOnline == true)
        #expect(f.service().restoreCachedAuthorization() == nil)
        service.cancelVerification()
        pending?.resume(returning: Data())
        #expect(service.isAuthorized) // deliberate cancellation can restore the prior grant.
    }

    @Test func commandGateRepeatedRestoreCannotExtendMonotonicDeadline() {
        let f = PersistentAuthorizationFixture()
        let license = VipLicense(udid: "test-device", status: "VALID", isVip: true, isBanned: false,
            expireAt: (f.wall + 100).timeIntervalSince1970 * 1000, nonce: "nonce", ts: f.wall.timeIntervalSince1970 * 1000)
        f.gate.update(license, now: f.wall, uptime: f.uptime)
        // A caller supplies an earlier wall time while refreshing the identical license.
        f.gate.update(license, now: f.wall - 60, uptime: f.uptime + 50)
        #expect(!f.gate.allows(now: f.wall, uptime: f.uptime + 101))
    }
}
