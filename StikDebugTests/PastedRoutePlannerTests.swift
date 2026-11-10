import CoreLocation
import Foundation
import Testing
@testable import StikDebug

@MainActor
struct PastedRoutePlannerTests {
    private let coordinates = [
        CLLocationCoordinate2D(latitude: 25.097467, longitude: 121.712822),
        CLLocationCoordinate2D(latitude: 25.140071, longitude: 121.709084),
        CLLocationCoordinate2D(latitude: 25.127901, longitude: 121.736764)
    ]

    @Test func pastedPointsKeepTheirOrderAndNumberingWithoutRoadPlanning() {
        let planner = WaypointRoutePlanner()
        #expect(planner.loadPastedCoordinates(coordinates, name: "三点路线"))
        #expect(planner.isPastedRoute && planner.isImported && planner.isReady)
        #expect(!planner.isPlanning && !planner.isLoop)
        #expect(planner.routeEndBehavior == .stopAtEnd)
        #expect(planner.waypoints.count == 3 && planner.importedPointCount == 3)
        #expect(planner.sourceCoordinates.map(\.latitude) == coordinates.map(\.latitude))
        #expect(planner.sourceCoordinates.map(\.longitude) == coordinates.map(\.longitude))
        #expect(planner.playbackCoordinates.map(\.latitude) == coordinates.map(\.latitude))
        #expect(planner.legs.count == 1 && planner.legs[0].status == .imported)
        let distance = zip(coordinates, coordinates.dropFirst()).reduce(0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        #expect(abs(planner.totalDistance - distance) < 0.001)
        #expect(abs(planner.estimatedTravelTime(speedMetersPerSecond: 2) - distance / 2) < 0.001)
    }

    @Test func pastedLoopClosesDirectlyAndCanReturnToStopOrReverse() {
        let planner = WaypointRoutePlanner()
        #expect(planner.loadPastedCoordinates(coordinates, name: "三点路线"))
        planner.routeEndBehavior = .loop
        #expect(planner.isLoop && planner.isClosedLoop && !planner.isPlanning)
        #expect(planner.closingLeg?.status == .imported)
        #expect(planner.closingLeg?.coordinates.first?.latitude == coordinates.last?.latitude)
        #expect(planner.closingLeg?.coordinates.last?.longitude == coordinates.first?.longitude)
        #expect(planner.sourceCoordinates.count == 3)
        #expect(planner.playbackCoordinates.count == 4)
        planner.routeEndBehavior = .reverse
        #expect(!planner.isLoop && planner.closingLeg == nil)
        #expect(planner.playbackCoordinates.count == 3)
        planner.routeEndBehavior = .loop
        planner.routeEndBehavior = .stopAtEnd
        #expect(!planner.isLoop && planner.closingLeg == nil)
        #expect(planner.routeEndBehavior == .stopAtEnd)
    }

    @Test func invalidPastedListDoesNotReplaceExistingRoute() {
        let planner = WaypointRoutePlanner()
        #expect(planner.loadPastedCoordinates(coordinates, name: "原路线"))
        #expect(!planner.loadPastedCoordinates([coordinates[0]], name: "太短"))
        #expect(!planner.loadPastedCoordinates([coordinates[0], coordinates[0]], name: "同一个点"))
        #expect(!planner.loadPastedCoordinates([
            coordinates[0], CLLocationCoordinate2D(latitude: 91, longitude: 121)
        ], name: "错误坐标"))
        #expect(planner.importedName == "原路线" && planner.waypoints.count == 3)
    }

    @Test func pastedSourcePreservesRepeatedStopsButPlaybackAvoidsZeroLengthDuplicates() {
        let planner = WaypointRoutePlanner()
        let repeated = [coordinates[0], coordinates[0], coordinates[1], coordinates[0]]
        #expect(planner.loadPastedCoordinates(repeated, name: "重复途经点"))
        #expect(planner.sourceCoordinates.count == 4 && planner.waypoints.count == 4)
        #expect(planner.playbackCoordinates.count == 3)
        planner.clear()
        #expect(!planner.isPastedRoute && !planner.isImported && planner.isEmpty)
        #expect(planner.routeEndBehavior == .reverse)
    }

    @Test func pastedRouteRoundTripKeepsPointsAndFinishBehavior() throws {
        let route = SavedWalkingRoute(name: "粘贴路线", coordinates: coordinates, isLoop: false,
                                      isPastedRoute: true)
        let saved = try JSONDecoder().decode(SavedWalkingRoute.self, from: JSONEncoder().encode(route))
        #expect(saved.isPastedRoute && saved.preservesExactPath)
        #expect(saved.routeEndBehavior == .stopAtEnd)
        let planner = WaypointRoutePlanner()
        #expect(planner.loadPastedCoordinates(saved.coordinates, name: saved.name,
                                             endBehavior: saved.routeEndBehavior))
        #expect(planner.waypoints.count == coordinates.count)
        #expect(planner.sourceCoordinates.map(\.longitude) == coordinates.map(\.longitude))
        #expect(planner.routeEndBehavior == .stopAtEnd && !planner.isPlanning)
    }

    @Test func legacySavedRoutesKeepTheirPreviousEndBehavior() throws {
        for isLoop in [false, true] {
            let route = SavedWalkingRoute(name: "旧路线", coordinates: coordinates, isLoop: isLoop)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any])
            object.removeValue(forKey: "isPastedRouteValue")
            object.removeValue(forKey: "routeEndBehaviorRawValue")
            object.removeValue(forKey: "preservesExactPathValue")
            let legacy = try JSONDecoder().decode(SavedWalkingRoute.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!legacy.isPastedRoute && !legacy.preservesExactPath)
            #expect(legacy.routeEndBehavior == (isLoop ? .loop : .reverse))
        }
    }
}
