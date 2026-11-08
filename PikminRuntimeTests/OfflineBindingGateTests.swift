import CryptoKit
import Foundation
import Testing
@testable import PikminRuntime

struct OfflineBindingGateTests {
    private let deviceA = "00008110-001234567890abcd"
    private let deviceB = "00008110-001234567890abce"

    private final class Transport {
        var events: [String] = []
        var nextID = 0
        var target: String
        var failNextSet = false
        var verify: (String) throws -> Void
        init(target: String, verify: @escaping (String) throws -> Void) {
            self.target = target
            self.verify = verify
        }
        struct Connection { let id: Int; let udid: String }
        func connect() -> Connection {
            nextID += 1
            events.append("connect:\(nextID)")
            return Connection(id: nextID, udid: target)
        }
        func session() -> LocationSimulationSession<Connection, Int> {
            .init(dependencies: .init(
                verifyBinding: { self.events.append("verify:\($0.id)"); try self.verify($0.udid) },
                makeController: { self.events.append("controller:\($0.id)"); return $0.id },
                set: { id, _, _ in
                    if self.failNextSet { self.failNextSet = false; throw CocoaError(.fileReadUnknown) }
                    self.events.append("set:\(id)")
                },
                clear: { self.events.append("clear:\($0)") },
                freeController: { self.events.append("free-controller:\($0)") },
                freeConnection: { self.events.append("free-connection:\($0.id)") }
            ))
        }
    }

    private func credential(product: String = "pikmin-helper") throws -> OfflineDeviceCredential {
        let key = P256.Signing.PrivateKey()
        let payload = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "purpose": "wow.offline-device-binding", "product": product, "udid": deviceA
        ])
        let envelope = try PropertyListSerialization.data(fromPropertyList: [
            "payload": payload.base64EncodedString(),
            "sig": try key.signature(for: payload).derRepresentation.base64EncodedString()
        ], format: .xml, options: 0)
        return try OfflineDeviceBinding._verify(envelope, expectedProduct: "pikmin-helper",
                                                trustedPublicKey: key.publicKey.x963Representation)
    }

    @Test func invalidCredentialsCannotCreateControllerOrSendCommands() throws {
        let signed = try credential()
        let untrustedKey = P256.Signing.PrivateKey()
        let untrustedPayload = Data("untrusted payload".utf8)
        let untrustedEnvelope = try PropertyListSerialization.data(fromPropertyList: [
            "payload": untrustedPayload.base64EncodedString(),
            "sig": try untrustedKey.signature(for: untrustedPayload).derRepresentation.base64EncodedString()
        ], format: .xml, options: 0)
        let verifications: [(String) throws -> Void] = [
            { _ in _ = try OfflineDeviceBinding._credential(at: nil, expectedProduct: "pikmin-helper", trustedPublicKey: Data()) },
            { _ in _ = try OfflineDeviceBinding.verify(Data("damaged".utf8), expectedProduct: "pikmin-helper") },
            { _ in _ = try OfflineDeviceBinding.verify(untrustedEnvelope, expectedProduct: "pikmin-helper") },
            { _ in _ = try credential(product: "jit-launcher") },
            { _ in try signed.validate(actualUDID: deviceB) }
        ]
        for verify in verifications {
            let transport = Transport(target: deviceA, verify: verify)
            let session = transport.session()
            #expect(throws: (any Error).self) {
                try session.set(identity: "first", latitude: 1, longitude: 2, connect: transport.connect)
            }
            #expect(transport.events == ["connect:1", "verify:1", "free-connection:1"])
        }
    }

    @Test func verifiedTargetIsTheConnectionUsedForCommands() throws {
        let signed = try credential()
        let transport = Transport(target: deviceA, verify: signed.validate)
        let session = transport.session()
        try session.set(identity: "ip-a|pairing-a", latitude: 1, longitude: 2, connect: transport.connect)
        try session.set(identity: "ip-a|pairing-a", latitude: 3, longitude: 4, connect: transport.connect)
        #expect(transport.events == ["connect:1", "verify:1", "controller:1", "set:1", "set:1"])
        session.disconnect()
    }

    @Test func changedIPOrPairingCannotReuseSuccessfulBinding() throws {
        let signed = try credential()
        for changedIdentity in ["ip-b|pairing-a", "ip-a|pairing-b"] {
            let transport = Transport(target: deviceA, verify: signed.validate)
            let session = transport.session()
            try session.set(identity: "ip-a|pairing-a", latitude: 1, longitude: 2, connect: transport.connect)
            transport.target = deviceB
            #expect(throws: OfflineDeviceBindingError.deviceMismatch) {
                try session.set(identity: changedIdentity, latitude: 1, longitude: 2, connect: transport.connect)
            }
            #expect(transport.events.filter { $0.hasPrefix("set:") } == ["set:1"])
            #expect(transport.events.contains("verify:2"))
            #expect(!transport.events.contains("controller:2"))
        }
    }

    @Test func disconnectionAndFailedSetRequireNewTargetVerification() throws {
        let signed = try credential()
        for explicitDisconnect in [true, false] {
            let transport = Transport(target: deviceA, verify: signed.validate)
            let session = transport.session()
            try session.set(identity: "same", latitude: 1, longitude: 2, connect: transport.connect)
            if explicitDisconnect { session.disconnect() } else { transport.failNextSet = true }
            transport.target = deviceB
            #expect(throws: OfflineDeviceBindingError.deviceMismatch) {
                try session.set(identity: "same", latitude: 1, longitude: 2, connect: transport.connect)
            }
            #expect(transport.events.filter { $0.hasPrefix("set:") } == ["set:1"])
            #expect(transport.events.contains("verify:2"))
            #expect(!transport.events.contains("controller:2"))
        }
    }

    @Test func recoveryWithoutCredentialDoesNotAuthorizeFutureSet() throws {
        let transport = Transport(target: deviceA, verify: { _ in throw OfflineDeviceBindingError.missingCredential })
        let session = transport.session()
        try session.clear(connect: transport.connect)
        #expect(transport.events == ["connect:1", "controller:1", "clear:1", "free-controller:1", "free-connection:1"])
        #expect(throws: OfflineDeviceBindingError.missingCredential) {
            try session.set(identity: "same", latitude: 1, longitude: 2, connect: transport.connect)
        }
        #expect(transport.events.contains("verify:2"))
        #expect(!transport.events.contains("set:1"))
        #expect(!transport.events.contains("set:2"))
    }

    @Test func existingSimulationCanBeClearedAfterCredentialBecomesUnavailable() throws {
        let signed = try credential()
        let transport = Transport(target: deviceA, verify: signed.validate)
        let session = transport.session()
        try session.set(identity: "first", latitude: 1, longitude: 2, connect: transport.connect)
        transport.verify = { _ in throw OfflineDeviceBindingError.missingCredential }
        transport.target = deviceB
        try session.clear(connect: transport.connect)
        #expect(transport.events.contains("clear:1"))
        #expect(!transport.events.contains("connect:2"))
        #expect(transport.events.last == "free-connection:1")
    }
}
