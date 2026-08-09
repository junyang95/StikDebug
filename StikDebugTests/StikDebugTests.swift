import CoreLocation
import Testing
@testable import StikDebug

struct PikminHelperTests {
    @Test
    func destinationMovesExpectedDistanceNorth() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let end = MovementMath.destination(
            from: start,
            distance: 100,
            bearingDegrees: 0
        )
        let measured = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

        #expect(abs(measured - 100) < 0.5)
        #expect(end.latitude > start.latitude)
    }

    @Test
    func destinationMovesExpectedBearingEast() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let end = MovementMath.destination(
            from: start,
            distance: 100,
            bearingDegrees: 90
        )

        #expect(end.longitude > start.longitude)
        #expect(abs(end.latitude - start.latitude) < 0.0001)
    }

    @Test
    func jitterOffsetStaysWithinConfiguredRadius() {
        let start = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let offset = MovementMath.offset(start, eastMeters: 1.8, northMeters: 2.0)
        let measured = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: offset.latitude, longitude: offset.longitude))

        #expect(measured < 3)
        #expect(measured > 2)
    }

    @Test
    func defaultWalkingMathMatchesPlan() {
        let config = WalkingSessionConfig(
            startLatitude: 31.2304,
            startLongitude: 121.4737
        )
        let stepsPerKilometer = Int(1_000 / config.strideMeters)

        #expect(abs(config.speedMetersPerSecond - 2.2222) < 0.001)
        #expect(stepsPerKilometer == 1_333)
    }
}
