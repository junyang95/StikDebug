import CoreLocation
import Foundation
import Testing
@testable import PikminRuntime

struct CoordinatePasteTests {
    @Test func suppliedNineteenPointsPreserveEveryCoordinateAndOrder() {
        let result = CoordinatePasteParser.parse(Self.sample)
        let expected = Self.sample.split(separator: "\n").map { line in
            line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! }
        }
        #expect(result.isValid && result.canCreateRoute)
        #expect(!result.canApplyCoordinate)
        #expect(result.nonemptyLineCount == 19 && result.coordinates.count == 19)
        #expect(result.issues.isEmpty)
        for (point, values) in zip(result.coordinates, expected) {
            #expect(point.latitude == values[0] && point.longitude == values[1])
        }
        #expect(abs(result.totalDistance / 1000 - 85.387) < 0.01)
    }

    @Test func supportedSeparatorsAndNegativeValuesKeepLatitudeLongitudeOrder() {
        let result = CoordinatePasteParser.parse("  -25.1, -121.7  \n+25.2，121.8\n.5\t-.75")
        #expect(result.canCreateRoute && result.coordinates.count == 3)
        #expect(result.coordinates.map(\.latitude) == [-25.1, 25.2, 0.5])
        #expect(result.coordinates.map(\.longitude) == [-121.7, 121.8, -0.75])
    }

    @Test func blankLinesAndWindowsLineEndingsPreserveErrorLineNumbers() {
        let secondLine = CoordinatePasteParser.parse("25.1,121.7\r\ninvalid")
        #expect(secondLine.issues.first?.lineNumber == 2)
        let result = CoordinatePasteParser.parse("\r\n25.1,121.7\r\n \r\ninvalid\r\n25.2,121.8\r\n")
        #expect(result.nonemptyLineCount == 3)
        #expect(result.coordinates.count == 2)
        #expect(result.issues == [CoordinatePasteIssue(lineNumber: 4, kind: .invalidFormat)])
        #expect(!result.canCreateRoute && !result.canApplyCoordinate)
    }

    @Test func listNumbersExtraFieldsAndTextCannotBecomeCoordinates() {
        for malformed in [
            "1. 25.097467, 121.712822", "25.1,121.7,5", "25.1,121.7 park",
            "latitude 25.1 longitude 121.7", "[25.1,121.7]", "25.1,", "NaN,121.7"
        ] {
            let result = CoordinatePasteParser.parse(malformed + "\n25.2,121.8")
            #expect(result.issues == [CoordinatePasteIssue(lineNumber: 1, kind: .invalidFormat)])
            #expect(!result.isValid && !result.canCreateRoute && !result.canApplyCoordinate)
            #expect(result.coordinates.count == 1)
        }
    }

    @Test func invalidRangesAreReportedWithoutSwappingColumns() {
        for text in ["91,25", "-91,25", "25,181", "25,-181", "121.7,25.1"] {
            let result = CoordinatePasteParser.parse(text)
            #expect(result.issues == [CoordinatePasteIssue(lineNumber: 1, kind: .outOfRange)])
            #expect(result.coordinates.isEmpty)
            #expect(!result.isValid)
        }
        let boundary = CoordinatePasteParser.parse("90,180\n-90,-180")
        #expect(boundary.canCreateRoute && boundary.issues.isEmpty)
    }

    @Test func singlePointRemainsUsableButCannotCreateRoute() {
        let result = CoordinatePasteParser.parse("\n25.1,121.7\n")
        #expect(result.canApplyCoordinate && !result.canCreateRoute)
        #expect(result.coordinates.count == 1 && result.totalDistance == 0)
        #expect(!CoordinatePasteParser.parse(" \n\t").isValid)
    }

    @Test func repeatedPointsArePreservedButAnEntirelyStationaryRouteIsRejected() {
        let allSame = CoordinatePasteParser.parse("25.1,121.7\n25.1,121.7")
        #expect(allSame.coordinates.count == 2 && allSame.isValid)
        #expect(!allSame.canCreateRoute)
        let route = CoordinatePasteParser.parse("25.1,121.7\n25.1,121.7\n25.2,121.8\n25.1,121.7")
        #expect(route.canCreateRoute && route.coordinates.count == 4)
        #expect(route.coordinates.first?.latitude == route.coordinates.last?.latitude)
    }

    @Test func oversizedPasteCannotPartiallyApplyTruncatedRoute() {
        let atLimit = (0..<CoordinatePasteParser.maximumPointCount).map { "25.\($0),121.7" }.joined(separator: "\n")
        let allowed = CoordinatePasteParser.parse(atLimit)
        #expect(allowed.canCreateRoute && !allowed.exceedsLimit)
        let tooMany = CoordinatePasteParser.parse(atLimit + "\n25.4,121.8")
        #expect(tooMany.exceedsLimit && tooMany.limitMessage != nil)
        #expect(tooMany.nonemptyLineCount == CoordinatePasteParser.maximumPointCount + 1)
        #expect(!tooMany.isValid && !tooMany.canCreateRoute && !tooMany.canApplyCoordinate)
    }

    private static let sample = """
    25.097467, 121.712822
    25.140071, 121.709084
    25.127901, 121.736764
    25.127658, 121.742311
    25.120645, 121.723095
    25.144918, 121.726561
    25.136060, 121.786835
    25.081714, 121.695951
    25.045210, 121.516140
    25.046086, 121.513379
    25.043461, 121.523968
    25.044278, 121.508594
    25.041508, 121.545018
    25.082686, 121.546370
    25.060373, 121.525384
    25.027568, 121.563322
    25.052054, 121.555007
    25.057341, 121.517810
    25.059314, 121.617931
    """
}
