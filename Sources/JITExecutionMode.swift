import Foundation

/// A script can be required by the target application's allocator independently
/// of TXM. Unknown detection never silently selects attach/detach.
enum JITExecutionMode: Equatable {
    case attachDetach
    case script

    static func select(forceScript: Bool, isTXMPresent: Bool?) throws -> Self {
        if forceScript { return .script }
        guard let isTXMPresent else { throw StikJITError.txmDetectionUnavailable }
        return isTXMPresent ? .script : .attachDetach
    }
}
