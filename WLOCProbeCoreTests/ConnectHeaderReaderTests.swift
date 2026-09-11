import Foundation
import XCTest
@testable import WLOCProbeCore

final class ConnectHeaderReaderTests: XCTestCase {
    private let header = Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nHost: gs-loc.apple.com\r\n\r\n".utf8)

    func testCompleteCONNECTAndEOFInSameCallbackRetainsReverseDirectionAndPayload() throws {
        let payload = Data([0, 255, 22, 3, 1, 0, 13, 10])
        var reader = ConnectHeaderReader()
        XCTAssertEqual(try reader.receive(header + payload, eof: true),
                       .connect(ConnectRequest(host: "gs-loc.apple.com", initialPayload: payload), clientReadClosed: true))
    }

    func testFinalHeaderFragmentWithEOFIsIndependentOfFragmentBoundary() throws {
        let payload = Data([0, 255, 17])
        for boundary in 0..<header.count {
            var reader = ConnectHeaderReader()
            XCTAssertEqual(try reader.receive(Data(header.prefix(boundary)), eof: false), .needMore)
            XCTAssertEqual(try reader.receive(Data(header.dropFirst(boundary)) + payload, eof: true),
                           .connect(ConnectRequest(host: "gs-loc.apple.com", initialPayload: payload), clientReadClosed: true))
        }
    }

    func testIncompleteEOFDoesNotConnectAndOrdinaryCONNECTKeepsReading() throws {
        var reader = ConnectHeaderReader()
        XCTAssertEqual(try reader.receive(nil, eof: false), .needMore)
        XCTAssertEqual(try reader.receive(Data("CONNE".utf8), eof: false), .needMore)
        XCTAssertEqual(try reader.receive(nil, eof: true), .endBeforeRequest)
        var complete = ConnectHeaderReader()
        XCTAssertEqual(try complete.receive(header, eof: false),
                       .connect(ConnectRequest(host: "gs-loc.apple.com", initialPayload: Data()), clientReadClosed: false))
    }

    func testEOFCannotBypassAuthorityValidation() throws {
        var reader = ConnectHeaderReader()
        XCTAssertThrowsError(try reader.receive(Data("CONNECT private.invalid:443 HTTP/1.1\r\n\r\n".utf8), eof: true)) {
            XCTAssertEqual($0 as? ConnectRequestError, .forbidden)
        }
    }
}
