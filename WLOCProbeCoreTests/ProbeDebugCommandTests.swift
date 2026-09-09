#if DEBUG
import XCTest
@testable import WLOCProbeCore

final class ProbeDebugCommandTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func request(action: String = "status", time: Double = 999) -> Data {
        Data("{\"version\":1,\"id\":\"B1000000-0000-0000-0000-000000000001\",\"issuedAt\":\(time),\"action\":\"\(action)\"}".utf8)
    }

    func testOnlyFourBoundedActionsAccepted() throws {
        for action in ["status", "reset", "selfTest", "stop"] {
            XCTAssertEqual(try ProbeDebugCommand.decode(request(action: action), now: now, after: 0).action.rawValue, action)
        }
        for action in ["start", "setLocation", "shell", "https://example.com"] {
            XCTAssertThrowsError(try ProbeDebugCommand.decode(request(action: action), now: now, after: 0))
        }
    }

    func testExpiredFutureAndReplayedRequestsRejected() {
        for time in [939.0, 1006.0] {
            XCTAssertThrowsError(try ProbeDebugCommand.decode(request(time: time), now: now, after: 0))
        }
        XCTAssertThrowsError(try ProbeDebugCommand.decode(request(), now: now, after: 999))
        XCTAssertThrowsError(try ProbeDebugCommand.decode(request(), now: now, after: 1000))
    }

    func testMalformedOversizedAndExtraFieldsRejected() throws {
        for data in [Data(), Data("null".utf8), Data(repeating: 32, count: 1025)] {
            XCTAssertThrowsError(try ProbeDebugCommand.decode(data, now: now, after: 0))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: request()) as? [String: Any])
        object["url"] = "https://private.example"
        XCTAssertThrowsError(try ProbeDebugCommand.decode(JSONSerialization.data(withJSONObject: object), now: now, after: 0))
        object.removeValue(forKey: "url")
        object["version"] = 2
        XCTAssertThrowsError(try ProbeDebugCommand.decode(JSONSerialization.data(withJSONObject: object), now: now, after: 0))
    }
}
#endif
