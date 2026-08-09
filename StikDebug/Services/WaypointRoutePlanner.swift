import CoreLocation
import Foundation
import MapKit

/// 用户在地图上依次点出的途经点。相邻两个途经点之间规划一段 leg。
struct RouteWaypoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: RouteWaypoint, rhs: RouteWaypoint) -> Bool {
        lhs.id == rhs.id
    }
}

enum RouteLegStatus: Equatable {
    /// 正在向 MapKit 请求步行路线。
    case planning
    /// MapKit 返回了真实步行路线。
    case walking
    /// 没有可用步行路线（跨水域、离线、海外地区等），退回两点直线。
    case straightLine
    /// 来自导入文件的轨迹，本身就是完整路径，不经过路线规划。
    case imported
}

struct RouteLeg: Identifiable {
    let id: UUID
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
    var status: RouteLegStatus
}

struct RouteLegPolyline: Identifiable {
    let id: UUID
    let polyline: MKPolyline
    let isStraightLine: Bool
}

/// 把「在地图上点几个点」变成一条可以直接交给 `WalkingSessionController` 的连续路径。
///
/// 每加一个点只规划新增的那一段，不重算整条路线，避免连点时反复打 MapKit 接口。
@MainActor
final class WaypointRoutePlanner: ObservableObject {
    @Published private(set) var waypoints: [RouteWaypoint] = []
    @Published private(set) var legs: [RouteLeg] = []

    /// 打开后补一段「终点回起点」，行走时绕圈而不是原路折返。
    @Published var isLoop = false {
        didSet {
            guard isLoop != oldValue else { return }
            refreshClosingLeg()
        }
    }

    /// 闭环补上的那一段，单独存放，避免和用户点出来的分段混在一起。
    @Published private(set) var closingLeg: RouteLeg?

    /// 导入的轨迹整条使用，不能再用地图连点编辑，避免把文件里的几百个点搞乱。
    @Published private(set) var importedName: String?

    var isImported: Bool { importedName != nil }

    /// 导入轨迹的原始点数，用于如实告诉用户这条路径有多细。
    var importedPointCount: Int {
        legs.first(where: { $0.status == .imported })?.coordinates.count ?? 0
    }

    private var planningTasks: [UUID: Task<Void, Never>] = [:]

    /// 与既有路线播放保持一致的采样间隔。
    private let samplingDistance: CLLocationDistance = 10

    // MARK: - 状态

    var isEmpty: Bool { waypoints.isEmpty }

    /// 闭环至少需要三个点，两个点绕圈和原路折返没有区别。
    /// 导入轨迹只有首尾两个标记，但中间有完整几何，同样可以闭合。
    var canLoop: Bool { waypoints.count >= 3 || isImported }

    private var allLegs: [RouteLeg] {
        legs + (closingLeg.map { [$0] } ?? [])
    }

    var isPlanning: Bool { allLegs.contains { $0.status == .planning } }

    var straightLineLegCount: Int {
        allLegs.filter { $0.status == .straightLine }.count
    }

    var totalDistance: CLLocationDistance {
        allLegs.reduce(0) { $0 + $1.distance }
    }

    /// 至少两个点、且所有分段都规划完成后才允许开始行走。
    var isReady: Bool {
        waypoints.count >= 2 && !isPlanning && !legs.isEmpty
    }

    /// 实际生效的闭环（点数够、分段也规划出来了）。
    var isClosedLoop: Bool { isLoop && closingLeg != nil }

    func estimatedTravelTime(speedMetersPerSecond: CLLocationSpeed) -> TimeInterval {
        guard speedMetersPerSecond > 0 else { return 0 }
        return totalDistance / speedMetersPerSecond
    }

    /// 展平后的行走坐标，去掉分段接缝处的重复点。
    var playbackCoordinates: [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for leg in allLegs {
            for coordinate in leg.coordinates {
                if let last = result.last, isSameCoordinate(last, coordinate) { continue }
                result.append(coordinate)
            }
        }
        return result
    }

    var legPolylines: [RouteLegPolyline] {
        allLegs.compactMap { leg in
            guard leg.coordinates.count > 1 else { return nil }
            let polyline = leg.coordinates.withUnsafeBufferPointer { buffer -> MKPolyline? in
                guard let baseAddress = buffer.baseAddress else { return nil }
                return MKPolyline(coordinates: baseAddress, count: buffer.count)
            }
            guard let polyline else { return nil }
            return RouteLegPolyline(
                id: leg.id,
                polyline: polyline,
                isStraightLine: leg.status == .straightLine
            )
        }
    }

    var boundingMapRect: MKMapRect? {
        let rect = legPolylines.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
        return rect.isNull ? nil : rect
    }

