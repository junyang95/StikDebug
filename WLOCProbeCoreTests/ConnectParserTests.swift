import Foundation
import XCTest
@testable import WLOCProbeCore

final class ConnectParserTests: XCTestCase {
    func testEveryPossibleFragmentBoundaryPreservesBinaryPayload() throws {
        let header = Data("CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nHost: gs-loc.apple.com:443\r\n\r\n".utf8)
        let payload = Data([22, 3, 1, 0, 0, 255, 13, 10, 0, 128])
        for boundary in 0..<header.count {
            var parser = ConnectRequestParser()
            XCTAssertNil(try parser.append(Data(header.prefix(boundary))))
            let result = try XCTUnwrap(parser.append(Data(header.dropFirst(boundary)) + payload))
            XCTAssertEqual(result.host, "gs-loc.apple.com")
            XCTAssertEqual(result.initialPayload, payload)
        }
    }

    func testOnlyFourExactAuthoritiesAllowed() throws {
        for host in WLOCProbePolicy.hosts {
            var parser = ConnectRequestParser()
            XCTAssertEqual(try parser.append(Data("CONNECT \(host.uppercased()):443 HTTP/1.1\r\n\r\n".utf8))?.host, host)
        }
        for authority in ["example.com:443", "gs-loc.apple.com.evil.test:443", "gs-loc.apple.com:80",
                          "127.0.0.1:443", "[::1]:443", "user@gs-loc.apple.com:443", "gs-loc.apple.com.:443"] {
            var parser = ConnectRequestParser()
            XCTAssertThrowsError(try parser.append(Data("CONNECT \(authority) HTTP/1.1\r\n\r\n".utf8))) {
                XCTAssertEqual($0 as? ConnectRequestError, .forbidden)
            }
        }
    }

    func testRejectsAmbiguousHeadersAndOtherMethods() {
        for request in [
            "GET https://gs-loc.apple.com/ HTTP/1.1\r\n\r\n",
            "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nHost: other.test:443\r\n\r\n",
            "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nContent-Length: 1\r\n\r\nx",
            "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n Bad: folded\r\n\r\n",
            "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nBadHeader\r\n\r\n"
        ] {
            var parser = ConnectRequestParser()
            XCTAssertThrowsError(try parser.append(Data(request.utf8)))
        }
    }

    func testHeaderLimitAppliesWithAndWithoutTerminator() {
        for suffix in [Data(), Data("\r\n\r\n".utf8)] {
            var parser = ConnectRequestParser()
            XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: WLOCProbePolicy.maximumHeaderBytes + 1) + suffix)) {
                XCTAssertEqual($0 as? ConnectRequestError, .headerTooLarge)
            }
        }
    }

    func testSnapshotRoundTripAndAggregates() throws {
        let snapshot = ProbeSnapshot(mode: .wlocProbe, listening: true, port: 12345, hosts: [
            "gs-loc.apple.com": ProbeHostActivity(connections: 2, uploadedBytes: 10, downloadedBytes: 20)
        ])
        XCTAssertEqual(try JSONDecoder().decode(ProbeSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(snapshot.totalConnections, 2)
        XCTAssertEqual(snapshot.uploadedBytes, 10)
        XCTAssertEqual(snapshot.downloadedBytes, 20)
    }
}
