#if DEBUG
import Foundation

/// A fixed, paired-Mac mailbox, not a general RPC server. No start, arbitrary URL,
/// coordinate, shell, file-path or VPN-configuration command is accepted.
struct ProbeDebugCommand: Codable {
    enum Action: String, Codable { case status, reset, selfTest, stop }
    let version: Int
    let id: UUID
    let issuedAt: TimeInterval
    let action: Action

    static func decode(_ data: Data, now: Date = Date(), after watermark: TimeInterval) throws -> Self {
        guard data.count <= 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "id", "issuedAt", "action"] else { throw Invalid.request }
        let command = try JSONDecoder().decode(Self.self, from: data)
        let age = now.timeIntervalSince1970 - command.issuedAt
        guard command.version == 1, command.issuedAt.isFinite,
              command.issuedAt > watermark, age >= -5, age <= 60 else { throw Invalid.request }
        return command
    }

    enum Invalid: Error { case request }
}
#endif
