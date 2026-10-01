// Service/metadata behavior follows StikDebug main 4bdfc92:
// Device/IdeviceFFIBridge.swift and Device/JITEnableContext.swift (AGPL-3.0).
// Scoped ownership, validation and public API are adapted for this framework.
// See ThirdParty/StikDebug for the retained license and source provenance.
import Foundation
import Darwin
@_implementationOnly import idevice

extension StikJIT {
    /// Reads the actual installation database, including get-task-allow. Icons
    /// are fetched separately so a large library never performs N serial requests.
    public static func installedApplications(pairingFile: URL, configuration: Configuration = .default) throws -> [InstalledApplication] {
        try DeviceTools.withTunnel(pairingFile, configuration) { tunnel in
            try DeviceTools.withClient("installation proxy", connect: {
                installation_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
            }, free: installation_proxy_client_free) { client in
                var raw: UnsafeMutableRawPointer?
                var count = 0
                defer {
                    if let raw, count >= 0 {
                        let pointers = raw.assumingMemoryBound(to: plist_t?.self)
                        for index in 0..<count { plist_free(pointers[index]) }
                        idevice_data_free(raw.assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
                    }
                }
                try IdeviceFFI.check("Failed to list installed applications") {
                    installation_proxy_get_apps(client, nil, nil, 0, &raw, &count)
                }
                guard count >= 0, count <= 100_000 else { throw DeviceTools.error("Invalid application count") }
                guard count > 0 else { return [] }
                guard let raw else { throw DeviceTools.error("Missing application list") }
                let pointers = raw.assumingMemoryBound(to: plist_t?.self)
                return try InstalledApplicationReader.applications(count: count) { pointers[$0] }
            }
        }
    }

    public static func applicationIcon(bundleIdentifier: String, pairingFile: URL, configuration: Configuration = .default) throws -> Data {
        try DeviceTools.validateIdentifier(bundleIdentifier)
        return try DeviceTools.withTunnel(pairingFile, configuration) { tunnel in
            try DeviceTools.withClient("SpringBoard services", connect: {
                springboard_services_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
            }, free: springboard_services_free) { client in
                var bytes: UnsafeMutableRawPointer?
                var count = 0
                defer { if let bytes { free(bytes) } }
                try IdeviceFFI.check("Failed to load application icon") {
                    bundleIdentifier.withCString { springboard_services_get_icon(client, $0, &bytes, &count) }
                }
                guard let bytes, count > 0, count <= 8 * 1024 * 1024 else { throw DeviceTools.error("Invalid application icon") }
                return Data(bytes: bytes, count: count)
            }
        }
    }

    /// Suspended launch is intended for an immediate debugger attach. The caller
    /// must resume the returned PID if the following attach fails.
    public static func launchApplication(bundleIdentifier: String, pairingFile: URL, configuration: Configuration = .default, startSuspended: Bool = false) throws -> Int32 {
        try DeviceTools.validateIdentifier(bundleIdentifier)
        return try DeviceTools.withRemoteServer(pairingFile, configuration) { server in
            try DeviceTools.withClient("process control", connect: { process_control_new(server, $0) }, free: process_control_free) { client in
                var pid: UInt64 = 0
                try IdeviceFFI.check("Failed to launch application") {
                    bundleIdentifier.withCString {
                        // Preserve a running app when bringing it to the foreground.
                        process_control_launch_app(client, $0, nil, 0, nil, 0, startSuspended, false, &pid)
                    }
                }
                guard let value = Int32(exactly: pid), value > 0 else { throw DeviceTools.error("Device returned an invalid process identifier") }
                return value
            }
        }
    }

    public static func terminateProcess(pid: Int32, pairingFile: URL, configuration: Configuration = .default) throws {
        try DeviceTools.sendSignal(SIGKILL, pid: pid, pairingFile: pairingFile, configuration: configuration)
    }

    public static func resumeProcess(pid: Int32, pairingFile: URL, configuration: Configuration = .default) throws {
        try DeviceTools.sendSignal(SIGCONT, pid: pid, pairingFile: pairingFile, configuration: configuration)
    }

    public static func deviceDetails(pairingFile: URL, configuration: Configuration = .default) throws -> [String: String] {
        try DeviceTools.withTunnel(pairingFile, configuration) { tunnel in
            try DeviceTools.withClient("lockdown", connect: {
                lockdownd_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
            }, free: lockdownd_client_free) { client in
                var plist: plist_t?
                defer { plist_free(plist) }
                try IdeviceFFI.check("Failed to read device details") { lockdownd_get_value(client, nil, nil, &plist) }
                guard let plist else { throw DeviceTools.error("Device details were not returned") }
                return try DeviceTools.dictionary(plist).mapValues(DeviceMetadata.displayValue)
            }
        }
    }

    public static func provisioningProfiles(pairingFile: URL, configuration: Configuration = .default) throws -> [ProvisioningProfile] {
        try DeviceTools.withMisagent(pairingFile, configuration) { client in
            var pointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
            var lengths: UnsafeMutablePointer<Int>?
            var count = 0
            defer {
                if let pointers, let lengths { misagent_free_profiles(pointers, lengths, count) }
            }
            try IdeviceFFI.check("Failed to list provisioning profiles") { misagent_copy_all(client, &pointers, &lengths, &count) }
            guard count >= 0, count <= 10_000 else { throw DeviceTools.error("Invalid profile count") }
            guard count > 0 else { return [] }
            guard let pointers, let lengths else { throw DeviceTools.error("Profiles were not returned") }
            return try (0..<count).map { index in
                guard let pointer = pointers[index], lengths[index] > 0, lengths[index] <= DeviceMetadata.maximumProfileSize else {
                    throw DeviceTools.error("Invalid provisioning profile data")
                }
                return try DeviceMetadata.profile(Data(bytes: pointer, count: lengths[index]))
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public static func installProfile(data: Data, pairingFile: URL, configuration: Configuration = .default) throws {
        // Extract only display metadata here. Misagent verifies the signed profile.
        _ = try DeviceMetadata.profile(data)
        try DeviceTools.withMisagent(pairingFile, configuration) { client in
            try IdeviceFFI.check("Failed to install provisioning profile") {
                data.withUnsafeBytes { misagent_install(client, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
            }
        }
    }

    public static func removeProfile(identifier: String, pairingFile: URL, configuration: Configuration = .default) throws {
        guard UUID(uuidString: identifier) != nil else { throw DeviceTools.error("Invalid provisioning profile UUID") }
        try DeviceTools.withMisagent(pairingFile, configuration) { client in
            try IdeviceFFI.check("Failed to remove provisioning profile") { identifier.withCString { misagent_remove(client, $0) } }
        }
    }

    public static func setSimulatedLocation(latitude: Double, longitude: Double, pairingFile: URL, configuration: Configuration = .default) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw DeviceTools.error("Latitude or longitude is outside its valid range")
        }
        try DeviceLocationController.shared.set(latitude: latitude, longitude: longitude, pairingFile: pairingFile, configuration: configuration)
    }

    public static func clearSimulatedLocation(pairingFile: URL, configuration: Configuration = .default) throws {
        try DeviceLocationController.shared.clear(pairingFile: pairingFile, configuration: configuration)
    }
}

enum DeviceTools {
    static func error(_ message: String) -> StikJITError { .device(code: -1, subCode: 0, message: message) }

    static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 1024, !identifier.contains("\0"),
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw error("Invalid application identifier")
        }
    }

    static func withTunnel<T>(_ pairingFile: URL, _ configuration: StikJIT.Configuration, _ body: (JITSession.Tunnel) throws -> T) throws -> T {
        let tunnel = try JITSession(pairingFilePath: pairingFile.path, configuration: configuration).makeTunnel()
        defer { tunnel.free() }
        return try body(tunnel)
    }

    static func withClient<T>(_ name: String, connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?, free: (OpaquePointer?) -> Void, _ body: (OpaquePointer) throws -> T) throws -> T {
        var client: OpaquePointer?
        defer { if let client { free(client) } }
        try IdeviceFFI.check("Failed to connect to \(name)") { connect(&client) }
        guard let client else { throw error("\(name) did not return a connection") }
        return try body(client)
    }

    static func withRemoteServer<T>(_ pairingFile: URL, _ configuration: StikJIT.Configuration, _ body: (OpaquePointer) throws -> T) throws -> T {
        try withTunnel(pairingFile, configuration) { tunnel in
            try withClient("remote server", connect: { remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, $0) }, free: remote_server_free, body)
        }
    }

    static func withMisagent<T>(_ pairingFile: URL, _ configuration: StikJIT.Configuration, _ body: (OpaquePointer) throws -> T) throws -> T {
        try withTunnel(pairingFile, configuration) { tunnel in
            try withClient("profile service", connect: { misagent_connect_rsd(tunnel.adapter, tunnel.handshake, $0) }, free: misagent_client_free, body)
        }
    }

    static func sendSignal(_ signal: Int32, pid: Int32, pairingFile: URL, configuration: StikJIT.Configuration) throws {
        guard pid > 0, pid != getpid() else { throw error("Refusing to signal an invalid process or the launcher itself") }
        try withTunnel(pairingFile, configuration) { tunnel in
            try withClient("application service", connect: { app_service_connect_rsd(tunnel.adapter, tunnel.handshake, $0) }, free: app_service_free) { client in
                var response: UnsafeMutablePointer<SignalResponseC>?
                defer { if let response { app_service_free_signal_response(response) } }
                try IdeviceFFI.check("Failed to send signal to process \(pid)") { app_service_send_signal(client, UInt32(pid), UInt32(signal), &response) }
                guard let response, response.pointee.pid == UInt32(pid), response.pointee.signal == UInt32(signal) else {
                    throw error("The device did not confirm the process signal")
                }
            }
        }
    }

    static func dictionary(_ plist: plist_t) throws -> [String: Any] {
        var bytes: UnsafeMutablePointer<CChar>?
        var count: UInt32 = 0
        defer { if let bytes { plist_mem_free(bytes) } }
        guard plist_to_bin(plist, &bytes, &count) == PLIST_ERR_SUCCESS, let bytes, count > 0 else {
            throw error("Could not serialize device metadata")
        }
        guard let dictionary = try PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(count)), format: nil) as? [String: Any] else {
            throw error("Device metadata is not a dictionary")
        }
        return dictionary
    }
}

