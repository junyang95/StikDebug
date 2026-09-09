#if DEBUG
import Foundation
import OSLog

/// Deliberately separate from UI errors: never serialize arbitrary error descriptions,
/// URLs, request bodies, coordinates, headers, or credentials to a public log.
struct ProbeDebugSnapshot: Codable {
    struct Host: Codable {
        let connections: Int
        let sent: Int64
        let received: Int64
        let lastActivity: TimeInterval?
    }
    let mode: EmbeddedVPNMode
    let sessionID: UUID
    let resetAt: TimeInterval
    let listening: Bool
    let port: UInt16?
    let active: Int
    let hosts: [String: Host]
    let error: String?

    init(_ snapshot: ProbeSnapshot) {
        mode = snapshot.mode
        sessionID = snapshot.sessionID
        resetAt = snapshot.resetAt.timeIntervalSince1970
        listening = snapshot.listening
        port = snapshot.port
        active = snapshot.activeConnections
        hosts = snapshot.hosts.filter { WLOCProbePolicy.hosts.contains($0.key) }.mapValues {
            Host(connections: $0.connections, sent: $0.uploadedBytes,
                 received: $0.downloadedBytes, lastActivity: $0.lastActivity?.timeIntervalSince1970)
        }
        let codes = [
            "本机监听失败": "listener_failed", "连接数达到上限": "connection_limit",
            "CONNECT 或上游连接超时": "connect_timeout", "透传连接空闲超时": "idle_timeout",
            "客户端连接失败": "client_failed", "CONNECT 读取失败": "header_read_failed",
            "CONNECT 请求被拒绝": "connect_rejected", "CONNECT 解析失败": "parse_failed",
            "上游连接中断": "upstream_interrupted", "CONNECT 应答失败": "reply_failed",
            "上游发送失败": "upstream_send_failed", "无法直接连接上游": "upstream_failed",
            "透传连接中断": "relay_interrupted", "透传发送失败": "relay_send_failed"
        ]
        error = snapshot.lastError.map { codes[$0] ?? "proxy_error" }
    }
}

struct ProbeDebugSelfTest: Codable {
    enum Outcome: String, Codable { case running, passed, unconfirmed, failed }
    var outcome: Outcome
    var httpStatus: Int?
    var usedProxy: Bool?
    var urlErrorCode: Int?
}

struct ProbeDebugRecord: Codable {
    enum Source: String, Codable { case app, tunnel }
    enum Event: String, Codable { case ready, snapshot, reset, stopped, selfTest, command }
    enum Result: String, Codable { case ok, busy, unavailable, failed, accepted }
    enum VPNState: String, Codable { case loading, disconnected, connecting, connected, disconnecting, failed }

    var version = 1
    var at = Date().timeIntervalSince1970
    var bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let source: Source
    let event: Event
    var snapshot: ProbeDebugSnapshot?
    var selfTest: ProbeDebugSelfTest?
    var vpnState: VPNState?
    var experimentEnabled: Bool?
    var requestID: UUID?
    var result: Result?

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

enum ProbeDebugLog {
    static let prefix = "STIK_WLOC_DEBUG_V1 "
    private static let logger = Logger(subsystem: "com.jy.stikdebug.wloc", category: "usb-debug")

    static func emit(_ record: ProbeDebugRecord) {
        guard let data = try? record.encoded(), data.count <= 4096,
              let json = String(data: data, encoding: .utf8) else { return }
        // All dynamic content is constructed from the metadata-only types above.
        logger.notice("STIK_WLOC_DEBUG_V1 \(json, privacy: .public)")
    }
}
#endif
