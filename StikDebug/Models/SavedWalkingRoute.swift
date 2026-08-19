import CoreLocation
import Foundation

/// 保存下来的连点路径，只存用户点的那几个点，载入时重新规划步行路线。
struct SavedWalkingRoute: Identifiable, Codable, Equatable {
    struct Point: Codable, Equatable {
        var latitude: Double
        var longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        }
    }

    var id: UUID
    var name: String
    var points: [Point]
    var isLoop: Bool
    var createdAt: Date
    /// Optional 保持兼容旧版本已经保存、没有该字段的 JSON。
    var planningStyleRawValue: String?
    /// 导入/手绘轨迹要原样保存全部几何点；旧版路线没有该字段，按途经点重新规划。
    var preservesExactPathValue: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        coordinates: [CLLocationCoordinate2D],
        isLoop: Bool,
        planningStyle: RoutePlanningStyle = .footpaths,
        preservesExactPath: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        points = coordinates.map(Point.init)
        self.isLoop = isLoop
        self.createdAt = createdAt
        planningStyleRawValue = planningStyle.rawValue
        preservesExactPathValue = preservesExactPath
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    var planningStyle: RoutePlanningStyle {
        RoutePlanningStyle(rawValue: planningStyleRawValue ?? "") ?? .footpaths
    }

    var preservesExactPath: Bool {
        preservesExactPathValue ?? false
    }
}

/// 用 UserDefaults 存路径，和既有的地点书签保持一致的做法。
enum SavedWalkingRouteStore {
    private static let key = "savedWalkingRoutes"

    static func load() -> [SavedWalkingRoute] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedWalkingRoute].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ routes: [SavedWalkingRoute]) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
