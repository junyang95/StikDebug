import Foundation

enum PairingPIN {
    /// Keep the original string: converting to Int would drop leading zeroes.
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
