#if DEBUG
import XCTest
@testable import WLOCProbeCore

final class ProbeDebugTelemetryTests: XCTestCase {
    func testSnapshotDropsUnexpectedHostsAndArbitraryErrors() throws {
        var snapshot = ProbeSnapshot(mode: .wlocProbe)
        snapshot.hosts["gs-loc.apple.com"] = ProbeHostActivity(connections: 2, uploadedBytes: 100, downloadedBytes: 200)
        snapshot.hosts["secret.example?token=private"] = ProbeHostActivity(connections: 9)
        snapshot.lastError = "private coordinate / credential / URL"
        let record = ProbeDebugRecord(source: .tunnel, event: .snapshot, snapshot: ProbeDebugSnapshot(snapshot))
        let data = try record.encoded()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private"))
        XCTAssertFalse(json.contains("secret.example"))
        let decoded = try JSONDecoder().decode(ProbeDebugRecord.self, from: data)
        XCTAssertEqual(decoded.snapshot?.hosts.count, 1)
        XCTAssertEqual(decoded.snapshot?.hosts["gs-loc.apple.com"]?.sent, 100)
        XCTAssertEqual(decoded.snapshot?.error, "proxy_error")
    }

    func testFullSnapshotFitsBoundAndUsesUnixTimestamps() throws {
        var snapshot = ProbeSnapshot(mode: .wlocProbe)
        for host in WLOCProbePolicy.hosts {
            snapshot.hosts[host] = ProbeHostActivity(connections: 1000, uploadedBytes: 1000000,
                                                   downloadedBytes: 1000000, lastActivity: Date())
        }
        let record = ProbeDebugRecord(source: .tunnel, event: .snapshot, snapshot: ProbeDebugSnapshot(snapshot))
        XCTAssertLessThan(try record.encoded().count, 2048)
        XCTAssertEqual(record.snapshot?.resetAt, snapshot.resetAt.timeIntervalSince1970)
    }
}
#endif
