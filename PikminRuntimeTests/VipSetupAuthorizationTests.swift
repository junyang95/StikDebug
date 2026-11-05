import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

@MainActor
private final class VipSetupFixture {
    var now = Date()
    let key = P256.Signing.PrivateKey()
    let gate = VipLocationGate()
    var binding: VipDeviceBinding?
    var candidate: String? = "setup-device"
    var canRead = false
    var actualUDID = "setup-device"
    var cache: CachedVipAuthorization?
    var securityState: VipAuthorizationSecurityState?
    var deviceReads = 0
    var requests: [String] = []
    var saves = 0
    var removals = 0
    var revocations = 0
    var response: ((String, String) async throws -> Data)?
    var deviceResponse: (() async throws -> String)?

    func envelope(udid: String, nonce: String, status: String = "VALID", vip: Bool = true,
                  banned: Bool = false) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "udid": udid, "nonce": nonce, "status": status,
            "isVip": vip, "isBanned": banned, "expireAt": 0,
            "ts": now.timeIntervalSince1970 * 1000
        ])
        return try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "sig": key.signature(for: payload).derRepresentation.base64EncodedString()
        ])
    }

    func connect(signature: String = "pairing-A") {
        binding = VipDeviceBinding(targetIP: "127.0.0.1", pairingPath: "/pairing", pairingSignature: signature)
        canRead = true
    }

    private func read() async throws -> String {
        deviceReads += 1
        return try await deviceResponse?() ?? actualUDID
    }

    private func request(udid: String, nonce: String) async throws -> Data {
        requests.append(udid)
        return try await response?(udid, nonce) ?? envelope(udid: udid, nonce: nonce)
    }

    func makeService() -> VipAuthorizationService {
        let dependencies = VipAuthorizationDependencies(
            binding: { self.binding }, canReadDevice: { self.canRead },
            readDevice: { _ in try await self.read() },
            request: { udid, nonce, _ in try await self.request(udid: udid, nonce: nonce) },
            load: { self.cache }, loadLegacy: { _ in nil },
            save: { self.cache = $0; self.saves += 1 },
            remove: { self.cache = nil; self.removals += 1 },
            loadSecurityState: { self.securityState }, saveSecurityState: { self.securityState = $0 },
            verify: { try VipLicenseVerifier.verify($0, udid: $1, nonce: $2, now: $3,
                publicKey: self.key.publicKey.x963Representation, trustFreshServerTime: $2 != nil) },
            now: { self.now }, revoked: { self.revocations += 1 },
            deviceTimeout: 2, requestTimeout: 2, setupIdentity: { self.candidate }
        )
        return VipAuthorizationService(dependencies: dependencies, gate: gate)
    }
}

