import Foundation

@main
enum JITExecutionModeTests {
    static func main() throws {
        var count = 0
        for presence in [true, false, nil] as [Bool?] {
            let mode = try JITExecutionMode.select(forceScript: true, isTXMPresent: presence)
            precondition(mode == .script)
            count += 1
        }
        let txmMode = try JITExecutionMode.select(forceScript: false, isTXMPresent: true)
        let nonTXMMode = try JITExecutionMode.select(forceScript: false, isTXMPresent: false)
        precondition(txmMode == .script)
        precondition(nonTXMMode == .attachDetach)
        count += 2
        do {
            _ = try JITExecutionMode.select(forceScript: false, isTXMPresent: nil)
            preconditionFailure("Unknown TXM cannot silently become a non-TXM attach/detach operation")
        } catch StikJITError.txmDetectionUnavailable { count += 1 }
        print("\(count) JIT execution mode tests passed")
    }
}
