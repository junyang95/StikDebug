import CoreLocation
import Foundation

/// Advances by traveled distance, independent of timer cadence or device I/O.
/// The final partial tick consumes only the distance left before the endpoint.
struct RouteTraversal {
    struct Advance {
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance
        let reachedEnd: Bool
    }

    let coordinates: [CLLocationCoordinate2D]
    let endBehavior: RouteEndBehavior
    let totalDistance: CLLocationDistance
    /// One immutable measurement per input leg, shared by progress and playback.
    let segmentDistances: [CLLocationDistance]
    private(set) var coordinate: CLLocationCoordinate2D
    private(set) var hasReachedEnd = false
    private var targetIndex = 1
    private var direction = 1
    private var segmentStart: CLLocationCoordinate2D
    private var segmentDistance: CLLocationDistance
    private var segmentRemaining: CLLocationDistance
    private let closingDistance: CLLocationDistance
    private let cycleDistance: CLLocationDistance

    init?(coordinates: [CLLocationCoordinate2D], endBehavior: RouteEndBehavior) {
        var points: [CLLocationCoordinate2D] = []
        for point in coordinates where CLLocationCoordinate2DIsValid(point) {
            if let last = points.last,
               last.latitude == point.latitude && last.longitude == point.longitude { continue }
            points.append(point)
        }
        guard points.count > 1 else { return nil }
        let distances = zip(points, points.dropFirst()).map { Self.distance($0.0, $0.1) }
        let total = distances.reduce(0, +)
        guard total > 0, total.isFinite else { return nil }
        self.coordinates = points
        self.endBehavior = endBehavior
        totalDistance = total
        segmentDistances = distances
        coordinate = points[0]
        segmentStart = points[0]
        segmentDistance = distances[0]
        segmentRemaining = distances[0]
        closingDistance = points.count == 2 ? distances[0] : Self.distance(points.last!, points[0])
        cycleDistance = endBehavior == .reverse ? total * 2 : total + closingDistance
    }

    mutating func advance(distance requestedDistance: CLLocationDistance) -> Advance {
        guard requestedDistance.isFinite, requestedDistance > 0, !hasReachedEnd else {
            return Advance(coordinate: coordinate, distance: 0, reachedEnd: hasReachedEnd)
        }
        var remaining = requestedDistance
        var traveled = 0.0
        // Full circuits return to exactly the same cursor state. Skipping them
        // also makes short looping routes safe at high speeds or after a late tick.
        if endBehavior != .stopAtEnd, remaining >= cycleDistance {
            remaining = remaining.truncatingRemainder(dividingBy: cycleDistance)
            traveled = requestedDistance - remaining
        }

        while remaining > 0, !hasReachedEnd {
            let target = coordinates[targetIndex]
            if remaining < segmentRemaining {
                segmentRemaining -= remaining
                // CLLocation measures an ellipsoidal distance. Interpolate a fraction
                // of the whole segment instead of repeatedly advancing spherical
                // meters, which otherwise accumulates an endpoint jump on long legs.
                coordinate = Self.interpolate(
                    from: segmentStart,
                    to: target,
                    fraction: 1 - segmentRemaining / segmentDistance
                )
                traveled += remaining
                remaining = 0
            } else {
                coordinate = target
                remaining -= segmentRemaining
                traveled += segmentRemaining
                if endBehavior == .stopAtEnd, targetIndex == coordinates.count - 1 {
                    hasReachedEnd = true
                    break
                }
                let previousIndex = targetIndex
                if endBehavior == .loop {
                    targetIndex = (targetIndex + 1) % coordinates.count
                } else if direction > 0, targetIndex == coordinates.count - 1 {
                    direction = -1
                    targetIndex -= 1
                } else if direction < 0, targetIndex == 0 {
                    direction = 1
                    targetIndex = 1
                } else {
                    targetIndex += direction
                }
                segmentStart = coordinate
                // Reuse the same length in either direction. Separate OS distance
                // queries can differ slightly and must not drift from totalDistance.
                segmentDistance = abs(previousIndex - targetIndex) == 1
                    ? segmentDistances[min(previousIndex, targetIndex)]
                    : closingDistance
                segmentRemaining = segmentDistance
            }
        }
        return Advance(coordinate: coordinate, distance: traveled, reachedEnd: hasReachedEnd)
    }

    private static func distance(_ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }

    private static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let latitudeDelta = endLatitude - startLatitude
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let haversine = min(max(
            pow(sin(latitudeDelta / 2), 2)
                + cos(startLatitude) * cos(endLatitude) * pow(sin(longitudeDelta / 2), 2),
            0
        ), 1)
        let angle = 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
        let point = MovementMath.destination(
            from: start,
            distance: angle * 6_371_000 * min(max(fraction, 0), 1),
            bearingDegrees: MovementMath.bearing(from: start, to: end)
        )
        // Crossing the date line must continue through ±180°, not across the map.
        let longitude = (point.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: longitude)
    }
}
