import CoreLocation

enum FreehandPathBuilder {
    static let minimumPointSpacingMeters: CLLocationDistance = 3

    @discardableResult
    static func append(
        _ coordinate: CLLocationCoordinate2D,
        to coordinates: inout [CLLocationCoordinate2D],
        minimumSpacing: CLLocationDistance = minimumPointSpacingMeters
    ) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        if let last = coordinates.last {
            let distance = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard distance >= max(minimumSpacing, 0) else { return false }
        }
        coordinates.append(coordinate)
        return true
    }

    static func finalized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let valid = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard valid.count > 1 else { return [] }
        return sampledRouteCoordinates(
            from: valid,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )
    }
}
