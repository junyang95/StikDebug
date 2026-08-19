import ActivityKit
import Foundation

struct PikminSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var steps: Int
        var distanceMeters: Double
        var speedKilometersPerHour: Double
        var latitude: Double
        var longitude: Double

        var distanceKilometers: Double { distanceMeters / 1_000 }
    }

    var mode: String
    var startedAt: Date
}
