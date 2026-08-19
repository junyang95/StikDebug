import CoreLocation
import Foundation

struct RecentLocation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var lastUsedAt: Date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RecentLocationStore {
    static let storageKey = "recentSimulationLocations"
    static let maximumCount = 12
    static let deduplicationDistanceMeters: CLLocationDistance = 25

    static func load(from defaults: UserDefaults = .standard) -> [RecentLocation] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentLocation].self, from: data) else {
            return []
        }
        return Array(decoded.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(maximumCount))
    }

    @discardableResult
    static func record(
        _ coordinate: CLLocationCoordinate2D,
        name: String? = nil,
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> [RecentLocation] {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return load(from: defaults) }
        var locations = load(from: defaults)
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let existingIndex = locations.firstIndex { item in
            target.distance(from: CLLocation(latitude: item.latitude, longitude: item.longitude))
                <= deduplicationDistanceMeters
        }
        let existing = existingIndex.map { locations.remove(at: $0) }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? existing?.name
            ?? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)

        locations.insert(
            RecentLocation(
                id: existing?.id ?? UUID(),
                name: resolvedName,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                lastUsedAt: date
            ),
            at: 0
        )
        locations = Array(locations.prefix(maximumCount))
        save(locations, to: defaults)
        return locations
    }

    static func save(_ locations: [RecentLocation], to defaults: UserDefaults = .standard) {
        let normalized = Array(locations.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(maximumCount))
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
