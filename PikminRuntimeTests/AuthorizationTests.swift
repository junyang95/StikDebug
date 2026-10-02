import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

@MainActor
private final class AuthorizationFixture {
    var now = Date()
    let key = P256.Signing.PrivateKey()
    let gate = VipLocationGate()
    var binding: VipDeviceBinding? = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/pairing", pairingSignature: "A")
    var cache: CachedVipAuthorization?
    var legacy: Data?
    var canRead = true
    var deviceReads = 0
    var removals = 0
    var revocations = 0
    var response: ((String, String) async throws -> Data)?
    var waiting: (@Sendable () -> Void)?
    var requestCount = 0
    var requestTimeout: TimeInterval = 0.05
    var deviceResponse: (() async throws -> String)?

    func envelope(udid: String = "test-device", nonce: String, status: String = "VALID", vip: Bool = true,
                  banned: Bool = false, timestamp: Date? = nil, expireAt: Double = 0) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: ["udid": udid, "nonce": nonce, "status": status,
            "isVip": vip, "isBanned": banned, "ts": (timestamp ?? now).timeIntervalSince1970 * 1000, "expireAt": expireAt])
        return try JSONSerialization.data(withJSONObject: ["payload": raw.base64EncodedString(),
            "sig": key.signature(for: raw).derRepresentation.base64EncodedString()])
    }
    func seed(age: TimeInterval = 0, expireAt: Double = 0) throws {
        cache = CachedVipAuthorization(binding: binding!, udid: "test-device",
            envelope: try envelope(nonce: "previous", timestamp: now.addingTimeInterval(-age), expireAt: expireAt))
    }
    func read() async throws -> String {
        deviceReads += 1
        return try await deviceResponse?() ?? "test-device"
    }
    func request(udid: String, nonce: String, waiting: @escaping @Sendable () -> Void) async throws -> Data {
        self.waiting = waiting
        requestCount += 1
        if let response { return try await response(udid, nonce) }
        return try envelope(udid: udid, nonce: nonce)
    }
    func makeService() -> VipAuthorizationService {
        let dependencies = VipAuthorizationDependencies(
            binding: { self.binding }, canReadDevice: { self.canRead },
            readDevice: { _ in try await self.read() },
            request: { try await self.request(udid: $0, nonce: $1, waiting: $2) },
            load: { self.cache }, loadLegacy: { _ in self.legacy }, save: { self.cache = $0 },
            remove: { self.cache = nil; self.legacy = nil; self.removals += 1 },
            verify: { try VipLicenseVerifier.verify($0, udid: $1, nonce: $2, now: $3, publicKey: self.key.publicKey.x963Representation) },
            now: { self.now }, revoked: { self.revocations += 1 }, deviceTimeout: 0.05, requestTimeout: requestTimeout)
        return VipAuthorizationService(dependencies: dependencies, gate: gate)
    }
}

@Suite(.serialized) @MainActor struct AuthorizationTests {
    @Test func allowsNetworkAfterFirstDenialRetriesImmediately() async {
        let f = AuthorizationFixture()
        f.response = { _, _ in throw URLError(.dataNotAllowed) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && service.needsNetworkSettings)
        #expect(f.removals == 0)
        f.response = nil
        service.connectionDidBecomeAvailable()
        await waitUntil { !service.isChecking }
        #expect(service.isAuthorized && !service.needsNetworkSettings)
        #expect(f.requestCount == 2)
    }

    @Test func grantingPermissionResumesPendingRequestWithoutDuplicate() async throws {
        let f = AuthorizationFixture()
        f.requestTimeout = 2
        var pending: CheckedContinuation<Data, Never>?
        var responseData = Data()
        f.response = { udid, nonce in
            responseData = try f.envelope(udid: udid, nonce: nonce)
            f.waiting?()
            return await withCheckedContinuation { pending = $0 }
        }
        let service = f.makeService()
        service.verifyManually()
        await waitUntil { pending != nil && service.needsNetworkSettings }
        #expect(service.isChecking && !service.isAuthorized)
        service.connectionDidBecomeAvailable()
        pending?.resume(returning: responseData)
        await waitUntil { !service.isChecking }
        #expect(service.isAuthorized && !service.needsNetworkSettings)
        #expect(f.requestCount == 1)
    }

    @Test func recoveryDuringFailedRequestIsNotLostOrDuplicated() async {
        let f = AuthorizationFixture()
        let service = f.makeService()
        f.response = { udid, nonce in
            if f.requestCount == 1 {
                service.connectionDidBecomeAvailable()
                service.connectionDidBecomeAvailable()
                service.connectionDidBecomeAvailable()
                throw URLError(.notConnectedToInternet)
            }
            return try f.envelope(udid: udid, nonce: nonce)
        }
        service.verifyManually()
        await waitUntil { !service.isChecking }
        #expect(service.isAuthorized && f.requestCount == 2)
    }

