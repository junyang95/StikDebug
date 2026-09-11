import NetworkExtension

/// Local loopback packet tunnel derived from LocalDevVPN by the SideStore Team.
/// See THIRD_PARTY_NOTICES.md for attribution and license terms.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleQueue = DispatchQueue(label: "com.jy.stikdebug.tunnel-lifecycle")
    private var generation: UInt64 = 0
    private var startCompletion: ((Error?) -> Void)?
    private var tunnelDeviceIP = "10.7.0.0"
    private var tunnelFakeIP = "10.7.0.1"
    private var tunnelSubnetMask = "255.255.255.0"
    private var deviceIPValue: UInt32 = 0
    private var fakeIPValue: UInt32 = 0
    private var isReadingPackets = false
    private var probe: LoopbackConnectProxy?
    private var mode = EmbeddedVPNMode.developerLoopback
    private var certificates: WLOCCertificateService?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        lifecycleQueue.async { [self] in start(options: options, completionHandler: completionHandler) }
    }

    private func start(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard startCompletion == nil, !isReadingPackets, probe == nil else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        generation &+= 1
        let revision = generation
        startCompletion = completionHandler
        // Probe is explicit and ephemeral: a system restart without start options is ordinary loopback.
        mode = EmbeddedVPNMode(rawValue: options?["Mode"] as? String ?? "") ?? .developerLoopback
        tunnelDeviceIP = options?["TunnelDeviceIP"] as? String ?? tunnelDeviceIP
        tunnelFakeIP = options?["TunnelFakeIP"] as? String ?? tunnelFakeIP
        tunnelSubnetMask = options?["TunnelSubnetMask"] as? String ?? tunnelSubnetMask
        deviceIPValue = ipToUInt32(tunnelDeviceIP)
        fakeIPValue = ipToUInt32(tunnelFakeIP)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIP)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIP], subnetMasks: [tunnelSubnetMask])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: tunnelDeviceIP, subnetMask: tunnelSubnetMask)
        ]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        if mode == .wlocProbe {
            let proxy = LoopbackConnectProxy()
            probe = proxy
            proxy.start(onFailure: { [weak self] error in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self, self.generation == revision else { return }
                    self.cancelTunnelWithError(error)
                }
            }) { [weak self] result in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self, self.generation == revision else { return }
                    switch result {
                    case .success(let port):
                        let proxySettings = NEProxySettings()
                        proxySettings.httpEnabled = false
                        proxySettings.httpsEnabled = true
                        proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: Int(port))
                        proxySettings.matchDomains = WLOCProbePolicy.hosts
                        settings.proxySettings = proxySettings
                        self.apply(settings, revision: revision)
                    case .failure(let error):
                        self.probe?.stop()
                        self.probe = nil
                        self.finishStart(error)
                    }
                }
            }
        } else {
            apply(settings, revision: revision)
        }
    }

    private func apply(_ settings: NEPacketTunnelNetworkSettings, revision: UInt64) {
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.lifecycleQueue.async { [weak self] in
                guard let self, self.generation == revision else { return }
                guard error == nil else {
                    self.probe?.stop()
                    self.probe = nil
                    self.finishStart(error)
                    return
                }
                self.isReadingPackets = true
                self.certificates = WLOCCertificateService()
                self.readPackets(revision: revision)
                self.finishStart(nil)
            }
        }
    }

    private func finishStart(_ error: Error?) {
        let callback = startCompletion
        startCompletion = nil
        callback?(error)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        lifecycleQueue.async { [self] in
            generation &+= 1
            isReadingPackets = false
            let cleanup = DispatchGroup()
            if let certificates {
                cleanup.enter()
                certificates.stop { cleanup.leave() }
            }
            certificates = nil
            // A late listener/settings callback must not restart packet reading after Stop.
            finishStart(NEVPNError(.configurationInvalid))
            if let probe {
                cleanup.enter()
                probe.stop { cleanup.leave() }
                self.probe = nil
            }
            cleanup.notify(queue: lifecycleQueue, execute: completionHandler)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if messageData.count < 256,
           let command = try? JSONDecoder().decode(WLOCCertificateCommand.self, from: messageData) {
            lifecycleQueue.async { [self] in
                guard isReadingPackets, let certificates else { completionHandler?(nil); return }
                certificates.handle(command) { reply in
                    completionHandler?(try? JSONEncoder().encode(reply))
                }
            }
            return
        }
        guard messageData.count < 256,
              let command = try? JSONDecoder().decode(ProbeCommand.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        lifecycleQueue.async { [self] in
            if let probe {
                probe.snapshot(reset: command == .reset) { snapshot in
                    completionHandler?(try? JSONEncoder().encode(snapshot))
                }
            } else {
                completionHandler?(try? JSONEncoder().encode(ProbeSnapshot(mode: mode)))
            }
        }
    }

    private func readPackets(revision: UInt64) {
        guard isReadingPackets, generation == revision else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.lifecycleQueue.async { [weak self] in
                guard let self, self.isReadingPackets, self.generation == revision else { return }
                var modifiedPackets = packets
                for index in modifiedPackets.indices
                where protocols[index].int32Value == AF_INET && modifiedPackets[index].count >= 20 {
                    modifiedPackets[index].withUnsafeMutableBytes { bytes in
                        guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else {
                            return
                        }
                        let source = UInt32(bigEndian: pointer[3])
                        let destination = UInt32(bigEndian: pointer[4])
                        if source == self.deviceIPValue {
                            pointer[3] = self.fakeIPValue.bigEndian
                        }
                        if destination == self.fakeIPValue {
                            pointer[4] = self.deviceIPValue.bigEndian
                        }
                    }
                }
                self.packetFlow.writePackets(modifiedPackets, withProtocols: protocols)
                self.readPackets(revision: revision)
            }
        }
    }

    private func ipToUInt32(_ value: String) -> UInt32 {
        let components = value.split(separator: ".").compactMap { UInt32($0) }
        guard components.count == 4, components.allSatisfy({ $0 <= 255 }) else { return 0 }
        return (components[0] << 24) | (components[1] << 16) |
            (components[2] << 8) | components[3]
    }
}