    /// 分段还在规划时也能用的取景范围，直接由途经点算出，四周留一点边距。
    var waypointsBoundingMapRect: MKMapRect? {
        guard !waypoints.isEmpty else { return nil }
        let rect = waypoints.reduce(MKMapRect.null) { partial, waypoint in
            let point = MKMapPoint(waypoint.coordinate)
            return partial.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return nil }
        return rect.insetBy(
            dx: -(rect.width * 0.2) - 300,
            dy: -(rect.height * 0.2) - 300
        )
    }

    // MARK: - 编辑

    func append(_ coordinate: CLLocationCoordinate2D) {
        guard !isImported, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let previous = waypoints.last
        waypoints.append(RouteWaypoint(coordinate: coordinate))

        if let previous {
            let leg = RouteLeg(id: UUID(), coordinates: [], distance: 0, status: .planning)
            legs.append(leg)
            planLeg(id: leg.id, from: previous.coordinate, to: coordinate)
        }
        refreshClosingLeg()
    }

    func removeLast() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        if let leg = legs.popLast() {
            planningTasks.removeValue(forKey: leg.id)?.cancel()
        }
        refreshClosingLeg()
    }

    func clear() {
        for task in planningTasks.values { task.cancel() }
        planningTasks = [:]
        waypoints = []
        legs = []
        closingLeg = nil
        importedName = nil
    }

    /// 载入 GPX/KML/JSON 导入的轨迹。文件本身就是完整路径，整条直接采用，
    /// 不能按相邻两点去调用路线规划——否则几百个点会打出几百次请求。
    @discardableResult
    func loadImportedPath(_ coordinates: [CLLocationCoordinate2D], name: String) -> Bool {
        let valid = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard valid.count > 1, let first = valid.first, let last = valid.last else { return false }

        clear()
        waypoints = [RouteWaypoint(coordinate: first), RouteWaypoint(coordinate: last)]
        legs = [
            RouteLeg(
                id: UUID(),
                coordinates: valid,
                distance: Self.distanceAlong(valid),
                status: .imported
            )
        ]
        importedName = name
        return true
    }

    private static func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    /// 载入已保存的路径：整条重建并重新规划。
    func replaceAll(with coordinates: [CLLocationCoordinate2D], isLoop shouldLoop: Bool) {
        clear()
        for coordinate in coordinates {
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let previous = waypoints.last
            waypoints.append(RouteWaypoint(coordinate: coordinate))
            guard let previous else { continue }
            let leg = RouteLeg(id: UUID(), coordinates: [], distance: 0, status: .planning)
            legs.append(leg)
            planLeg(id: leg.id, from: previous.coordinate, to: coordinate)
        }
        // 绕过 didSet，避免在这里重复触发一次闭环规划。
        if isLoop != shouldLoop {
            isLoop = shouldLoop
        } else {
            refreshClosingLeg()
        }
    }

    private func refreshClosingLeg() {
        if let existing = closingLeg {
            planningTasks.removeValue(forKey: existing.id)?.cancel()
            closingLeg = nil
        }

        guard isLoop,
              canLoop,
              let first = waypoints.first,
              let last = waypoints.last else {
            return
        }

        let leg = RouteLeg(id: UUID(), coordinates: [], distance: 0, status: .planning)
        closingLeg = leg
        planLeg(id: leg.id, from: last.coordinate, to: first.coordinate)
    }

    // MARK: - 规划

    private func planLeg(
        id: UUID,
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        planningTasks[id] = Task { [weak self] in
            guard let self else { return }
            let resolved: RouteLeg

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else {
                    throw CocoaError(.featureUnsupported)
                }
                let coordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: self.samplingDistance
                )
                resolved = RouteLeg(
                    id: id,
                    coordinates: coordinates,
                    distance: route.distance,
                    status: .walking
                )
            } catch is CancellationError {
                return
            } catch {
                // MapKit 没给出步行路线时退回直线，保证整条路径仍可用。
                let coordinates = sampledRouteCoordinates(
                    from: [start, end],
                    targetDistance: self.samplingDistance
                )
                resolved = RouteLeg(
                    id: id,
                    coordinates: coordinates,
                    distance: CLLocation(latitude: start.latitude, longitude: start.longitude)
                        .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)),
                    status: .straightLine
                )
            }

            guard !Task.isCancelled else { return }
            self.apply(resolved)
        }
    }

    private func apply(_ leg: RouteLeg) {
        planningTasks.removeValue(forKey: leg.id)
        if let index = legs.firstIndex(where: { $0.id == leg.id }) {
            legs[index] = leg
        } else if closingLeg?.id == leg.id {
            closingLeg = leg
        }
    }

    private func isSameCoordinate(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
