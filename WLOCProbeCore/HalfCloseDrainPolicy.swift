import Foundation
import Network

enum HalfCloseDrainPolicy {
    /// Fixed from the first qualifying failure; activity cannot extend this deadline.
    static let maximumDuration: TimeInterval = 1

    static func allows(_ error: NWError, writeCloseSubmitted: Bool) -> Bool {
        guard writeCloseSubmitted, case .posix(.ENETDOWN) = error else { return false }
        return true
    }
}