    @Test func vpnPermissionThenConnectionRetriesDeviceRead() async {
        let f = AuthorizationFixture()
        f.canRead = false
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && f.deviceReads == 0)
        f.canRead = true
        service.connectionDidBecomeAvailable()
        await waitUntil { !service.isChecking }
        #expect(service.isAuthorized && f.deviceReads == 1)
    }

    @Test func deniedNetworkPermissionKeepsExistingOfflineLicense() async throws {
        let f = AuthorizationFixture()
        try f.seed(age: 3600)
        f.response = { _, _ in throw URLError(.dataNotAllowed) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized && service.needsNetworkSettings)
        #expect(f.cache != nil && f.removals == 0 && f.revocations == 0)
    }

    @Test func cancelWhileWaitingPreventsAutomaticRestartAndLatePromptState() async {
        let f = AuthorizationFixture()
        f.requestTimeout = 2
        var pending: CheckedContinuation<Data, Never>?
        f.response = { _, _ in
            f.waiting?()
            return await withCheckedContinuation { pending = $0 }
        }
        let service = f.makeService()
        service.verifyManually()
        await waitUntil { pending != nil && service.needsNetworkSettings }
        let lateWaiting = f.waiting
        service.cancelVerification()
        service.connectionDidBecomeAvailable()
        lateWaiting?()
        pending?.resume(returning: Data())
        await Task.yield()
        #expect(!service.isChecking && !service.needsNetworkSettings && !service.isAuthorized)
        #expect(f.requestCount == 1)
    }

    @Test func networkChangeDoesNotRetryAnAuthenticatedBan() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        let service = f.makeService()
        f.response = { udid, nonce in
            service.connectionDidBecomeAvailable()
            return try f.envelope(udid: udid, nonce: nonce, status: "BANNED", banned: true)
        }
        await service.refresh(force: true)
        service.connectionDidBecomeAvailable()
        await Task.yield()
        #expect(!service.isAuthorized && !service.isChecking)
        #expect(f.requestCount == 1 && f.cache == nil)
    }

    @Test func onlineActivationSavesSignedDeviceBinding() async {
        let f = AuthorizationFixture()
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized)
        #expect(!service.isChecking)
        #expect(f.cache?.udid == "test-device")
        #expect(f.deviceReads == 1)
    }
    @Test func coldLaunchDuringOutageRestoresCacheWithoutVPNOrDeviceRead() async throws {
        let f = AuthorizationFixture()
        try f.seed(age: 86400)
        f.canRead = false
        f.response = { _, _ in throw URLError(.cannotConnectToHost) }
        let service = f.makeService()
        #expect(service.restoreCachedAuthorization() != nil)
        #expect(service.isAuthorized)
        await service.refresh(force: true)
        #expect(service.isAuthorized)
        #expect(f.gate.allows(udid: "test-device", now: f.now))
        #expect(f.deviceReads == 0)
        #expect(f.removals == 0 && f.revocations == 0)
        #expect(!service.isChecking)
    }
    @Test func maintenanceHTMLKeepsPreviouslyVerifiedAccess() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.response = { _, _ in Data("<html>Maintenance</html>".utf8) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized)
        #expect(f.cache != nil && f.removals == 0)
    }
    @Test func offlineRetriesDoNotRestartThreeDayClock() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.response = { _, _ in throw URLError(.timedOut) }
        let service = f.makeService()
        await service.refresh(force: true)
        let deadline = try #require(service.offlineValidUntil)
        f.now = f.now.addingTimeInterval(2 * 86400)
        await service.refresh(force: true)
        #expect(service.isAuthorized && service.offlineValidUntil == deadline)
        f.now = deadline
        await service.refresh(force: true)
        #expect(!service.isAuthorized)
        #expect(!f.gate.allows(now: f.now))
    }
    @Test func vipExpiryStillLimitsOfflineUse() async throws {
        let f = AuthorizationFixture()
        try f.seed(expireAt: f.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        f.response = { _, _ in throw URLError(.notConnectedToInternet) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized)
        f.now = f.now.addingTimeInterval(3601)
        await service.refresh(force: true)
        #expect(!service.isAuthorized)
    }
    @Test func signedBanClearsOfflineGrantAcrossRestarts() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.response = { udid, nonce in try f.envelope(udid: udid, nonce: nonce, status: "BANNED", banned: true) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && f.cache == nil)
        #expect(f.removals == 1)
        #expect(f.makeService().restoreCachedAuthorization() == nil)
    }
    @Test func sandboxRelocationRetainsSamePairingLicenseDuringOutage() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/new-container/pairing", pairingSignature: "A")
        f.canRead = false
        f.response = { _, _ in throw URLError(.notConnectedToInternet) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized && f.deviceReads == 0)
        #expect(f.cache != nil && f.removals == 0)
    }
    @Test func differentPairingCannotReuseStoredEntitlement() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/pairing", pairingSignature: "B")
        f.canRead = false
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized)
        #expect(!f.gate.allows(now: f.now))
    }
    @Test func noInitialLicenseDoesNotGetFreeOfflineGrace() async {
        let f = AuthorizationFixture()
        f.response = { _, _ in throw URLError(.cannotFindHost) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && !service.isChecking)
    }
    @Test func legacySignedCacheMigratesDuringOutage() async throws {
        let f = AuthorizationFixture()
        f.legacy = try f.envelope(nonce: "old", timestamp: f.now.addingTimeInterval(-3600))
        f.response = { _, _ in throw URLError(.notConnectedToInternet) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(service.isAuthorized && f.cache != nil)
        #expect(f.deviceReads == 1)
    }
    @Test func hungDeviceReadTimesOutAndLateResultCannotAuthorize() async {
        let f = AuthorizationFixture()
        var pending: CheckedContinuation<String, Never>?
        f.deviceResponse = { await withCheckedContinuation { pending = $0 } }
        let service = f.makeService()
        let start = ContinuousClock.now
        await service.refresh(force: true)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(!service.isChecking && !service.isAuthorized)
        pending?.resume(returning: "test-device")
        await Task.yield()
        #expect(!service.isAuthorized && f.cache == nil)
    }
    @Test func manualButtonRespondsImmediatelyAndCancelsHungRequest() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        var pending: CheckedContinuation<Data, Never>?
        f.response = { _, _ in await withCheckedContinuation { pending = $0 } }
        let service = f.makeService()
        service.verifyManually()
        #expect(service.isChecking)
        while pending == nil { await Task.yield() }
        service.verifyManually()
        #expect(!service.isChecking && service.isAuthorized)
        pending?.resume(returning: Data())
        f.response = nil
        await service.refresh(force: true)
        #expect(service.isAuthorized && !service.isChecking)
    }
    @Test func serverTimeoutRetainsLicenseAndReleasesButton() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        var pending: CheckedContinuation<Data, Never>?
        f.response = { _, _ in await withCheckedContinuation { pending = $0 } }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isChecking && service.isAuthorized)
        #expect(f.removals == 0)
        pending?.resume(returning: Data())
    }
}

