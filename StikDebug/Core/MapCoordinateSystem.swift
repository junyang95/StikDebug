import CoreLocation
import Foundation

/// Stored locations, GPX and simulation commands always use WGS-84.
/// Only MapKit input/output is converted when its displayed map uses GCJ-02.
enum MapCoordinateSystem: String, CaseIterable {
    case wgs84
    case gcj02

    static let storageKey = "mapCoordinateSystem"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .wgs84
    }

    func toMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard self == .gcj02, Self.isInCoverage(coordinate) else { return coordinate }
        return Self.shift(coordinate)
    }

    func fromMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard self == .gcj02, Self.isInCoverage(coordinate) else { return coordinate }
        var result = coordinate
        // Iterative inverse keeps round trips accurate to well below a meter.
        for _ in 0..<8 {
            let projected = Self.shift(result)
            let latitudeError = projected.latitude - coordinate.latitude
            let longitudeError = projected.longitude - coordinate.longitude
            result.latitude -= latitudeError
            result.longitude -= longitudeError
            if max(abs(latitudeError), abs(longitudeError)) < 1e-9 { break }
        }
        return result
    }

    private static func isInCoverage(_ p: CLLocationCoordinate2D) -> Bool {
        // This is a transform coverage guard, NOT a provider/region detector.
        // Some China map providers also shift their Hong Kong/Macau tiles.
        // Taiwan, Japan and other common overseas destinations stay unchanged.
        CLLocationCoordinate2DIsValid(p)
            && (72.004...137.8347).contains(p.longitude)
            && (0.8293...55.8271).contains(p.latitude)
            && !((119.3...122.1).contains(p.longitude) && (21.8...25.6).contains(p.latitude))
    }

    private static func shift(_ p: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = p.longitude - 105
        let y = p.latitude - 35
        var lat = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        lat += (20*sin(6*x * .pi) + 20*sin(2*x * .pi)) * 2/3
        lat += (20*sin(y * .pi) + 40*sin(y/3 * .pi)) * 2/3
        lat += (160*sin(y/12 * .pi) + 320*sin(y * .pi/30)) * 2/3
        var lon = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        lon += (20*sin(6*x * .pi) + 20*sin(2*x * .pi)) * 2/3
        lon += (20*sin(x * .pi) + 40*sin(x/3 * .pi)) * 2/3
        lon += (150*sin(x/12 * .pi) + 300*sin(x/30 * .pi)) * 2/3
        let radians = p.latitude * .pi/180
        let eccentricity = 0.00669342162296594323
        let magic = 1 - eccentricity * pow(sin(radians), 2)
        let root = sqrt(magic)
        lat = lat * 180 / ((6378245 * (1 - eccentricity)) / (magic * root) * .pi)
        lon = lon * 180 / (6378245 / root * cos(radians) * .pi)
        return CLLocationCoordinate2D(latitude: p.latitude + lat, longitude: p.longitude + lon)
    }
}
