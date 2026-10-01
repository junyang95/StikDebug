// Heartbeat behavior adapted from StikDebug/Device/JITEnableContext.swift,
// upstream 4bdfc92 (AGPL-3.0). See ThirdParty/StikDebug for provenance/license.
import Foundation
@_implementationOnly import idevice

/// Owns every heartbeat handle on one thread. Stop requests never free a handle
/// that may still be in an FFI call; that thread retains self through cleanup.
final class DebugHeartbeatSession: @unchecked Sendable {
    private let pairingFilePath: String
    private let configuration: StikJIT.Configuration
    private let progress: (String) -> Void
    private let stateLock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var stopRequested = false
    private var startupError: Error?

    init(pairingFilePath: String, configuration: StikJIT.Configuration, progress: @escaping (String) -> Void) {
        self.pairingFilePath = pairingFilePath
        self.configuration = configuration
        self.progress = progress
    }

    func start() throws {
        let thread = Thread { self.run() }
        thread.name = "JITLauncher.debugHeartbeat"
        thread.qualityOfService = .utility
        thread.start()
        guard ready.wait(timeout: .now() + 15) == .success else {
            requestStop()
            throw DeviceTools.error("Timed out starting debug heartbeat")
        }
        stateLock.lock()
        let error = startupError
        stateLock.unlock()
        if let error { throw error }
    }

    func stop() {
        requestStop()
        // Marco reads have a maximum 3-second interval. If another FFI call
        // exceeds it, leave ownership with the worker until the call returns.
        _ = finished.wait(timeout: .now() + 4)
    }

    private func requestStop() {
        stateLock.lock(); defer { stateLock.unlock() }
        stopRequested = true
    }

    private var shouldStop: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopRequested
    }

    private func run() {
        var announcedReady = false
        defer { finished.signal() }
        do {
            let tunnel = try JITSession(pairingFilePath: pairingFilePath, configuration: configuration).makeTunnel()
            defer { tunnel.free() }
            var client: OpaquePointer?
            defer { if let client { heartbeat_client_free(client) } }
            try IdeviceFFI.check("Failed to connect debug heartbeat") { heartbeat_connect_rsd(tunnel.adapter, tunnel.handshake, &client) }
            guard let client else { throw DeviceTools.error("Debug heartbeat was not returned") }
            announcedReady = true
            ready.signal()
            var interval: UInt64 = 2
            while !shouldStop {
                var suggested: UInt64 = 0
                let result = heartbeat_get_marco(client, interval, &suggested)
                if let result {
                    let error = IdeviceFFI.consume(result, fallback: "Debug heartbeat read failed")
                    guard !shouldStop else { return }
                    if error.localizedDescription.contains("HeartbeatTimeout") { interval = 2; continue }
                    if error.localizedDescription.contains("HeartbeatSleepyTime") {
                        progress("Debug heartbeat stopped: the device entered SleepyTime")
                        return
                    }
                    progress("Debug heartbeat warning: \(error.localizedDescription)")
                    return
                }
                guard !shouldStop else { return }
                interval = min(max(suggested, 1), 3)
                try IdeviceFFI.check("Failed to reply to debug heartbeat") { heartbeat_send_polo(client) }
            }
        } catch {
            if !announcedReady {
                stateLock.lock()
                startupError = error
                stateLock.unlock()
                ready.signal()
            } else if !shouldStop {
                progress("Debug heartbeat stopped: \(error.localizedDescription)")
            }
        }
    }
}