struct GuidePolicyTests {
    @Test func unpairedIOS27PresentsGuideOncePerLaunch() {
        #expect(PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: false, presentedThisLaunch: false))
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: false, presentedThisLaunch: true))
    }
    @Test func pairedAndOlderDevicesDoNotGetAutomaticGuide() {
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: true, hasValidPairing: true, presentedThisLaunch: false))
        #expect(!PairingGuidePolicy.shouldPresent(isSupported: false, hasValidPairing: false, presentedThisLaunch: false))
    }
}

struct AuthorizationDeviceReaderTests {
    @Test func timedOutPhysicalReadDoesNotQueueAnotherBlockingCall() async {
        let reader = AuthorizationDeviceReader()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        do {
            _ = try await withAuthorizationDeadline(seconds: 0.2) {
                try await reader.read {
                    release.wait()
                    return "test-device"
                }
            }
            Issue.record("Expected the physical read to time out")
        } catch AuthorizationOperationError.timedOut {
            // The UI has returned, but the physical operation still owns its worker.
        } catch {
            Issue.record("Unexpected timeout result: \(error)")
        }
        do {
            _ = try await reader.read { "unexpected-second-read" }
            Issue.record("Queued a second physical read before the first one returned")
        } catch AuthorizationOperationError.deviceBusy {
        } catch {
            Issue.record("Unexpected busy result: \(error)")
        }
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(predicate())
}

struct AuthorizationTransportTests {
    @Test func sessionWaitsForPermissionAndHasBoundedLifetime() {
        let configuration = AuthorizationHTTPClient.configuration()
        #expect(configuration.waitsForConnectivity)
        #expect(configuration.allowsCellularAccess)
        #expect(configuration.allowsExpensiveNetworkAccess && configuration.allowsConstrainedNetworkAccess)
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 60)
    }
}

@Suite(.serialized) @MainActor struct AuthorizationRenewalTests {
    @Test func expiredSignedIdentityCanRenewWithoutLocalVPN() async throws {
        let f = AuthorizationFixture()
        try f.seed(age: 4 * 86400)
        f.canRead = false
        let service = f.makeService()
        #expect(service.restoreCachedAuthorization() == nil)
        #expect(!service.isAuthorized)
        await service.refresh(force: true)
        #expect(service.isAuthorized && f.requestCount == 1 && f.deviceReads == 0)
    }

