//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  Created by Stossy11 on 28/03/2025.
//
// Based on LocalDevVPN, commit af3fd69. See ThirdParty/LocalDevVPN.
// Integration changes: validate configuration, synchronize lifecycle, and swap
// IPv4 addresses bytewise to avoid assuming Data's storage is UInt32-aligned.

import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0
    private var isRunning = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lifecycleLock.lock()
        generation &+= 1
        let sessionGeneration = generation
        isRunning = false
        lifecycleLock.unlock()

        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let interfaceInput = options?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? configuration?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? TunnelConstants.defaultIfaceIP
        let peerInput = options?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? configuration?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? TunnelConstants.defaultPeerIP

        let addresses: (iface: CIDRParseResult, peer: CIDRParseResult)
        do {
            addresses = try CIDRValidator.shared.validatePair(
                tunnelIfaceInput: interfaceInput,
                tunnelPeerInput: peerInput,
                allowIntermediateAddresses: TunnelConstants.defaultAllowIntermediateAddresses
            )
        } catch {
            completionHandler(error)
            return
        }

        let ipv4 = NEIPv4Settings(addresses: [addresses.iface.ip], subnetMasks: [addresses.iface.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: addresses.peer.ip, subnetMask: addresses.peer.subnetMask)]
        ipv4.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: addresses.peer.ip)
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            self.lifecycleLock.lock()
            let isCurrent = self.generation == sessionGeneration
            if isCurrent { self.isRunning = true }
            self.lifecycleLock.unlock()
            guard isCurrent else {
                completionHandler(NSError(
                    domain: "JITLauncher.Tunnel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Tunnel startup was cancelled."]
                ))
                return
            }
            self.readPackets(generation: sessionGeneration)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycleLock.lock()
        isRunning = false
        generation &+= 1
        lifecycleLock.unlock()
        completionHandler()
    }

    private func isActive(_ expectedGeneration: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isRunning && generation == expectedGeneration
    }

    private func readPackets(generation: UInt64) {
        guard isActive(generation) else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isActive(generation) else { return }
            var reflectedPackets: [Data] = []
            var reflectedProtocols: [NSNumber] = []
            for (packet, family) in zip(packets, protocols) {
                guard family.int32Value == AF_INET, packet.count >= 20 else { continue }
                var reflected = packet
                let valid = reflected.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
                    guard bytes[0] >> 4 == 4 else { return false }
                    let headerLength = Int(bytes[0] & 0x0F) * 4
                    guard headerLength >= 20, bytes.count >= headerLength else { return false }
                    // Swapping addresses preserves the IPv4 and TCP/UDP checksum sums.
                    for offset in 0..<4 {
                        let sourceByte = bytes[12 + offset]
                        bytes[12 + offset] = bytes[16 + offset]
                        bytes[16 + offset] = sourceByte
                    }
                    return true
                }
                if valid {
                    reflectedPackets.append(reflected)
                    reflectedProtocols.append(family)
                }
            }
            guard self.isActive(generation) else { return }
            if !reflectedPackets.isEmpty {
                self.packetFlow.writePackets(reflectedPackets, withProtocols: reflectedProtocols)
            }
            self.readPackets(generation: generation)
        }
    }
}
