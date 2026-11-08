import CryptoKit
import Darwin
import Foundation
@_implementationOnly import idevice

public enum StikJIT {
    public struct Configuration {
        var deviceAddress = "127.0.0.1"
        var rsdPort: UInt16 = 49152
        public static var `default`: Self { .init() }
    }
}
@_silgen_name("binding_test_reset") private func reset()
@_silgen_name("binding_test_count") private func count(_ event: Int32) -> Int32
@_silgen_name("binding_test_tunnel_mode") private func tunnelMode(_ mode: Int32)
@_silgen_name("binding_test_identity_mode") private func identityMode(_ mode: Int32)
@_silgen_name("binding_test_udid") private func actualUDID(_ value: UnsafePointer<CChar>)
@_silgen_name("binding_test_adapter") private func adapterID() -> UInt
@_silgen_name("binding_test_handshake") private func handshakeID() -> UInt

@main enum DeviceTunnelBindingTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairing = directory.appendingPathComponent("pairing.plist")
        // Deliberately contains a different purported ID: identity must come from
        // the connected lockdown service, never this local connection credential.
        try Data("claimedUDID=ffffffffffffffffffffffffffffffffffffffff".utf8).write(to: pairing)
        let key = P256.Signing.PrivateKey()
        let payload = Data(#"{"schema":1,"purpose":"wow.offline-device-binding","product":"jit-launcher","udid":"00008110-000a010203040506"}"#.utf8)
        let signature = try key.signature(for: payload).derRepresentation
        let envelope = try PropertyListSerialization.data(fromPropertyList: ["payload": payload.base64EncodedString(), "sig": signature.base64EncodedString()], format: .xml, options: 0)
        func verifiedCredential() throws -> OfflineDeviceCredential {
            try OfflineDeviceBinding._verify(envelope, expectedProduct: "jit-launcher", trustedPublicKey: key.publicKey.x963Representation)
        }
        let approved = DeviceTunnelFactory(pairingFilePath: pairing.path, configuration: .default, credential: verifiedCredential)
        let production = DeviceTunnelFactory(pairingFilePath: pairing.path, configuration: .default)
        var checks = 0
        func run(_ name: String, _ body: () throws -> Void) rethrows {
            reset(); "00008110-000A010203040506".withCString(actualUDID)
            try body(); checks += 1; print("PASS \(name)")
        }
        func rejects(_ reason: OfflineDeviceBindingFailure, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected \(reason)") }
            catch StikJITError.offlineDeviceBinding(let actual) { precondition(actual == reason, "\(actual) != \(reason)") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        try run("Verified credential binds the same actual paired tunnel before use") {
            let tunnel = try approved.makeTunnel()
            precondition(count(0) == 1 && count(3) == 1 && count(4) == 1 && count(12) == 1)
            precondition(UInt(bitPattern: tunnel.adapter!) == adapterID())
            precondition(UInt(bitPattern: tunnel.handshake!) == handshakeID())
            precondition(count(5) == 1 && count(11) == 1)
            tunnel.free(); precondition(count(1) == 1 && count(2) == 1)
        }
        run("Missing credential denies production tunnel and frees paired handles") {
            rejects(.missingCredential) { _ = try production.makeTunnel() }
            precondition(count(0) == 1 && count(1) == 1 && count(2) == 1 && count(3) == 0)
        }
        run("Connected device mismatch fails even when the pairing file exists") {
            "00008110-000a010203040507".withCString(actualUDID)
            rejects(.deviceMismatch) { _ = try approved.makeTunnel() }
            precondition(count(4) == 1 && count(1) == 1 && count(2) == 1)
        }
        try run("Each new tunnel re-verifies credentials and connected identity") {
            var loads = 0
            let factory = DeviceTunnelFactory(pairingFilePath: pairing.path, configuration: .default, credential: { loads += 1; return try verifiedCredential() })
            try factory.makeTunnel().free()
            "00008110-000a010203040507".withCString(actualUDID)
            rejects(.deviceMismatch) { _ = try factory.makeTunnel() }
            precondition(loads == 2 && count(0) == 2 && count(4) == 2 && count(1) == 2)
        }
        for (error, reason) in [(OfflineDeviceBindingError.missingCredential, OfflineDeviceBindingFailure.missingCredential), (.invalidCredential, .invalidCredential), (.invalidSignature, .invalidSignature), (.unsupportedCredential, .unsupportedCredential), (.wrongProduct, .wrongProduct), (.invalidDeviceIdentifier, .invalidDeviceIdentifier), (.deviceMismatch, .deviceMismatch)] {
            run("Credential failure \(reason) denies before any device action") {
                let factory = DeviceTunnelFactory(pairingFilePath: pairing.path, configuration: .default, credential: { throw error })
                rejects(reason) { _ = try factory.makeTunnel() }
                precondition(count(1) == 1 && count(2) == 1 && count(3) == 0 && count(6) == 0)
            }
        }
        for mode: Int32 in 1...5 {
            run("Unavailable or malformed lockdown identity \(mode) fails closed") {
                identityMode(mode)
                rejects(mode < 4 ? .identityUnavailable : .invalidDeviceIdentifier) { _ = try approved.makeTunnel() }
                precondition(count(1) == 1 && count(2) == 1)
            }
        }
        for text in ["", " 00008110-000a010203040506", "000081100000a010203040506", "00008110-000a01020304050z"] {
            run("Invalid actual identifier is rejected: \(text)") {
                text.withCString(actualUDID)
                rejects(.invalidDeviceIdentifier) { _ = try approved.makeTunnel() }
            }
        }
        for checkpoint in 1...5 {
            run("Cancellation at authorization boundary \(checkpoint) never returns a tunnel") {
                var calls = 0
                do {
                    _ = try approved.makeTunnel(cancellationCheck: { calls += 1; if calls == checkpoint { throw CancellationError() } })
                    preconditionFailure("Cancellation ignored")
                } catch is CancellationError {} catch { preconditionFailure("Unexpected \(error)") }
                precondition(calls == checkpoint)
                let opened: Int32 = checkpoint == 1 ? 0 : 1
                precondition(count(0) == opened && count(1) == opened && count(2) == opened)
            }
        }
        for mode: Int32 in 1...3 {
            run("Incomplete paired handshake \(mode) never reaches identity or protected service") {
                tunnelMode(mode)
                do { _ = try approved.makeTunnel(); preconditionFailure("Handshake accepted") }
                catch StikJITError.device {} catch { preconditionFailure("Unexpected \(error)") }
                precondition(count(3) == 0 && count(6) == 0 && count(1) == (mode == 1 ? 0 : 1))
            }
        }
        try run("Pairing-file setup remains accessible without an offline credential") {
            try production.validatePairingFile()
            precondition(count(0) == 0 && count(3) == 0 && count(11) == 1)
        }
        try run("Public resume API remains available without a credential and only sends SIGCONT") {
            try StikJIT.resumeProcess(pid: 4242, pairingFile: pairing)
            precondition(count(7) == 1 && count(8) == SIGCONT && count(13) == 4242)
            precondition(count(3) == 0 && count(1) == 1 && count(2) == 1)
        }
        try run("Public clear-location API works without a credential and closes recovery connection") {
            try StikJIT.clearSimulatedLocation(pairingFile: pairing)
            precondition(count(9) == 1 && count(10) == 0 && count(3) == 0 && count(1) == 1 && count(2) == 1)
        }
        run("Location setting cannot reuse a cleared recovery connection to bypass binding") {
            do { try StikJIT.clearSimulatedLocation(pairingFile: pairing) } catch { preconditionFailure("\(error)") }
            rejects(.missingCredential) { try StikJIT.setSimulatedLocation(latitude: 35, longitude: 139, pairingFile: pairing) }
            precondition(count(9) == 1 && count(10) == 0 && count(0) == 2 && count(1) == 2)
        }
        try run("Replacing same-size pairing bytes with unchanged mtime rechecks the actual device") {
            let controller = DeviceLocationController(makeProtectedTunnel: { file, config in
                try DeviceTunnelFactory(pairingFilePath: file.path, configuration: config, credential: verifiedCredential).makeTunnel()
            })
            try controller.set(latitude: 35, longitude: 139, pairingFile: pairing, configuration: .default)
            let modified = try pairing.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            let original = try Data(contentsOf: pairing)
            try Data(repeating: 65, count: original.count).write(to: pairing)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: pairing.path)
            "00008110-000a010203040507".withCString(actualUDID)
            rejects(.deviceMismatch) { try controller.set(latitude: 36, longitude: 140, pairingFile: pairing, configuration: .default) }
            precondition(count(0) == 2 && count(4) == 2 && count(10) == 1 && count(1) == 2)
        }
        try run("Existing simulated location clears after pairing deletion and endpoint change") {
            let controller = DeviceLocationController(makeProtectedTunnel: { file, config in
                try DeviceTunnelFactory(pairingFilePath: file.path, configuration: config, credential: verifiedCredential).makeTunnel()
            })
            try controller.set(latitude: 35, longitude: 139, pairingFile: pairing, configuration: .default)
            try FileManager.default.removeItem(at: pairing)
            var changed = StikJIT.Configuration.default
            changed.deviceAddress = "127.0.0.2"
            try controller.clear(pairingFile: pairing, configuration: changed)
            precondition(count(0) == 1 && count(9) == 1 && count(10) == 1 && count(1) == 1 && count(2) == 1)
        }
        run("Invalid recovery PID never reaches the tunnel") {
            do { try StikJIT.resumeProcess(pid: 0, pairingFile: pairing); preconditionFailure("Invalid PID") }
            catch StikJITError.device {} catch { preconditionFailure("Unexpected \(error)") }
            precondition(count(0) == 0 && count(7) == 0)
        }
        print("\(checks) device tunnel binding and recovery tests passed")
    }
}
