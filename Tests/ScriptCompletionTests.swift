import Foundation

@main
enum ScriptCompletionTests {
    static func main() throws {
        var count = 0
        func rejects(_ state: ScriptCompletionState, _ name: String) {
            do { try state.validateCompletion(); preconditionFailure(name) }
            catch { count += 1 }
        }
        func accepts(_ state: ScriptCompletionState) throws {
            try state.validateCompletion()
            count += 1
        }
        rejects(ScriptCompletionState(), "Comment-only JavaScript is not JIT success")
        var outsideAttachment = ScriptCompletionState()
        outsideAttachment.recordMemoryPreparation(length: 16384)
        try outsideAttachment.recordCommand("vAttach;123", response: "S05")
        try outsideAttachment.recordCommand("D", response: "OK")
        rejects(outsideAttachment, "Preparation outside the attachment cannot establish completion")
        var state = ScriptCompletionState()
        try state.recordCommand("qSupported", response: "")
        rejects(state, "Queries alone are not JIT success")
        try state.recordCommand("D", response: "OK")
        rejects(state, "Unpaired detach is not completion")
        try state.recordCommand("vAttach;123", response: "T05thread:1;")
        rejects(state, "Attach alone needs cleanup, not success")
        try state.recordCommand("D", response: "OK")
        rejects(state, "Attach and detach with no memory preparation does not prove TXM JIT")
        try state.recordCommand("vAttach;123", response: "T05thread:1;")
        state.recordMemoryPreparation(length: 0)
        try state.recordCommand("D", response: "OK")
        rejects(state, "Zero length preparation proves nothing")
        try state.recordCommand("vAttach;123", response: "T05thread:1;")
        state.recordMemoryPreparation(length: 16384)
        rejects(state, "Prepared memory still needs explicit detach")
        do {
            try state.recordCommand("D", response: "E01")
            preconditionFailure("Failed detach accepted")
        } catch { count += 1 }
        precondition(state.isAttached, "Failed detach must preserve cleanup obligation")
        try state.recordCommand("D", response: "OK")
        try accepts(state)
        try state.recordCommand("vAttach;123", response: "S05")
        try state.recordCommand("D", response: "OK")
        rejects(state, "Reattachment cannot reuse previous memory preparation")
        try state.recordCommand("vAttach;123", response: "S05")
        try state.recordCommand("M1000,1:69", response: "OK")
        try state.recordCommand("D", response: "OK")
        rejects(state, "Arbitrary acknowledged memory writes do not prove JIT preparation")
        try state.recordCommand("vAttach;123", response: "S05")
        try state.recordCommand("P0=001122;thread:1;", response: "OK")
        try state.recordCommand("D", response: "OK")
        rejects(state, "Register writes do not count as memory preparation")
        try state.recordCommand("vAttach;123", response: "S05")
        do {
            try state.recordCommand("M1000,1:69", response: "E01")
            preconditionFailure("Failed memory write accepted")
        } catch { count += 1 }
        try state.recordCommand("D", response: "OK")
        rejects(state, "Failed memory write does not prove JIT")
        print("\(count) script completion tests passed")
    }
}
