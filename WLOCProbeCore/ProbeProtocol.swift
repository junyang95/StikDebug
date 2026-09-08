import Foundation

enum EmbeddedVPNMode: String, Codable, Sendable {
    case developerLoopback
    case wlocProbe
}

enum ProbeCommand: String, Codable {
    case status
    case reset
}

struct ProbeHostActivity: Codable, Equatable, Sendable {
    var connections = 0
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var lastActivity: Date?
}

struct ProbeSnapshot: Codable, Equatable, Sendable {
    var mode: EmbeddedVPNMode = .developerLoopback
    var sessionID = UUID()
    var listening = false
    var port: UInt16?
    var activeConnections = 0
    var hosts: [String: ProbeHostActivity] = [:]
    var lastError: String?
    var resetAt = Date()

    var totalConnections: Int { hosts.values.reduce(0) { $0 + $1.connections } }
    var uploadedBytes: Int64 { hosts.values.reduce(0) { $0 + $1.uploadedBytes } }
    var downloadedBytes: Int64 { hosts.values.reduce(0) { $0 + $1.downloadedBytes } }
}

enum WLOCProbePolicy {
    // Exact hosts from the cyberhandyman stateless module; never a user-supplied proxy destination.
    static let hosts = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com"
    ]
    static let maximumHeaderBytes = 16 * 1024
    static let chunkBytes = 32 * 1024
    static let maximumConnections = 8
    static let handshakeTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 120
}
