import CoreLocation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

struct GPXRouteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx, .xml] }

    let data: Data

    init(name: String, coordinates: [CLLocationCoordinate2D], createdAt: Date = Date()) {
        data = Data(Self.xml(name: name, coordinates: coordinates, createdAt: createdAt).utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func xml(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        createdAt: Date
    ) -> String {
        let safeName = escapeXML(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let timestamp = ISO8601DateFormatter().string(from: createdAt)
        let points = coordinates
            .filter(CLLocationCoordinate2DIsValid)
            .map { coordinate in
                "      <trkpt lat=\"\(formatted(coordinate.latitude))\" lon=\"\(formatted(coordinate.longitude))\" />"
            }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="StikDebug" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(safeName)</name>
            <time>\(timestamp)</time>
          </metadata>
          <trk>
            <name>\(safeName)</name>
            <trkseg>
        \(points)
            </trkseg>
          </trk>
        </gpx>
        """
    }

    static func suggestedFilename(for name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Pikmin-Helper-Route" : cleaned
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
