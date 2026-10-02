import Combine
import Foundation
import NetworkExtension

/// Manages only the packet-tunnel profiles belonging to this app's extension.
/// Every preference operation is serialized on the main actor; loading never
/// installs a profile or starts a VPN without the user's Connect action.
@MainActor
final class LocalVPNManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var isConnected: Bool { status == .connected }

    var canConnect: () -> Bool = { true }

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var expectsConnection = false
    private var requestGeneration: UInt64 = 0

    private var providerBundleIdentifier: String? {
        Bundle.main.bundleIdentifier.map { $0 + ".TunnelProv" }
    }

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                guard let self, connection === self.manager?.connection else { return }
                self.updateStatus(from: connection)
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        #if targetEnvironment(simulator)
        status = .invalid
        #else
        do {
            manager = try await loadOwnedManager()
            if let manager {
                updateStatus(from: manager.connection)
            } else {
                status = .invalid
                expectsConnection = false
            }
        } catch {
            report("vpn.load_failed", error: error)
        }
        #endif
    }

    func connect() async {
        guard !isBusy else { return }
        guard canConnect() else { report("wifi.required"); return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        #if targetEnvironment(simulator)
        report("vpn.device_required")
        #else
        guard let providerBundleIdentifier else {
            report("vpn.configuration_missing")
            return
        }

        let selectedManager: NETunnelProviderManager
        do {
            selectedManager = try await loadOwnedManager() ?? NETunnelProviderManager()
            manager = selectedManager
            status = selectedManager.connection.status
        } catch {
            report("vpn.load_failed", error: error)
            return
        }

        switch status {
        case .connected, .connecting, .reasserting:
            return
        case .disconnecting:
            report("vpn.disconnecting")
            return
        default:
            break
        }

        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = CIDREndpoint(TunnelConstants.defaultPeerIP).ip
        tunnelProtocol.providerConfiguration = [
            TunnelConstants.ifaceIPConfigurationKey: TunnelConstants.defaultIfaceIP,
            TunnelConstants.peerIPConfigurationKey: TunnelConstants.defaultPeerIP
        ]
        tunnelProtocol.disconnectOnSleep = false
        selectedManager.protocolConfiguration = tunnelProtocol
        selectedManager.localizedDescription = NSLocalizedString("vpn.profile_name", comment: "Local VPN profile name")
        selectedManager.isEnabled = true
        selectedManager.isOnDemandEnabled = false
        selectedManager.onDemandRules = []

        do {
            // A newly saved profile must be reloaded before its connection can start.
            try await save(selectedManager)
            try await reload(selectedManager)
        } catch {
            status = selectedManager.connection.status
            report("vpn.save_failed", error: error)
            return
        }

        guard let session = selectedManager.connection as? NETunnelProviderSession else {
            report("vpn.configuration_missing")
            return
        }
        guard canConnect() else { report("wifi.required"); return }
        do {
            requestGeneration &+= 1
            expectsConnection = true
            try session.startTunnel(options: nil)
            // Reflect the OS status only: startTunnel returning is not success.
            status = session.status
        } catch {
            expectsConnection = false
            status = session.status
            report("vpn.start_failed", error: error)
        }
        #endif
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        #if targetEnvironment(simulator)
        report("vpn.device_required")
        #else
        do {
            requestGeneration &+= 1
            expectsConnection = false
            // Reload only our own profile; never use NEVPNManager.shared().
            manager = try await loadOwnedManager()
            guard let manager else {
                status = .invalid
                return
            }
            expectsConnection = false
            manager.connection.stopVPNTunnel()
            status = manager.connection.status
        } catch {
            report("vpn.stop_failed", error: error)
        }
        #endif
    }

    private func updateStatus(from connection: NEVPNConnection) {
        status = connection.status
        if [.connected, .connecting, .reasserting].contains(status) {
            expectsConnection = true
            if status == .connected { errorMessage = nil }
            return
        }
        guard (status == .disconnected || status == .invalid), expectsConnection else { return }
        expectsConnection = false
        let generation = requestGeneration
        // Extension launch failures are asynchronous; startTunnel() can return
        // successfully before iOS rejects or terminates the provider.
        connection.fetchLastDisconnectError { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.requestGeneration == generation,
                      connection === self.manager?.connection,
                      !self.expectsConnection,
                      self.status == .disconnected || self.status == .invalid else { return }
                self.report("vpn.connection_lost", error: error)
            }
        }
    }

    private func loadOwnedManager() async throws -> NETunnelProviderManager? {
        guard let providerBundleIdentifier else { return nil }
        let managers = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
        let owned = managers.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        }
        // Prefer a currently active owned profile if an older install left duplicates.
        return owned.first {
            [.connected, .connecting, .reasserting, .disconnecting].contains($0.connection.status)
        } ?? owned.first
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func report(_ key: String, error: Error? = nil) {
        let message = NSLocalizedString(key, comment: "VPN status or error")
        errorMessage = error.map { message + "\n" + $0.localizedDescription } ?? message
    }
}
