import CoreLocation
import Foundation

struct LocationBookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum LocationBookmarkStore {
    static let storageKey = "locationBookmarks"

    static func load(from defaults: UserDefaults = .standard) -> [LocationBookmark] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ bookmarks: [LocationBookmark], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
