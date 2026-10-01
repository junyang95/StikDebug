import Foundation
import Darwin
@_implementationOnly import idevice

/// A single device-initiated pairing attempt. Run on a background queue and keep
/// the session alive until `run` returns. `cancel` is safe from any thread.
/// The application owns notification permission and its background task lifetime.
public final class SelfPairingSession: @unchecked Sendable {
    public enum Event: Sendable {
        case ready(hostName: String)
        case pin(String)
    }

    public struct Result: Sendable {
        public let pairingFileURL: URL
        /// Persist alongside the pairing record for future host advertisements.
        public let hostAltIRK: Data
        public let peerName: String?
        public let peerIdentifier: String?
    }

    public enum SessionError: Error, LocalizedError {
        case cancelled, timedOut, alreadyStarted, backgroundQueueRequired
        case unsupportedSystem, invalidAdvertisement, missingPairingRecord

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Pairing was cancelled."
            case .timedOut: return "Pairing timed out. Start a new pairing attempt."
            case .alreadyStarted: return "This pairing session has already started."
            case .backgroundQueueRequired: return "Pairing must run on a background queue."
            case .unsupportedSystem: return "On-device pairing requires iOS 27 or later."
            case .invalidAdvertisement: return "The pairing host could not be advertised."
            case .missingPairingRecord: return "The device did not return a pairing record."
            }
        }
    }

    public static let hostName = "StikDebug"
    public static let serviceType = "_remotepairing-pairable-host._tcp."

    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var cancellation: SessionError?
    // Only run() closes descriptors. cancel() shuts the connected socket down,
    // which also interrupts the duplicate used by Rust's async handshake.
    private var connectedSocket: Int32 = -1
    private var publisher: PairingServicePublisher?

    public init() {}

    public func cancel() { cancel(with: .cancelled) }

    /// Blocks until the real handshake completes, fails, or is cancelled. The
    /// output is a private RPPairing plist, ready for the app's validated import.
    /// Events may arrive on the calling queue or an FFI worker; dispatch UI work.
    public func run(outputURL: URL, timeout: TimeInterval = 180,
                    event: @escaping @Sendable (Event) -> Void) throws -> Result {
        guard !Thread.isMainThread else { throw SessionError.backgroundQueueRequired }
        guard #available(iOS 27.0, *) else { throw SessionError.unsupportedSystem }
        lock.lock()
        if started {
            lock.unlock()
            throw SessionError.alreadyStarted
        }
        started = true
        lock.unlock()
        defer { finish() }
        try checkCancellation()

        let expiry = DispatchWorkItem { [weak self] in self?.cancel(with: .timedOut) }
        let boundedTimeout = timeout.isFinite ? max(1, min(timeout, 600)) : 180
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + boundedTimeout, execute: expiry)
        defer { expiry.cancel() }

        var host: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtCount: UInt = 0
        var hostAltIRK = [UInt8](repeating: 0, count: 16)
        defer {
            if let host { pairable_host_free(host) }
            if let serviceID { idevice_string_free(serviceID) }
            if let txtBytes { idevice_data_free(txtBytes, txtCount) }
        }
        try IdeviceFFI.check("Could not prepare the pairing host") {
            pairable_host_prepare(Self.hostName, "Mac17,7", false, &host,
                                  &serviceID, &txtBytes, &txtCount, &hostAltIRK)
        }
        guard let host, let serviceID, let txtBytes,
              let txtLength = Int(exactly: txtCount), txtLength > 0 else {
            throw SessionError.invalidAdvertisement
        }
        let txtData = Data(bytes: txtBytes, count: txtLength)
        guard let properties = try PropertyListSerialization.propertyList(
            from: txtData, options: [], format: nil) as? [String: Any] else {
            throw SessionError.invalidAdvertisement
        }
        var txt: [String: Data] = [:]
        for (key, value) in properties {
            if let data = value as? Data { txt[key] = data }
            else if let string = value as? String { txt[key] = Data(string.utf8) }
            else { throw SessionError.invalidAdvertisement }
        }

        let (listener, port) = try makeListener()
        defer { Darwin.close(listener) }
        let advertisement = PairingServicePublisher(name: String(cString: serviceID),
                                                   port: port, txt: txt)
        lock.lock()
        publisher = advertisement
        let stoppedBeforePublish = cancellation != nil
        lock.unlock()
        if stoppedBeforePublish { try checkCancellation() }
        // NetService uses the main run loop. Publishing is separate from the
        // worker's blocking accept/FFI calls so UIKit remains responsive.
        DispatchQueue.main.async { advertisement.start() }
        try advertisement.waitUntilPublished(checkCancellation: checkCancellation)
        try checkCancellation()
        event(.ready(hostName: Self.hostName))

        let socket = try acceptConnection(on: listener)
        defer { closeConnection(socket) }
        let relay = PairingPINRelay { [weak self] pin in
            guard let self, !self.isCancelled,
                  pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
            event(.pin(pin))
        }
        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var pairing: OpaquePointer?
        defer {
            if let peer { rppairing_peer_device_free(peer) }
            if let pairing { rp_pairing_file_free(pairing) }
        }
        let ffiError = withExtendedLifetime(relay) {
            pairable_host_accept_fd(host, socket, { pin, context in
                guard let pin, let context else { return }
                Unmanaged<PairingPINRelay>.fromOpaque(context).takeUnretainedValue()
                    .receive(String(cString: pin))
            }, Unmanaged.passUnretained(relay).toOpaque(), &peer, &pairing)
        }
        // Always consume FFI errors, including ones caused by socket shutdown.
        let failure = ffiError.map { IdeviceFFI.consume($0, fallback: "Pairing failed") }
        try checkCancellation()
        if let failure { throw failure }
        guard let pairing else { throw SessionError.missingPairingRecord }

        var recordBytes: UnsafeMutablePointer<UInt8>?
        var recordCount: UInt = 0
        defer { if let recordBytes { idevice_data_free(recordBytes, recordCount) } }
        try IdeviceFFI.check("Could not serialize the pairing record") {
            rp_pairing_file_to_bytes(pairing, &recordBytes, &recordCount)
        }
        guard let recordBytes, let recordLength = Int(exactly: recordCount),
              recordLength > 0 else { throw SessionError.missingPairingRecord }
        let record = Data(bytes: recordBytes, count: recordLength)
        let fm = FileManager.default
        let directory = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try checkCancellation()
        try record.write(to: outputURL,
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        return Result(pairingFileURL: outputURL, hostAltIRK: Data(hostAltIRK),
                      peerName: peer?.pointee.name.map { String(cString: $0) },
                      peerIdentifier: peer?.pointee.udid.map { String(cString: $0) })
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellation != nil
    }

    private func checkCancellation() throws {
        lock.lock()
        let error = cancellation
        lock.unlock()
        if let error { throw error }
    }

    private func cancel(with reason: SessionError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if cancellation == nil { cancellation = reason }
        if connectedSocket >= 0 { Darwin.shutdown(connectedSocket, SHUT_RDWR) }
        let advertisement = publisher
        lock.unlock()
        DispatchQueue.main.async { advertisement?.stop() }
    }

    private func finish() {
        lock.lock()
        finished = true
        let advertisement = publisher
        publisher = nil
        lock.unlock()
        DispatchQueue.main.async { advertisement?.stop() }
    }

    private func makeListener() throws -> (Int32, Int32) {
        let socket = Darwin.socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw socketError() }
        do {
            var off: Int32 = 0
            // One listener accepts both IPv6 and IPv4-mapped connections.
            guard setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &off,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bound == 0, Darwin.listen(socket, 1) == 0 else { throw socketError() }
            var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let inspected = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socket, $0, &addressLength)
                }
            }
            guard inspected == 0 else { throw socketError() }
            // A poll-ready socket can lose readiness; nonblocking accept keeps
            // cancellation bounded even if the peer withdraws its connection.
            guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() }
            return (socket, Int32(UInt16(bigEndian: address.sin6_port)))
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    private func acceptConnection(on listener: Int32) throws -> Int32 {
        while true {
            try checkCancellation()
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 200)
            if result < 0 {
                if errno == EINTR { continue }
                throw socketError()
            }
            if result == 0 { continue }
            let socket = Darwin.accept(listener, nil, nil)
            if socket < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR { continue }
                throw socketError()
            }
            var noSIGPIPE: Int32 = 1
            if setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE,
                          socklen_t(MemoryLayout<Int32>.size)) != 0 {
                let error = socketError()
                Darwin.close(socket)
                throw error
            }
            lock.lock()
            connectedSocket = socket
            let stopped = cancellation != nil
            lock.unlock()
            if stopped {
                closeConnection(socket)
                try checkCancellation()
            }
            return socket
        }
    }

    private func closeConnection(_ socket: Int32) {
        lock.lock()
        if connectedSocket == socket {
            connectedSocket = -1
            Darwin.close(socket)
        }
        lock.unlock()
    }

    private func socketError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private final class PairingPINRelay {
    let receive: (String) -> Void
    init(receive: @escaping (String) -> Void) { self.receive = receive }
}

