import Foundation

extension StikJIT {
    /// Checks the local endpoint and the signed binding against the actual
    /// paired connection target. No website authorization request is made.
    /// This operation blocks and must run off the main thread.
    public static func checkDeviceConnection(pairingFile: URL, configuration: Configuration = .default,
                                             cancellationCheck: () throws -> Void = {}) throws {
        try cancellationCheck()
        if let reason = EndpointProbe.failureReason(address: configuration.deviceAddress,
                                                    port: configuration.rsdPort,
                                                    timeout: configuration.connectionTimeout) {
            try cancellationCheck()
            throw StikJITError.deviceNotReady(reason)
        }
        try cancellationCheck()
        try DeviceTools.withTunnel(pairingFile, configuration, cancellationCheck: cancellationCheck) { _ in
            try cancellationCheck()
        }
    }
}
