import CoreLocation
import Foundation

struct CoordinatePasteIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        case invalidFormat
        case outOfRange
    }

    let lineNumber: Int
    let kind: Kind
    var id: Int { lineNumber }

    var message: String {
        let reason: String
        switch kind {
        case .invalidFormat:
            reason = "请只填写一组「纬度, 经度」，不要添加序号或其他文字。".localized
        case .outOfRange:
            reason = "纬度须在 -90～90，经度须在 -180～180。".localized
        }
        return String(format: "第 %1$d 行：%2$@".localized, lineNumber, reason)
    }
}

struct CoordinatePasteResult {
    let coordinates: [CLLocationCoordinate2D]
    let issues: [CoordinatePasteIssue]
    let nonemptyLineCount: Int
    let exceedsLimit: Bool

    var isValid: Bool {
        !exceedsLimit && issues.isEmpty && !coordinates.isEmpty
    }

    var canApplyCoordinate: Bool { isValid && coordinates.count == 1 }

    var canCreateRoute: Bool {
        guard isValid, let first = coordinates.first else { return false }
        return coordinates.dropFirst().contains {
            $0.latitude != first.latitude || $0.longitude != first.longitude
        }
    }

    var totalDistance: CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { result, pair in
            result + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    var limitMessage: String? {
        guard exceedsLimit else { return nil }
        return String(format: "一次最多粘贴 %d 个坐标，请分成多条路线。".localized,
                      CoordinatePasteParser.maximumPointCount)
    }
}

/// The paste editor must not silently discard malformed lines or interpret a
/// list number as latitude. File imports retain their own format-aware parser.
enum CoordinatePasteParser {
    static let maximumPointCount = 1_000

    private static let coordinatePattern = try! NSRegularExpression(
        pattern: #"^\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))(?:\s*[,，]\s*|\s+)([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))\s*$"#
    )

    static func parse(_ text: String) -> CoordinatePasteResult {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (number: index + 1, text: trimmed)
        }
        var coordinates: [CLLocationCoordinate2D] = []
        var issues: [CoordinatePasteIssue] = []

        for line in lines.prefix(maximumPointCount) {
            let range = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            guard let match = coordinatePattern.firstMatch(in: line.text, range: range),
                  let latitudeRange = Range(match.range(at: 1), in: line.text),
                  let longitudeRange = Range(match.range(at: 2), in: line.text),
                  let latitude = Double(line.text[latitudeRange]),
                  let longitude = Double(line.text[longitudeRange]) else {
                issues.append(CoordinatePasteIssue(lineNumber: line.number, kind: .invalidFormat))
                continue
            }

            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                issues.append(CoordinatePasteIssue(lineNumber: line.number, kind: .outOfRange))
                continue
            }
            coordinates.append(coordinate)
        }

        return CoordinatePasteResult(coordinates: coordinates, issues: issues,
                                     nonemptyLineCount: lines.count,
                                     exceedsLimit: lines.count > maximumPointCount)
    }
}
