import CoreLocation
import Testing
@testable import PikminRuntime

struct RouteTraversalTests {
    private let first = CLLocationCoordinate2D(latitude: 25.097467, longitude: 121.712822)

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    @Test func onePassVisitsEveryPointInOrderAndConsumesOnlyTheDistanceRemaining() throws {
        let second = MovementMath.offset(first, eastMeters: 8, northMeters: 0)
        let last = MovementMath.offset(second, eastMeters: 0, northMeters: 6)
        var route = try #require(RouteTraversal(coordinates: [first, second, last], endBehavior: .stopAtEnd))
        let firstLeg = route.segmentDistances[0]
        let secondLeg = route.segmentDistances[1]
        let middle = route.advance(distance: firstLeg)
        #expect(middle.coordinate.latitude == second.latitude && middle.coordinate.longitude == second.longitude)
        #expect(!middle.reachedEnd)
        let end = route.advance(distance: 100_000)
        #expect(end.coordinate.latitude == last.latitude && end.coordinate.longitude == last.longitude)
        #expect(end.reachedEnd)
        #expect(abs(end.distance - secondLeg) < 0.000_001)
        #expect(abs(route.totalDistance - firstLeg - secondLeg) < 0.000_001)
        let afterEnd = route.advance(distance: 100)
        #expect(afterEnd.distance == 0 && afterEnd.reachedEnd)
        #expect(afterEnd.coordinate.latitude == last.latitude && afterEnd.coordinate.longitude == last.longitude)
    }

    @Test func partialTicksAccumulateToExactlyOnePass() throws {
        let last = MovementMath.offset(first, eastMeters: 12, northMeters: 4)
        var route = try #require(RouteTraversal(coordinates: [first, last], endBehavior: .stopAtEnd))
        let partial = route.advance(distance: route.totalDistance * 0.4)
        #expect(!partial.reachedEnd)
        let final = route.advance(distance: route.totalDistance)
        #expect(final.reachedEnd)
        #expect(abs(partial.distance + final.distance - route.totalDistance) < 0.000_001)
        #expect(final.coordinate.latitude == last.latitude && final.coordinate.longitude == last.longitude)
    }

    @Test func reverseKeepsMovingBackAfterTheEndpoint() throws {
        let last = MovementMath.offset(first, eastMeters: 10, northMeters: 0)
        var route = try #require(RouteTraversal(coordinates: [first, last], endBehavior: .reverse))
        let end = route.advance(distance: route.totalDistance)
        #expect(!end.reachedEnd)
        #expect(end.coordinate.longitude == last.longitude)
        let returning = route.advance(distance: 2)
        #expect(!returning.reachedEnd && returning.distance == 2)
        #expect(returning.coordinate.longitude < last.longitude && returning.coordinate.longitude > first.longitude)
    }

    @Test func loopingShortRouteCanAdvanceSeveralCircuitsInOneTick() throws {
        let second = MovementMath.offset(first, eastMeters: 0.2, northMeters: 0)
        var route = try #require(RouteTraversal(coordinates: [first, second, first], endBehavior: .loop))
        let distance = route.totalDistance * 10 + route.totalDistance / 4
        let step = route.advance(distance: distance)
        #expect(!step.reachedEnd)
        #expect(abs(step.distance - distance) < 0.000_001)
        #expect(step.coordinate.longitude > first.longitude && step.coordinate.longitude < second.longitude)
    }

    @Test func repeatedAdjacentPointsDoNotPreventCompletion() throws {
        let last = MovementMath.offset(first, eastMeters: 2, northMeters: 0)
        var route = try #require(RouteTraversal(coordinates: [first, first, last, last], endBehavior: .stopAtEnd))
        let end = route.advance(distance: 100)
        #expect(end.reachedEnd)
        #expect(end.coordinate.latitude == last.latitude && end.coordinate.longitude == last.longitude)
        #expect(RouteTraversal(coordinates: [first, first], endBehavior: .stopAtEnd) == nil)
    }

    @Test func sparseLongLegsStayContinuousAtTheSelectedSpeedThroughTheFinalTick() throws {
        let legs: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            (first, CLLocationCoordinate2D(latitude: 25.140071, longitude: 121.709084)),
            (CLLocationCoordinate2D(latitude: 25.081714, longitude: 121.695951),
             CLLocationCoordinate2D(latitude: 25.045210, longitude: 121.516140))
        ]
        let metersPerTick = 5.0 / 3.6
        for (start, end) in legs {
            var route = try #require(RouteTraversal(coordinates: [start, end], endBehavior: .stopAtEnd))
            var previous = start
            var largestPhysicalStep = 0.0
            var finalPhysicalStep = 0.0
            var finalCountedStep = 0.0
            var countedDistance = 0.0
            while !route.hasReachedEnd {
                let step = route.advance(distance: metersPerTick)
                let physicalStep = distance(previous, step.coordinate)
                largestPhysicalStep = max(largestPhysicalStep, physicalStep)
                countedDistance += step.distance
                previous = step.coordinate
                if step.reachedEnd {
                    finalPhysicalStep = physicalStep
                    finalCountedStep = step.distance
                }
            }
            #expect(largestPhysicalStep <= metersPerTick * 1.02 + 0.001)
            #expect(finalPhysicalStep <= finalCountedStep * 1.02 + 0.001)
            #expect(abs(countedDistance - route.totalDistance) < 0.000_001)
            #expect(route.coordinate.latitude == end.latitude && route.coordinate.longitude == end.longitude)
        }
    }

    @Test func interpolationCrossesTheDateLineWithoutTakingTheLongWayAround() throws {
        let start = CLLocationCoordinate2D(latitude: 25, longitude: 179.99)
        let end = CLLocationCoordinate2D(latitude: 25, longitude: -179.99)
        var route = try #require(RouteTraversal(coordinates: [start, end], endBehavior: .stopAtEnd))
        let halfway = route.advance(distance: route.totalDistance / 2)
        #expect(CLLocationCoordinate2DIsValid(halfway.coordinate))
        #expect(abs(halfway.coordinate.longitude) > 179.99)
        #expect(abs(distance(start, halfway.coordinate) - route.totalDistance / 2) < 0.05)
        let final = route.advance(distance: route.totalDistance)
        #expect(final.reachedEnd)
        #expect(final.coordinate.latitude == end.latitude && final.coordinate.longitude == end.longitude)
    }

    @Test func nineteenPointExampleVisitsEachCoordinateWithoutReordering() throws {
        let points = [
            (25.097467, 121.712822), (25.140071, 121.709084), (25.127901, 121.736764),
            (25.127658, 121.742311), (25.120645, 121.723095), (25.144918, 121.726561),
            (25.136060, 121.786835), (25.081714, 121.695951), (25.045210, 121.516140),
            (25.046086, 121.513379), (25.043461, 121.523968), (25.044278, 121.508594),
            (25.041508, 121.545018), (25.082686, 121.546370), (25.060373, 121.525384),
            (25.027568, 121.563322), (25.052054, 121.555007), (25.057341, 121.517810),
            (25.059314, 121.617931)
        ].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        var route = try #require(RouteTraversal(coordinates: points, endBehavior: .stopAtEnd))
        for index in 1..<points.count {
            let step = route.advance(distance: route.segmentDistances[index - 1])
            #expect(step.coordinate.latitude == points[index].latitude)
            #expect(step.coordinate.longitude == points[index].longitude)
            #expect(step.reachedEnd == (index == points.count - 1))
        }
    }
}
