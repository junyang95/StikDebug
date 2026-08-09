import CoreLocation
import Foundation
import SwiftData

enum MovementMode: String, CaseIterable, Codable, Identifiable {
    case joystick
    case route
    case fixedLocation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .joystick: "摇杆".localized
        case .route: "路线".localized
        case .fixedLocation: "定点".localized
        }
    }
}

enum SessionGoalKind: String, CaseIterable, Codable, Identifiable {
    case steps
    case distance
    case duration
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps: "步数".localized
        case .distance: "距离".localized
        case .duration: "时长".localized
        case .manual: "手动停止".localized
        }
    }
}

struct WalkingSessionConfig: Codable, Equatable {
    var mode: MovementMode = .joystick
    var goalKind: SessionGoalKind = .steps
    var goalValue: Double = 10_000
    var speedKilometersPerHour: Double = 8
    var strideMeters: Double = 0.75
    var startLatitude: Double
    var startLongitude: Double

    var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude)
    }

    var speedMetersPerSecond: Double {
        speedKilometersPerHour / 3.6
    }
}

enum WalkingSessionPhase: String, Codable {
    case idle
    case preparing
    case running
    case paused
    case completed
    case failed
}

@Model
final class WalkingSessionRecord {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var modeRawValue: String
    var distanceMeters: Double
    var estimatedSteps: Int
    var healthStepsWritten: Int
    var durationSeconds: Double
    var terminationReason: String

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        mode: MovementMode,
        distanceMeters: Double,
        estimatedSteps: Int,
        healthStepsWritten: Int,
        durationSeconds: Double,
        terminationReason: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        modeRawValue = mode.rawValue
        self.distanceMeters = distanceMeters
        self.estimatedSteps = estimatedSteps
        self.healthStepsWritten = healthStepsWritten
        self.durationSeconds = durationSeconds
        self.terminationReason = terminationReason
    }

    var mode: MovementMode {
        MovementMode(rawValue: modeRawValue) ?? .joystick
    }
}