/// NetService methods/delegate callbacks are confined to the main run loop.
private final class PairingServicePublisher: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let name: String
    private let port: Int32
    private let txt: [String: Data]
    private var service: NetService?
    private let published = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failure: Error?
    private var stopped = false

    init(name: String, port: Int32, txt: [String: Data]) {
        self.name = name
        self.port = port
        self.txt = txt
        super.init()
    }

    func start() {
        guard !stopped else { return }
        let service = NetService(domain: "local.", type: SelfPairingSession.serviceType,
                                 name: name, port: port)
        self.service = service
        guard service.setTXTRecord(NetService.data(fromTXTRecord: txt)) else {
            lock.lock()
            failure = SelfPairingSession.SessionError.invalidAdvertisement
            lock.unlock()
            published.signal()
            return
        }
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.publish(options: .noAutoRename)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service?.delegate = nil
        service = nil
    }

    func waitUntilPublished(checkCancellation: () throws -> Void) throws {
        while published.wait(timeout: .now() + 0.2) == .timedOut {
            try checkCancellation()
        }
        lock.lock()
        let error = failure
        lock.unlock()
        if let error { throw error }
    }

    func netServiceDidPublish(_ sender: NetService) { published.signal() }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        lock.lock()
        failure = NSError(domain: "JITLauncher.Bonjour",
                          code: errorDict[NetService.errorCode]?.intValue ?? -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "The pairing host could not be published. Allow Local Network access in Settings."])
        lock.unlock()
        published.signal()
    }
}
