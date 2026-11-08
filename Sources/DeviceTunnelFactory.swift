import Foundation
@_implementationOnly import idevice

/// Owns one actual paired connection. Authorization is scoped to this connection;
/// a previous successful check never authorizes a newly opened tunnel.
struct DeviceTunnel {
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    func free() {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
    }
}

struct DeviceTunnelFactory {
    let pairingFilePath: String
    let configuration: StikJIT.Configuration
    // Internal injection keeps host tests on the real connection/gate path.
    // The production entry points always use the fixed-key bundle loader.
    var credential: () throws -> OfflineDeviceCredential = {
        try OfflineDeviceBinding.credential(expectedProduct: "jit-launcher")
    }

    func validatePairingFile() throws {
        let pairing = try openPairingFile()
        rp_pairing_file_free(pairing)
    }

    func makeTunnel(cancellationCheck: () throws -> Void = {}) throws -> DeviceTunnel {
        try cancellationCheck()
        let tunnel = try openPairedTunnel()
        var authorized = false
        defer { if !authorized { tunnel.free() } }
        try cancellationCheck()
        do {
            let credential = try credential()
            try cancellationCheck()
            let actualUDID = try DeviceIdentityReader.udid(over: tunnel)
            try cancellationCheck()
            try credential.validate(actualUDID: actualUDID)
        } catch let error as OfflineDeviceBindingError {
            throw StikJITError.offlineDeviceBinding(.init(error))
        }
        try cancellationCheck()
        authorized = true
        return tunnel
    }

    /// Internal recovery capability only. Callers may clear location or resume
    /// a suspended process; they must not expose the tunnel to ordinary actions.
    func makeRecoveryTunnel() throws -> DeviceTunnel { try openPairedTunnel() }

    private func openPairingFile() throws -> OpaquePointer {
        guard !pairingFilePath.isEmpty, FileManager.default.fileExists(atPath: pairingFilePath) else {
            throw StikJITError.pairingFile("not found at \(pairingFilePath)")
        }
        var handle: OpaquePointer?
        var succeeded = false
        defer { if !succeeded, let handle { rp_pairing_file_free(handle) } }
        try IdeviceFFI.check("failed to read pairing file") {
            pairingFilePath.withCString { rp_pairing_file_read($0, &handle) }
        }
        guard let handle else { throw StikJITError.pairingFile("unreadable at \(pairingFilePath)") }
        succeeded = true
        return handle
    }

    private func openPairedTunnel() throws -> DeviceTunnel {
        let pairing = try openPairingFile()
        defer { rp_pairing_file_free(pairing) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.rsdPort.bigEndian
        guard configuration.deviceAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw StikJITError.device(code: -1, subCode: 0, message: "Invalid device IPv4 address")
        }
        var tunnel = DeviceTunnel()
        var succeeded = false
        defer { if !succeeded { tunnel.free() } }
        try IdeviceFFI.check("failed to create RSD tunnel") {
            "StikJIT".withCString { hostname in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        tunnel_create_rppairing(sa, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                               hostname, pairing, nil, nil,
                                               &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
        }
        guard tunnel.adapter != nil, tunnel.handshake != nil else {
            throw StikJITError.device(code: -1, subCode: 0, message: "RSD tunnel was not returned")
        }
        succeeded = true
        return tunnel
    }
}

private extension OfflineDeviceBindingFailure {
    init(_ error: OfflineDeviceBindingError) {
        switch error {
        case .missingCredential: self = .missingCredential
        case .invalidCredential: self = .invalidCredential
        case .invalidSignature: self = .invalidSignature
        case .unsupportedCredential: self = .unsupportedCredential
        case .wrongProduct: self = .wrongProduct
        case .invalidDeviceIdentifier: self = .invalidDeviceIdentifier
        case .deviceMismatch: self = .deviceMismatch
        }
    }
}
