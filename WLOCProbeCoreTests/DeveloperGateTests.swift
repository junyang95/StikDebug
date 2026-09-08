import XCTest
@testable import WLOCProbeCore

final class DeveloperGateTests: XCTestCase {
    override func setUp() {
        DeveloperConnectionGate.setBlocked(false)
        _ = DeveloperConnectionGate.performLocationCommand(clear: true) { 0 }
    }

    override func tearDown() {
        DeveloperConnectionGate.setBlocked(false)
        _ = DeveloperConnectionGate.performLocationCommand(clear: true) { 0 }
    }

    func testInFlightDeveloperOperationPreventsProbe() {
        XCTAssertTrue(DeveloperConnectionGate.beginDeveloperOperation())
        XCTAssertFalse(DeveloperConnectionGate.beginProbe())
        DeveloperConnectionGate.endDeveloperOperation()
        XCTAssertTrue(DeveloperConnectionGate.beginProbe())
        XCTAssertFalse(DeveloperConnectionGate.beginDeveloperOperation())
    }

    func testProbeBlocksQueuedSetAndClearWithoutExecutingThem() {
        XCTAssertTrue(DeveloperConnectionGate.beginProbe())
        for clear in [false, true] {
            let status = DeveloperConnectionGate.performLocationCommand(clear: clear) {
                XCTFail("FFI closure must not execute during a probe")
                return 0
            }
            XCTAssertEqual(status, DeveloperConnectionGate.blockedStatus)
        }
    }

    func testLocationRequiresSuccessfulExplicitRestoreBeforeProbe() {
        _ = DeveloperConnectionGate.performLocationCommand(clear: false) { 0 }
        XCTAssertTrue(DeveloperConnectionGate.needsRestore)
        XCTAssertFalse(DeveloperConnectionGate.beginProbe())
        _ = DeveloperConnectionGate.performLocationCommand(clear: true) { -1 }
        XCTAssertFalse(DeveloperConnectionGate.beginProbe())
        _ = DeveloperConnectionGate.performLocationCommand(clear: true) { 0 }
        XCTAssertFalse(DeveloperConnectionGate.needsRestore)
        XCTAssertTrue(DeveloperConnectionGate.beginProbe())
    }

    func testFailedSetIsConservativelyTreatedAsPotentiallyActive() {
        _ = DeveloperConnectionGate.performLocationCommand(clear: false) { -1 }
        XCTAssertTrue(DeveloperConnectionGate.needsRestore)
        XCTAssertFalse(DeveloperConnectionGate.beginProbe())
    }
}
