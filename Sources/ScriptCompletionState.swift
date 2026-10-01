import Foundation

/// JavaScript returning normally is not evidence of a completed JIT operation.
/// This state only advances on acknowledged debugger commands, and requires
/// successful prepare_memory_region work between attachment and the script's
/// explicit detachment. Arbitrary debugger writes do not prove JIT preparation.
struct ScriptCompletionState {
    private(set) var isAttached = false
    private var didAttach = false
    private var didPrepareMemory = false
    private var didDetach = false

    mutating func recordCommand(_ command: String, response: String?) throws {
        try DebugAttachResponse.validateScriptCommand(command, response: response)
        if command.hasPrefix("vAttach;") {
            isAttached = true
            didAttach = true
            didPrepareMemory = false
            didDetach = false
        } else if command == "D" {
            // A bare D response from an unattached session proves nothing.
            didDetach = isAttached
            isAttached = false
        }
    }

    mutating func recordMemoryPreparation(length: UInt64) {
        if isAttached && length > 0 { didPrepareMemory = true }
    }

    func validateCompletion() throws {
        guard didAttach else {
            throw StikJITError.scriptExecution("The script finished without successfully attaching to the target process.")
        }
        guard !isAttached, didDetach else {
            throw StikJITError.scriptExecution("The script finished without confirming detachment from the target process.")
        }
        guard didPrepareMemory else {
            throw StikJITError.scriptExecution("The script finished without successfully preparing a nonempty JIT region with prepare_memory_region.")
        }
    }
}