private final class DeviceLocationController {
    static let shared = DeviceLocationController()
    private let lock = NSLock()
    private var tunnel: JITSession.Tunnel?
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
        try connect(pairingFile, configuration)
        try IdeviceFFI.check("Failed to clear simulated location") { location_simulation_clear(client) }
    }

    private func connect(_ pairingFile: URL, _ configuration: StikJIT.Configuration) throws {
        let modified = try pairingFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(pairingFile.path)|\(modified)|\(configuration.deviceAddress)|\(configuration.rsdPort)"
        if client != nil, identity == key { return }
        cleanup()
        do {
            let tunnel = try JITSession(pairingFilePath: pairingFile.path, configuration: configuration).makeTunnel()
            self.tunnel = tunnel
            try IdeviceFFI.check("Failed to connect location remote server") { remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &server) }
            guard server != nil else { throw DeviceTools.error("Location remote server was not returned") }
            try IdeviceFFI.check("Failed to connect location simulation") { location_simulation_new(server, &client) }
            guard client != nil else { throw DeviceTools.error("Location simulation service was not returned") }
            identity = key
        } catch {
            cleanup()
            throw error
        }
    }

    private func cleanup() {
        if let client { location_simulation_free(client) }
        if let server { remote_server_free(server) }
        tunnel?.free()
        client = nil; server = nil; tunnel = nil; identity = nil
    }
}

