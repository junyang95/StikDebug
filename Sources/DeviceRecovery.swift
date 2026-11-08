import CryptoKit
import Foundation
import Darwin
@_implementationOnly import idevice

private func recoveryError(_ message: String) -> StikJITError {
    .device(code: -1, subCode: 0, message: message)
}

extension StikJIT {
    /// Always permits recovery of a suspended process through a real paired
    /// connection. This API can only send SIGCONT, never another signal.
    public static func resumeProcess(pid: Int32, pairingFile: URL, configuration: Configuration = .default) throws {
        guard pid > 0, pid != getpid() else { throw recoveryError("Refusing to resume an invalid process or the launcher itself") }
        let tunnel = try DeviceTunnelFactory(pairingFilePath: pairingFile.path, configuration: configuration).makeRecoveryTunnel()
        defer { tunnel.free() }
        var client: OpaquePointer?
        defer { if let client { app_service_free(client) } }
        try IdeviceFFI.check("Failed to connect recovery application service") {
            app_service_connect_rsd(tunnel.adapter, tunnel.handshake, &client)
        }
        guard let client else { throw recoveryError("Recovery application service was not returned") }
        var response: UnsafeMutablePointer<SignalResponseC>?
        defer { if let response { app_service_free_signal_response(response) } }
        try IdeviceFFI.check("Failed to resume process \(pid)") {
            app_service_send_signal(client, UInt32(pid), UInt32(SIGCONT), &response)
        }
        guard let response, response.pointee.pid == UInt32(pid), response.pointee.signal == UInt32(SIGCONT) else {
            throw recoveryError("The device did not confirm process resumption")
        }
    }

    public static func setSimulatedLocation(latitude: Double, longitude: Double, pairingFile: URL, configuration: Configuration = .default) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw recoveryError("Latitude or longitude is outside its valid range")
        }
        try DeviceLocationController.shared.set(latitude: latitude, longitude: longitude, pairingFile: pairingFile, configuration: configuration)
    }

    public static func clearSimulatedLocation(pairingFile: URL, configuration: Configuration = .default) throws {
        try DeviceLocationController.shared.clear(pairingFile: pairingFile, configuration: configuration)
    }
}

final class DeviceLocationController {
    static let shared = DeviceLocationController()
    private let lock = NSLock()
    private let makeProtectedTunnel: (URL, StikJIT.Configuration) throws -> DeviceTunnel

    init(makeProtectedTunnel: @escaping (URL, StikJIT.Configuration) throws -> DeviceTunnel = {
        try DeviceTunnelFactory(pairingFilePath: $0.path, configuration: $1).makeTunnel()
    }) {
        self.makeProtectedTunnel = makeProtectedTunnel
    }
    private var tunnel: DeviceTunnel?
    private var server: OpaquePointer?
    private var client: OpaquePointer?
    private var identity: String?

    func set(latitude: Double, longitude: Double, pairingFile: URL, configuration: StikJIT.Configuration) throws {
        lock.lock(); defer { lock.unlock() }
        try connect(pairingFile, configuration)
        do {
            try IdeviceFFI.check("Failed to set simulated location") { location_simulation_set(client, latitude, longitude) }
        } catch {
            cleanup()
            throw error
        }
    }

    func clear(pairingFile: URL, configuration: StikJIT.Configuration) throws {
        lock.lock(); defer { lock.unlock() }
        defer { cleanup() }
        try connectForRecovery(pairingFile, configuration)
        try IdeviceFFI.check("Failed to clear simulated location") { location_simulation_clear(client) }
    }

    private func connectionKey(_ pairingFile: URL, _ configuration: StikJIT.Configuration) throws -> String {
        // A pairing record can be overwritten without changing its size or mtime.
        let digest = SHA256.hash(data: try Data(contentsOf: pairingFile)).map { String(format: "%02x", $0) }.joined()
        return "\(pairingFile.path)|\(digest)|\(configuration.deviceAddress)|\(configuration.rsdPort)"
    }

    private func connect(_ pairingFile: URL, _ configuration: StikJIT.Configuration) throws {
        let key = try connectionKey(pairingFile, configuration)
        if client != nil, identity == key { return }
        cleanup()
        let tunnel = try makeProtectedTunnel(pairingFile, configuration)
        try connectServices(over: tunnel, key: key)
    }

    private func connectForRecovery(_ pairingFile: URL, _ configuration: StikJIT.Configuration) throws {
        // Restore the device whose location we actually changed, even if its
        // pairing file was removed or the selected endpoint has since changed.
        if client != nil { return }
        cleanup()
        let tunnel = try DeviceTunnelFactory(pairingFilePath: pairingFile.path, configuration: configuration).makeRecoveryTunnel()
        try connectServices(over: tunnel, key: "recovery")
    }

    private func connectServices(over tunnel: DeviceTunnel, key: String) throws {
        self.tunnel = tunnel
        do {
            try IdeviceFFI.check("Failed to connect location remote server") { remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &server) }
            guard server != nil else { throw recoveryError("Location remote server was not returned") }
            try IdeviceFFI.check("Failed to connect location simulation") { location_simulation_new(server, &client) }
            guard client != nil else { throw recoveryError("Location simulation service was not returned") }
            identity = key
        } catch {
            cleanup()
            throw error
        }
    }

    private func cleanup() {
        // location_simulation_new borrows the RemoteServer. The shipped FFI's
        // controller destructor only deallocates its 16-byte wrapper; keep the
        // server alive until the controller is freed, then release it separately.
        if let client { location_simulation_free(client) }
        if let server { remote_server_free(server) }
        tunnel?.free()
        client = nil; server = nil; tunnel = nil; identity = nil
    }
}
