import CoreLocation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PikminRuntime

struct CoordinateImportTests {
    @Test func pickerAcceptsGPXFromGenericAndDynamicProviderTypes() throws {
        let fileType = try #require(UTType(filenameExtension: "gpx", conformingTo: .data))
        let providerType = try #require(UTType(tag: "application/x-provider-gpx", tagClass: .mimeType, conformingTo: .data))
        for type in [UTType.data, fileType, providerType, .xml] {
            #expect(CoordinateImportParser.supportedContentTypes.contains { type.conforms(to: $0) }, "Type: \(type.identifier), conforms to data: \(type.conforms(to: .data))")
        }
        #expect(!CoordinateImportParser.supportedContentTypes.contains { UTType.folder.conforms(to: $0) })
    }

    @Test func exportedGPXImportsWithoutChangingWGS84Coordinates() throws {
        let expected = [CLLocationCoordinate2D(latitude: 22.2918, longitude: 114.179),
                        CLLocationCoordinate2D(latitude: 22.292, longitude: 114.1795)]
        let xml = GPXRouteDocument.xml(name: "香港 & 海边", coordinates: expected, createdAt: Date(timeIntervalSince1970: 0))
        let actual = try parse(xml, extension: "gpx")
        #expect(actual.count == 2)
        #expect(actual.map(\.latitude) == expected.map(\.latitude))
        #expect(actual.map(\.longitude) == expected.map(\.longitude))
    }

    @Test func uppercaseGPXExtensionImportsRoutePoints() throws {
        let points = try parse("<gpx><rte><rtept lat=\"25.03\" lon=\"121.56\"/><rtept lat=\"25.04\" lon=\"121.57\"/></rte></gpx>", extension: "GPX")
        #expect(points.count == 2)
        #expect(points.first?.latitude == 25.03 && points.last?.longitude == 121.57)
    }

    @Test func singleWaypointGPXImportsAsOneLocation() throws {
        let points = try parse("<gpx><wpt lat=\"35.68\" lon=\"139.76\"/></gpx>", extension: "gpx")
        #expect(points.count == 1 && points.first?.longitude == 139.76)
    }

    @Test func malformedGPXCannotTurnXMLMetadataIntoCoordinates() {
        #expect(throws: CoordinateImportError.self) {
            try parse("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx><trkpt lat=\"22.29\" lon=\"114.17\"/>", extension: "gpx")
        }
    }

    @Test func GPXWithOnlyMetadataDoesNotCreateAFakeRoute() {
        #expect(throws: CoordinateImportError.self) {
            try parse("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx><metadata><name>Route 22.29, 114.17</name></metadata></gpx>", extension: "gpx")
        }
    }

    @Test func unsupportedFilesRemainRejectedAfterPickerBroadening() {
        #expect(throws: CoordinateImportError.self) { try parse("22.2918,114.1790", extension: "jpg") }
        #expect(throws: CoordinateImportError.self) { try parse("", extension: "gpx") }
    }

    @Test func KMLImportPreservesLongitudeLatitudeOrder() throws {
        let points = try parse("<kml><LineString><coordinates>114.179,22.2918,0 114.180,22.292,0</coordinates></LineString></kml>", extension: "kml")
        #expect(points.count == 2 && points.first?.latitude == 22.2918 && points.first?.longitude == 114.179)
    }

    @Test func geoJSONImportPreservesLongitudeLatitudeOrder() throws {
        let points = try parse(#"{"type":"LineString","coordinates":[[114.179,22.2918],[114.180,22.292]]}"#, extension: "geojson")
        #expect(points.count == 2 && points.first?.latitude == 22.2918 && points.last?.longitude == 114.180)
    }

    @Test func textCoordinateFormatsStillImport() throws {
        let csv = try parse("lon,lat\n114.179,22.2918\n114.180,22.292", extension: "csv")
        let text = try parse("22.2918 114.179\n22.292 114.180", extension: "txt")
        #expect(csv.map(\.latitude) == text.map(\.latitude) && csv.count == 2)
        #expect(csv.map(\.longitude) == text.map(\.longitude))
    }

    private func parse(_ text: String, extension suffix: String) throws -> [CLLocationCoordinate2D] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("路线.\(suffix)")
        try Data(text.utf8).write(to: url)
        return try CoordinateImportParser.parse(url: url)
    }
}
