import Foundation
import Darwin

// Compile the real production connection entry point against a paired-tunnel
// boundary. Binding itself is covered by DeviceTunnelBindingTests against the
// real factory, core verifier, and lockdown reader. An open TCP port is not enough.
public enum StikJIT {
    public struct Configuration {
        public var deviceAddress: String
        public var rsdPort: UInt16
        public var connectionTimeout: TimeInterval
        public init(deviceAddress: String = "127.0.0.1", rsdPort: UInt16 = 49152,
                    connectionTimeout: TimeInterval = 0.15) {
            self.deviceAddress = deviceAddress; self.rsdPort = rsdPort
            self.connectionTimeout = connectionTimeout
        }
        public static var `default`: Self { Self() }
    }
}
private enum TestFailure: Error { case tunnelBoundary, unexpected(String) }
enum DeviceTools {
    struct Tunnel {}
    static var allowsHandshake = false
    static var attempts = 0
    static var completedHandshakes = 0
    static var cleanedUpTunnels = 0
    static func withTunnel<T>(_ file: URL, _ config: StikJIT.Configuration,
                              cancellationCheck: () throws -> Void = {},
                              _ body: (Tunnel) throws -> T) throws -> T {
        attempts += 1
        guard allowsHandshake else { throw TestFailure.tunnelBoundary }
        completedHandshakes += 1
        defer { cleanedUpTunnels += 1 }
        return try body(Tunnel())
    }
}
private final class TCPFixture {
    let descriptor: Int32
    let port: UInt16
    init(listening: Bool) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure.unexpected("socket failed") }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(descriptor); throw TestFailure.unexpected("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { Darwin.close(descriptor); throw TestFailure.unexpected("getsockname failed") }
        port = UInt16(bigEndian: address.sin_port)
        if listening && listen(descriptor, 16) != 0 {
            Darwin.close(descriptor); throw TestFailure.unexpected("listen failed")
        }
    }
    deinit { Darwin.close(descriptor) }
}
@main
enum DeviceConnectionProbeTests {
    static func main() throws {
        let live = try TCPFixture(listening: true)
        // A bound but non-listening socket reserves the unavailable port, so an
        // unrelated service cannot accidentally turn the test into a success.
        let absent = try TCPFixture(listening: false)
        let file = URL(fileURLWithPath: "/unused/pairing.plist")
        var checks = 0
        func run(_ title: String, _ body: () throws -> Void) rethrows {
            DeviceTools.allowsHandshake = false
            DeviceTools.attempts = 0
            DeviceTools.completedHandshakes = 0
            DeviceTools.cleanedUpTunnels = 0
            try body(); checks += 1; print("PASS \(title)")
        }
        func expectFailure(_ config: StikJIT.Configuration,
                           cancellationCheck: () throws -> Void = {}, matches: (Error) -> Bool) throws {
            do {
                try StikJIT.checkDeviceConnection(pairingFile: file, configuration: config,
                                                 cancellationCheck: cancellationCheck)
                throw TestFailure.unexpected("Connection check unexpectedly succeeded")
            } catch {
                guard matches(error) else { throw TestFailure.unexpected("Unexpected failure: \(error)") }
            }
        }
        let liveConfiguration = StikJIT.Configuration(rsdPort: live.port)
        let absentConfiguration = StikJIT.Configuration(rsdPort: absent.port)
        try run("A reachable TCP endpoint still requires the paired tunnel") {
            try expectFailure(liveConfiguration, matches: {
                if case TestFailure.tunnelBoundary = $0 { return true }; return false
            })
            precondition(DeviceTools.attempts == 1)
        }
        try run("An authorized paired tunnel completes the connection check") {
            DeviceTools.allowsHandshake = true
            var count = 0
            try StikJIT.checkDeviceConnection(pairingFile: file, configuration: liveConfiguration,
                                             cancellationCheck: { count += 1 })
            precondition(count == 3)
            precondition(DeviceTools.attempts == 1 && DeviceTools.completedHandshakes == 1)
            precondition(DeviceTools.cleanedUpTunnels == 1)
        }
        try run("An unavailable endpoint fails within its deadline before the paired tunnel") {
            let started = ProcessInfo.processInfo.systemUptime
            try expectFailure(absentConfiguration, matches: {
                if case StikJITError.deviceNotReady = $0 { return true }; return false
            })
            precondition(ProcessInfo.processInfo.systemUptime - started < 3)
            precondition(DeviceTools.attempts == 0)
        }
        try run("An invalid endpoint fails before the paired tunnel") {
            try expectFailure(.init(deviceAddress: " ", rsdPort: live.port), matches: {
                if case StikJITError.deviceNotReady = $0 { return true }; return false
            })
            precondition(DeviceTools.attempts == 0)
        }
        try run("Cancellation before probing never enters the tunnel") {
            var count = 0
            try expectFailure(liveConfiguration, cancellationCheck: {
                count += 1; throw CancellationError()
            }, matches: { $0 is CancellationError })
            precondition(count == 1 && DeviceTools.attempts == 0)
        }
        try run("Cancellation after TCP success prevents paired tunnel creation") {
            var count = 0
            try expectFailure(liveConfiguration, cancellationCheck: {
                count += 1; if count == 2 { throw CancellationError() }
            }, matches: { $0 is CancellationError })
            precondition(count == 2 && DeviceTools.attempts == 0)
        }
        try run("Cancellation after pairing rejects success and releases the tunnel") {
            DeviceTools.allowsHandshake = true
            var count = 0
            try expectFailure(liveConfiguration, cancellationCheck: {
                count += 1; if count == 3 { throw CancellationError() }
            }, matches: { $0 is CancellationError })
            precondition(count == 3)
            precondition(DeviceTools.attempts == 1 && DeviceTools.completedHandshakes == 1)
            precondition(DeviceTools.cleanedUpTunnels == 1)
        }
        try run("Cancellation during an unavailable probe wins over its network error") {
            var count = 0
            try expectFailure(absentConfiguration, cancellationCheck: {
                count += 1; if count == 2 { throw CancellationError() }
            }, matches: { $0 is CancellationError })
            precondition(count == 2 && DeviceTools.attempts == 0)
        }
        print("\(checks) device connection probe integration tests passed")
    }
}
