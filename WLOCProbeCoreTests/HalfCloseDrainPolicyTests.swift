import Network
import XCTest
@testable import WLOCProbeCore

final class HalfCloseDrainPolicyTests: XCTestCase {
    func testOnlyENETDOWNAfterFINCanEnterDrain() {
        XCTAssertTrue(HalfCloseDrainPolicy.allows(.posix(.ENETDOWN), writeCloseSubmitted: true))
        XCTAssertFalse(HalfCloseDrainPolicy.allows(.posix(.ENETDOWN), writeCloseSubmitted: false))
        for error in [NWError.posix(.ECONNRESET), .posix(.EPIPE), .posix(.ETIMEDOUT),
                      .posix(.ECONNREFUSED), .dns(-65538), .tls(-9807)] {
            for submitted in [false, true] {
                XCTAssertFalse(HalfCloseDrainPolicy.allows(error, writeCloseSubmitted: submitted))
            }
        }
        XCTAssertEqual(HalfCloseDrainPolicy.maximumDuration, 1)
    }
}