    @Test func pairingChangeBeforeRequestCannotReusePreviousDeviceIdentity() async throws {
        let f = AuthorizationFixture()
        try f.seed()
        f.canRead = false
        let service = f.makeService()
        service.verifyManually()
        f.binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/pairing", pairingSignature: "replacement")
        await waitUntil { !service.isChecking }
        #expect(!service.isAuthorized && f.requestCount == 0)
        #expect(service.lastDiagnostic == "device: VPN unavailable")
    }

    @Test func expiredIdentityNeverGrantsOfflineAccess() async throws {
        let f = AuthorizationFixture()
        try f.seed(age: 4 * 86400)
        f.canRead = false
        f.response = { _, _ in throw URLError(.dnsLookupFailed) }
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && !f.gate.allows(now: f.now))
        #expect(f.requestCount == 1 && f.deviceReads == 0)
        #expect(service.lastDiagnostic == "network: URL -1006")
    }

    @Test func invalidSignatureCannotSupplyCachedIdentity() async {
        let f = AuthorizationFixture()
        f.cache = CachedVipAuthorization(binding: f.binding!, udid: "tampered", envelope: Data("invalid".utf8))
        f.canRead = false
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && f.requestCount == 0)
    }

    @Test func changedPairingCannotRenewUsingExpiredIdentity() async throws {
        let f = AuthorizationFixture()
        try f.seed(age: 4 * 86400)
        f.binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/pairing", pairingSignature: "new")
        f.canRead = false
        let service = f.makeService()
        await service.refresh(force: true)
        #expect(!service.isAuthorized && f.requestCount == 0)
    }
}

@Suite(.serialized) struct AuthorizationRetryTests {
    @Test func cellularHandoverRetriesEvenWhenBothPathsAreSatisfied() {
        var recovery = AuthorizationPathRecovery()
        let wifi = AuthorizationNetworkPath(satisfied: true, interfaces: ["wifi:en0"], ipv4: true, ipv6: true, dns: true, expensive: false, constrained: false)
        let cellular = AuthorizationNetworkPath(satisfied: true, interfaces: ["cellular:pdp_ip0"], ipv4: false, ipv6: true, dns: true, expensive: true, constrained: false)
        let events = [recovery.update(wifi), recovery.update(wifi), recovery.update(cellular),
                      recovery.update(cellular), recovery.update(wifi)]
        #expect(events == [true, false, true, false, true])
    }

    @Test func offlinePathDoesNotTriggerARequest() {
        var recovery = AuthorizationPathRecovery()
        let offline = AuthorizationNetworkPath(satisfied: false, interfaces: [], ipv4: false, ipv6: false, dns: false, expensive: false, constrained: false)
        let events = [recovery.update(offline), recovery.update(offline)]
        #expect(events == [false, false])
    }

    @Test func transientFailuresRecoverWithBoundedBackoff() async throws {
        var count = 0
        var delays: [TimeInterval] = []
        let result = try await AuthorizationRequestRetry.run(operation: {
            count += 1
            if count == 1 { throw URLError(.networkConnectionLost) }
            if count == 2 { throw URLError(.dnsLookupFailed) }
            return Data("signed-response".utf8)
        }, sleep: { delays.append($0) })
        #expect(count == 3 && delays == [1, 2])
        #expect(result == Data("signed-response".utf8))
    }

    @Test func persistentTransportFailureStopsAfterThreeAttempts() async {
        var count = 0
        do {
            _ = try await AuthorizationRequestRetry.run(operation: {
                count += 1
                throw URLError(.timedOut)
            }, sleep: { _ in })
            Issue.record("Expected timeout")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(count == 3)
    }

    @Test func permissionTLSAndAccessDenialsAreNotRetried() async {
        for error: Error in [URLError(.dataNotAllowed), URLError(.secureConnectionFailed), URLError(.serverCertificateUntrusted), AuthorizationHTTPError(status: 403), AuthorizationHTTPError(status: 429)] {
            var count = 0
            do {
                _ = try await AuthorizationRequestRetry.run(operation: { count += 1; throw error }, sleep: { _ in })
                Issue.record("Expected rejection")
            } catch { }
            #expect(count == 1)
        }
    }

    @Test func cancelledBackoffNeverStartsAnotherRequest() async {
        var count = 0
        do {
            _ = try await AuthorizationRequestRetry.run(operation: {
                count += 1; throw URLError(.networkConnectionLost)
            }, sleep: { _ in throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(count == 1)
    }

    @Test func serverMaintenanceCanRecover() async throws {
        var count = 0
        _ = try await AuthorizationRequestRetry.run(operation: {
            count += 1
            if count == 1 { throw AuthorizationHTTPError(status: 503) }
            return Data()
        }, sleep: { _ in })
        #expect(count == 2)
    }
}
