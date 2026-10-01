import Foundation

struct LauncherProfile: Identifiable, Sendable {
    let id: String
    let name: String
    let appIdentifier: String
    let expirationDate: Date?
    let data: Data
}

enum LauncherInput {
    static func coordinate(_ latitude: String, _ longitude: String) -> (Double, Double)? {
        guard !latitude.contains("\0"), !longitude.contains("\0"),
              let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }
}
