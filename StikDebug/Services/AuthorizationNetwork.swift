import Foundation
import Network
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif

/// Make the real request to trigger any system prompt; reachability is never an access gate.
enum AuthorizationHTTPClient {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static func request(udid: String, nonce: String, waiting: @escaping @Sendable () -> Void) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://wow-app.store/api/vip-license.action")!)
        request.setValue(udid, forHTTPHeaderField: "DEVICE_UDID")
        request.setValue(nonce, forHTTPHeaderField: "X-VIP-NONCE")
        request.setValue("PikminHelper/0.1.6", forHTTPHeaderField: "User-Agent")
        return try await AuthorizationRequestRetry.run {
            // A new session drops stale connections after a Wi-Fi/cellular handover.
            // The service bounds this entire operation, including retries, to 60 seconds.
            let session = URLSession(configuration: configuration())
            defer { session.invalidateAndCancel() }
            let response = try await session.data(for: request, delegate: ConnectivityDelegate(waiting: waiting))
            guard let http = response.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else { throw AuthorizationHTTPError(status: http.statusCode) }
            return response.0
        }
    }

    private final class ConnectivityDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let waiting: @Sendable () -> Void
        init(waiting: @escaping @Sendable () -> Void) { self.waiting = waiting }
        func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
            waiting()
        }
    }
}

struct AuthorizationHTTPError: Error {
    let status: Int
}

enum AuthorizationRequestRetry {
    static func run(
        operation: () async throws -> Data,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Data {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, isTransient(error) else { throw error }
                try await sleep(Double(attempt + 1))
            }
        }
        throw URLError(.unknown)
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let http = error as? AuthorizationHTTPError {
            return [502, 503, 504].contains(http.status)
        }
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                .cannotConnectToHost, .notConnectedToInternet].contains(url.code)
    }
}

struct AuthorizationNetworkPath: Equatable {
    let satisfied: Bool
    let interfaces: [String]
    let ipv4: Bool
    let ipv6: Bool
    let dns: Bool
    let expensive: Bool
    let constrained: Bool
}

struct AuthorizationPathRecovery {
    private var previous: AuthorizationNetworkPath?

    mutating func update(_ current: AuthorizationNetworkPath) -> Bool {
        defer { previous = current }
        return current.satisfied && previous != current
    }
}

/// These are retry hints, not proof of Internet access or permission to use Wi-Fi.
final class AuthorizationConnectivityObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.pikminhelper.authorization.connectivity")
    private var recovery = AuthorizationPathRecovery()
    #if canImport(CoreTelephony) && os(iOS)
    private let cellular = CTCellularData()
    private var wasCellularAllowed = false
    #endif

    init(available: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let current = AuthorizationNetworkPath(
                satisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.type):\($0.name)" }.sorted(),
                ipv4: path.supportsIPv4, ipv6: path.supportsIPv6, dns: path.supportsDNS,
                expensive: path.isExpensive, constrained: path.isConstrained)
            if self.recovery.update(current) { available() }
        }
        monitor.start(queue: queue)
        #if canImport(CoreTelephony) && os(iOS)
        cellular.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            self?.queue.async { [weak self] in
                guard let self else { return }
                let allowed = state == .notRestricted
                let recovered = allowed && !self.wasCellularAllowed
                self.wasCellularAllowed = allowed
                if recovered { available() }
            }
        }
        #endif
    }

    deinit {
        monitor.cancel()
        #if canImport(CoreTelephony) && os(iOS)
        cellular.cellularDataRestrictionDidUpdateNotifier = nil
        #endif
    }
}
