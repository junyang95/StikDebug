import CoreLocation
import Foundation

enum MovementMath {
    static func destination(
        from coordinate: CLLocationCoordinate2D,
        distance: CLLocationDistance,
        bearingDegrees: Double
    ) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let angularDistance = distance / radius
        let bearing = bearingDegrees * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180

        let nextLatitude = asin(
            sin(latitude) * cos(angularDistance) +
            cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let nextLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(nextLatitude)
        )
        return CLLocationCoordinate2D(
            latitude: nextLatitude * 180 / .pi,
            longitude: nextLongitude * 180 / .pi
        )
    }

    static func offset(
        _ coordinate: CLLocationCoordinate2D,
        eastMeters: Double,
        northMeters: Double
    ) -> CLLocationCoordinate2D {
        let north = destination(
            from: coordinate,
            distance: abs(northMeters),
            bearingDegrees: northMeters >= 0 ? 0 : 180
        )
        return destination(
            from: north,
            distance: abs(eastMeters),
            bearingDegrees: eastMeters >= 0 ? 90 : 270
        )
    }

    static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) -
            sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