/// A single-use device log reader. `cancel` suppresses callbacks immediately.
/// The bundled FFI exposes no interrupt/timeout for syslog_relay_next, so run()
/// returns only after the pending read finishes or the device disconnects. Keep
/// the session alive and disallow a second reader while waiting for that return.
/// Handles are freed exclusively on the reader thread, never in cancel().
public final class DeviceLogSession: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var started = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public func run(pairingFile: URL, configuration: StikJIT.Configuration = .default, line: @escaping @Sendable (String) -> Void) throws {
        lock.lock()
        guard !started else { lock.unlock(); throw DeviceTools.error("This log session has already been used") }
        started = true
        let shouldStart = !cancelled
        lock.unlock()
        guard shouldStart else { return }
        do {
            try DeviceTools.withTunnel(pairingFile, configuration) { tunnel in
                guard !isCancelled else { return }
                try DeviceTools.withClient("system log relay", connect: {
                    syslog_relay_connect_rsd(tunnel.adapter, tunnel.handshake, $0)
                }, free: syslog_relay_client_free) { client in
                    while !isCancelled {
                        var message: UnsafeMutablePointer<CChar>?
                        let error = syslog_relay_next(client, &message)
                        let text = message.map { String(cString: $0) }
                        if let message { idevice_string_free(message) }
                        if let error { throw IdeviceFFI.consume(error, fallback: "System log read failed") }
                        if let text {
                            lock.lock()
                            if !cancelled { line(text) }
                            lock.unlock()
                        }
                    }
                }
            }
        } catch {
            if !isCancelled { throw error }
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