@Suite(.serialized) @MainActor struct VipSetupAuthorizationTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Expected authorization state transition did not finish")
    }

    @Test func setupVerificationPrecedesPairingAndVPNWithoutGrantingLocation() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        await service.refresh(force: true)
        service.startMonitoring()
        service.connectionDidBecomeAvailable()
        service.pairingDidChange()
        #expect(!service.hasStartedSetup && fixture.requests.isEmpty && fixture.deviceReads == 0)
        service.startSetup()
        await service.refresh(force: true)
        #expect(service.isSetupVerified)
        #expect(!service.isAuthorized && !fixture.gate.allows(now: fixture.now))
        #expect(fixture.requests == ["setup-device"])
        #expect(fixture.deviceReads == 0 && fixture.saves == 0 && fixture.cache == nil)
        #expect(fixture.binding == nil && !fixture.canRead)
        #expect(!service.needsSetupIdentity)
    }

    @Test func vpnRecoveryBindsMatchingPhysicalDeviceWithoutAnotherNetworkRequest() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.response = { _, _ in throw URLError(.cannotConnectToHost) }
        fixture.connect()
        service.connectionDidBecomeAvailable()
        await waitUntil { !service.isChecking }
        #expect(service.isAuthorized && service.isSetupVerified)
        #expect(fixture.gate.allows(udid: "setup-device", now: fixture.now))
        #expect(fixture.deviceReads == 1 && fixture.saves == 1)
        #expect(fixture.cache?.udid == "setup-device")
        #expect(fixture.cache?.binding == fixture.binding)
        #expect(fixture.requests.count == 1)
    }

    @Test func mismatchedPhysicalDeviceCannotUseSetupGrant() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.connect()
        fixture.actualUDID = "another-device"
        await service.refresh(force: true)
        #expect(!service.isAuthorized && !service.isSetupVerified)
        #expect(!fixture.gate.allows(now: fixture.now))
        #expect(fixture.cache == nil && fixture.saves == 0)
        #expect(fixture.deviceReads == 1 && fixture.requests.count == 1)
        #expect(service.lastDiagnostic == "device: setup identity mismatch")
    }

    @Test(arguments: ["BANNED", "EXPIRED", "NOT_VIP"])
    func signedSetupDenialPreventsContinuing(_ status: String) async {
        let fixture = VipSetupFixture()
        fixture.response = { udid, nonce in
            try fixture.envelope(udid: udid, nonce: nonce, status: status,
                vip: status != "NOT_VIP", banned: status == "BANNED")
        }
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(!fixture.gate.allows(now: fixture.now))
        #expect(fixture.cache == nil && fixture.saves == 0 && fixture.removals == 1)
        #expect(fixture.deviceReads == 0)
        service.connectionDidBecomeAvailable()
        await Task.yield()
        #expect(fixture.requests.count == 1)
    }

    @Test func initialNetworkFailureCannotApproveSetupAndRecoveryRetries() async {
        let fixture = VipSetupFixture()
        fixture.response = { _, _ in throw URLError(.cannotFindHost) }
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.saves == 0 && fixture.deviceReads == 0)
        fixture.response = nil
        service.connectionDidBecomeAvailable()
        await waitUntil { !service.isChecking }
        #expect(service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.requests.count == 2 && fixture.saves == 0)
    }

    @Test func missingAutomaticIdentityDoesNotInventAnAuthorizedDevice() async {
        let fixture = VipSetupFixture()
        fixture.candidate = nil
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        #expect(service.needsSetupIdentity)
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.requests.isEmpty && fixture.deviceReads == 0 && fixture.saves == 0)
    }

    @Test func cancellingSetupIgnoresLateSignedResponse() async throws {
        let fixture = VipSetupFixture()
        var pending: CheckedContinuation<Data, Never>?
        var signedResponse = Data()
        fixture.response = { udid, nonce in
            signedResponse = try fixture.envelope(udid: udid, nonce: nonce)
            return await withCheckedContinuation { pending = $0 }
        }
        let service = fixture.makeService()
        service.verifyManually()
        await waitUntil { pending != nil }
        service.cancelVerification()
        pending?.resume(returning: signedResponse)
        await Task.yield()
        await Task.yield()
        #expect(!service.isChecking && !service.isSetupVerified && !service.isAuthorized)
        #expect(!service.hasStartedSetup)
        service.connectionDidBecomeAvailable()
        service.pairingDidChange()
        service.startMonitoring()
        await service.refresh(force: true)
        #expect(fixture.requests.count == 1 && fixture.deviceReads == 0)
        #expect(fixture.saves == 0 && fixture.cache == nil)
        #expect(!fixture.gate.allows(now: fixture.now))
    }

    @Test func expiredPendingSetupCannotAuthorizeDeviceDuringOutage() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.now = fixture.now.addingTimeInterval(7 * 86400 + 1)
        fixture.connect()
        fixture.response = { _, _ in throw URLError(.cannotConnectToHost) }
        await service.refresh(force: true)
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.saves == 0 && fixture.cache == nil && fixture.deviceReads == 0)
        #expect(!fixture.gate.allows(now: fixture.now))
    }

    @Test func pendingSetupExpiryIsRecheckedAfterPhysicalRead() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.connect()
        var pending: CheckedContinuation<String, Never>?
        fixture.deviceResponse = { await withCheckedContinuation { pending = $0 } }
        service.verifyManually()
        await waitUntil { pending != nil }
        fixture.now = fixture.now.addingTimeInterval(7 * 86400 + 1)
        pending?.resume(returning: "setup-device")
        await waitUntil { !service.isChecking }
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.saves == 0 && fixture.cache == nil)
        #expect(!fixture.gate.allows(now: fixture.now))
    }

    @Test func changingPairingDuringPhysicalReadCannotBindItsLateResult() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.connect()
        var pending: CheckedContinuation<String, Never>?
        fixture.deviceResponse = { await withCheckedContinuation { pending = $0 } }
        service.verifyManually()
        await waitUntil { pending != nil }
        fixture.connect(signature: "pairing-B")
        pending?.resume(returning: "setup-device")
        await waitUntil { !service.isChecking }
        #expect(!service.isAuthorized && !fixture.gate.allows(now: fixture.now))
        #expect(fixture.saves == 0 && fixture.cache == nil)
    }

    @Test func cancellingPhysicalReadCannotPromotePendingSetupToRealCache() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.connect()
        var pending: CheckedContinuation<String, Never>?
        fixture.deviceResponse = { await withCheckedContinuation { pending = $0 } }
        service.verifyManually()
        await waitUntil { pending != nil }
        service.cancelVerification()
        pending?.resume(returning: "setup-device")
        await Task.yield()
        await Task.yield()
        #expect(!service.isChecking && !service.isAuthorized)
        #expect(!service.hasStartedSetup)
        service.connectionDidBecomeAvailable()
        service.pairingDidChange()
        await service.refresh(force: true)
        #expect(fixture.deviceReads == 1 && fixture.requests.count == 1)
        #expect(fixture.saves == 0 && fixture.cache == nil && !fixture.gate.allows(now: fixture.now))
    }

    @Test func changedAutomaticIdentityCannotReusePreviousSetupDuringOutage() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.candidate = "another-device"
        fixture.response = { _, _ in throw URLError(.cannotConnectToHost) }
        await service.refresh(force: true)
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.requests == ["setup-device", "another-device"])
        #expect(fixture.saves == 0 && fixture.cache == nil)
    }

    @Test func changingAutomaticIdentityDuringLookupDiscardsLateResponse() async throws {
        let fixture = VipSetupFixture()
        var pending: CheckedContinuation<Data, Never>?
        var signedResponse = Data()
        fixture.response = { udid, nonce in
            signedResponse = try fixture.envelope(udid: udid, nonce: nonce)
            return await withCheckedContinuation { pending = $0 }
        }
        let service = fixture.makeService()
        service.verifyManually()
        await waitUntil { pending != nil }
        fixture.candidate = "another-device"
        pending?.resume(returning: signedResponse)
        await waitUntil { !service.isChecking }
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.saves == 0 && fixture.cache == nil)
    }

    @Test func changingAutomaticIdentityDuringPhysicalReadPreventsBinding() async {
        let fixture = VipSetupFixture()
        let service = fixture.makeService()
        service.startSetup()
        await service.refresh(force: true)
        fixture.connect()
        var pending: CheckedContinuation<String, Never>?
        fixture.deviceResponse = { await withCheckedContinuation { pending = $0 } }
        service.verifyManually()
        await waitUntil { pending != nil }
        fixture.candidate = "another-device"
        pending?.resume(returning: "setup-device")
        await waitUntil { !service.isChecking }
        #expect(!service.isSetupVerified && !service.isAuthorized)
        #expect(fixture.saves == 0 && fixture.cache == nil)
        #expect(!fixture.gate.allows(now: fixture.now))
    }
}
