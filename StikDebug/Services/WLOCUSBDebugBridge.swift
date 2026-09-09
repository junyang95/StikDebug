#if DEBUG
import Foundation

/// Commands are carried by the paired Mac's app-container file service, not TCP.
/// Only claims requests while foregrounded; accepted operations finish normally.
@MainActor
final class WLOCUSBDebugBridge {
    static let shared = WLOCUSBDebugBridge()
    private let directory = URL.documentsDirectory.appendingPathComponent("WLOCDebug", isDirectory: true)
    private var active = false
    private var task: Task<Void, Never>?
    private var watermark: TimeInterval = 0
    private var prepared = false

    func setActive(_ active: Bool) {
        self.active = active
        guard active, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                try self.prepare()
                ProbeDebugLog.emit(EmbeddedVPNService.shared.debugRecord(event: .ready))
                while self.active {
                    await self.consumeRequest()
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                // No raw filesystem error or path in public diagnostics.
                var record = EmbeddedVPNService.shared.debugRecord(event: .command)
                record.result = .unavailable
                ProbeDebugLog.emit(record)
            }
        }
    }

    private func prepare() throws {
        guard !prepared else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cursor = directory.appendingPathComponent("cursor.json")
        if FileManager.default.fileExists(atPath: cursor.path) {
            // Fail closed on corrupt replay state; never silently reset it.
            watermark = try JSONDecoder().decode(TimeInterval.self, from: readBounded(cursor))
            guard watermark.isFinite, watermark >= 0 else { throw ProbeDebugCommand.Invalid.request }
        }
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var path = directory
        try path.setResourceValues(resource)
        prepared = true
    }

    private func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1024 else { throw ProbeDebugCommand.Invalid.request }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1025) ?? Data()
        guard data.count <= 1024 else { throw ProbeDebugCommand.Invalid.request }
        return data
    }

    private func consumeRequest() async {
        let inbox = directory.appendingPathComponent("request.json")
        let ready = directory.appendingPathComponent("ready.txt")
        // The Mac copies the UUID marker only AFTER the payload copy succeeds.
        // A partial copy or an old marker must not consume the new request.
        guard active, let markerData = try? readBounded(ready),
              let marker = String(data: markerData, encoding: .utf8),
              let id = UUID(uuidString: marker),
              let preview = try? JSONDecoder().decode(ProbeDebugCommand.self, from: readBounded(inbox)),
              preview.id == id else { return }
        do {
            // Claim before execution so app interruption cannot replay it.
            try FileManager.default.removeItem(at: ready)
            let claimed = directory.appendingPathComponent("claimed.json")
            if FileManager.default.fileExists(atPath: claimed.path) { try FileManager.default.removeItem(at: claimed) }
            try FileManager.default.moveItem(at: inbox, to: claimed)
            let command = try ProbeDebugCommand.decode(readBounded(claimed), after: watermark)
            guard command.id == id else { throw ProbeDebugCommand.Invalid.request }
            // Persist before invoking any action. Requests older than this cursor are rejected.
            try JSONEncoder().encode(command.issuedAt).write(to: directory.appendingPathComponent("cursor.json"), options: .atomic)
            watermark = command.issuedAt
            var accepted = EmbeddedVPNService.shared.debugRecord(event: .command)
            accepted.requestID = command.id
            accepted.result = .accepted
            try respond(accepted)
            let response = await EmbeddedVPNService.shared.performDebugCommand(command)
            try respond(response)
        } catch {
            var record = EmbeddedVPNService.shared.debugRecord(event: .command)
            record.result = .failed
            // Invalid requests have no trusted request ID and never execute.
            ProbeDebugLog.emit(record)
        }
    }

    private func respond(_ record: ProbeDebugRecord) throws {
        let data = try record.encoded()
        guard data.count <= 4096 else { throw ProbeDebugCommand.Invalid.request }
        try data.write(to: directory.appendingPathComponent("response.json"), options: .atomic)
        ProbeDebugLog.emit(record)
    }
}
#endif
