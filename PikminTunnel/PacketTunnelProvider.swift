import NetworkExtension

/// Local loopback packet tunnel derived from LocalDevVPN by the SideStore Team.
/// See THIRD_PARTY_NOTICES.md for attribution and license terms.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelDeviceIP = "10.7.0.0"
    private var tunnelFakeIP = "10.7.0.1"
    private var tunnelSubnetMask = "255.255.255.0"
    private var deviceIPValue: UInt32 = 0
    private var fakeIPValue: UInt32 = 0
    private var isReadingPackets = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
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

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(NEVPNError(.configurationInvalid))
                return
            }
            guard error == nil else {
                completionHandler(error)
                return
            }
            self.isReadingPackets = true
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isReadingPackets = false
        completionHandler()
    }

    private func readPackets() {
        guard isReadingPackets else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isReadingPackets else { return }
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
            self.readPackets()
        }
    }

    private func ipToUInt32(_ value: String) -> UInt32 {
        let components = value.split(separator: ".").compactMap { UInt32($0) }
        guard components.count == 4, components.allSatisfy({ $0 <= 255 }) else { return 0 }
        return (components[0] << 24) | (components[1] << 16) |
            (components[2] << 8) | components[3]
    }
}
