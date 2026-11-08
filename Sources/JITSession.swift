import Foundation
@_implementationOnly import idevice

final class JITSession {

    typealias Tunnel = DeviceTunnel

    private struct DebugSession {
        var remoteServer: OpaquePointer?
        var debugProxy: OpaquePointer?
        func free() {
            if let debugProxy { debug_proxy_free(debugProxy) }
            if let remoteServer { remote_server_free(remoteServer) }
        }
    }

    private let pairingFilePath: String
    private let configuration: StikJIT.Configuration

    init(pairingFilePath: String, configuration: StikJIT.Configuration) {
        self.pairingFilePath = pairingFilePath
        self.configuration = configuration
    }

    func validatePairingFile() throws {
        try tunnelFactory.validatePairingFile()
    }

    func runningProcesses() throws -> [StikJIT.RunningProcess] {
        let tunnel = try makeTunnel()
        defer { tunnel.free() }

        var remoteServer: OpaquePointer?
        defer { if let remoteServer { remote_server_free(remoteServer) } }
        try IdeviceFFI.check("failed to connect remote server") {
            remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &remoteServer)
        }
        guard let remoteServer else {
            throw StikJITError.device(code: -1, subCode: 0, message: "Remote server was not returned")
        }

        var deviceInfo: OpaquePointer?
        defer { if let deviceInfo { device_info_free(deviceInfo) } }
        try IdeviceFFI.check("failed to connect to device information service") {
            device_info_new(remoteServer, &deviceInfo)
        }
        guard let deviceInfo else {
            throw StikJITError.device(code: -1, subCode: 0, message: "Device information service was not returned")
        }

        var processes: UnsafeMutablePointer<UnsafeMutablePointer<IdeviceRunningProcess>?>?
        var count: UInt = 0
        defer { if let processes { device_info_running_processes_free(processes, count) } }
        try IdeviceFFI.check("failed to list running processes") {
            device_info_running_processes(deviceInfo, &processes, &count)
        }
        guard count > 0 else { return [] }
        guard let processes, let bufferCount = Int(exactly: count) else {
            throw StikJITError.device(code: -1, subCode: 0, message: "Invalid running process list")
        }

        // Copy the strings before releasing the FFI-owned process array.
        return UnsafeBufferPointer(start: processes, count: bufferCount).compactMap { pointer in
            guard let process = pointer?.pointee,
                  let pid = Int32(exactly: process.pid), pid > 0 else { return nil }
            let names = [process.real_app_name, process.name].compactMap { value -> String? in
                guard let value else { return nil }
                let name = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            return StikJIT.RunningProcess(pid: pid, name: names.first ?? "PID \(pid)")
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
        }
    }

    func enableJIT(targetPID: Int32,
                   script: StikJIT.Script,
                   forceScript: Bool,
                   txmPresence: TXMPresence,
                   progress: @escaping (String) -> Void,
                   cancellationCheck: @escaping () throws -> Void = {}) throws {
        try cancellationCheck()
        let txmStatus = txmPresence.isPresent.map { $0 ? "present" : "absent" } ?? "unknown"
        progress("Detected TXM: \(txmStatus).")
        let mode = try JITExecutionMode.select(forceScript: forceScript, isTXMPresent: txmPresence.isPresent)
        let tunnel = try makeTunnel(cancellationCheck: cancellationCheck)
        defer { tunnel.free() }

        let session = try connectDebugSession(over: tunnel)
        defer { session.free() }

        guard let debugProxy = session.debugProxy else { throw StikJITError.debugProxyUnavailable }

        debug_proxy_send_ack(debugProxy)
        _ = try? sendCommand("QStartNoAckMode", over: debugProxy)
        debug_proxy_set_ack_mode(debugProxy, 0)

        switch mode {
        case .script:
            progress(forceScript ? "JIT mode: script required by the caller; TXM detection does not skip it." :
                "JIT mode: script required because TXM is present.")
            // Current StikDebug keeps the paired device awake while a TXM script
            // waits for the target app's breakpoints. Give that service its own
            // tunnel and thread; it must never share the debugger's FFI handles.
            let heartbeat = DebugHeartbeatSession(pairingFilePath: pairingFilePath, configuration: configuration, progress: progress)
            do { try heartbeat.start() }
            catch let error as StikJITError {
                // Optional heartbeat transport errors are recoverable. A denied
                // new device connection must never be treated as optional.
                if case .offlineDeviceBinding = error { throw error }
                progress("Heartbeat unavailable: \(error.localizedDescription)")
            } catch { progress("Heartbeat unavailable: \(error.localizedDescription)") }
            defer { heartbeat.stop() }
            let runner = ScriptRunner(targetPID: targetPID, debugProxy: debugProxy, script: script, txmPresence: txmPresence, progress: progress,
                                      cancellationCheck: cancellationCheck)
            try withExtendedLifetime(runner) { try runner.run() }
        case .attachDetach:
            try cancellationCheck()
            try attachWithoutScript(targetPID: targetPID, debugProxy: debugProxy, progress: progress)
        }
    }

    private func attachWithoutScript(targetPID: Int32, debugProxy: OpaquePointer, progress: (String) -> Void) throws {
        progress("Attaching to pid \(targetPID). TXM is not present, so the attach alone enables JIT and the script is skipped.")
        let attachReply = try sendCommand("vAttach;\(String(targetPID, radix: 16))", over: debugProxy)
        try DebugAttachResponse.validateAttach(attachReply)
        var detached = false
        defer {
            // If detach failed, make one best-effort attempt to release the stopped
            // target before freeing the connection. Never turn a failure into success.
            if !detached { _ = try? sendCommand("D", over: debugProxy) }
        }
        let detachReply = try sendCommand("D", over: debugProxy)
        try DebugAttachResponse.validateDetach(detachReply)
        detached = true
        progress("JIT enabled (debugger attached and detached).")
    }

    private var tunnelFactory: DeviceTunnelFactory {
        DeviceTunnelFactory(pairingFilePath: pairingFilePath, configuration: configuration)
    }

    func makeTunnel(cancellationCheck: () throws -> Void = {}) throws -> Tunnel {
        try tunnelFactory.makeTunnel(cancellationCheck: cancellationCheck)
    }

    private func connectDebugSession(over tunnel: Tunnel) throws -> DebugSession {
        var session = DebugSession()
        var succeeded = false
        defer { if !succeeded { session.free() } }
        try IdeviceFFI.check("failed to connect remote server") {
            remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &session.remoteServer)
        }
        try IdeviceFFI.check("failed to connect debug proxy") {
            debug_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, &session.debugProxy)
        }
        succeeded = true
        return session
    }

    @discardableResult
    private func sendCommand(_ command: String, over debugProxy: OpaquePointer) throws -> String? {
        guard let handle = command.withCString({ debugserver_command_new($0, nil, 0) }) else { return nil }
        defer { debugserver_command_free(handle) }
        var response: UnsafeMutablePointer<CChar>?
        defer { if let response { idevice_string_free(response) } }
        try IdeviceFFI.check("debugserver command failed") {
            debug_proxy_send_command(debugProxy, handle, &response)
        }
        guard let response else { return nil }
        return String(cString: response)
    }
}
