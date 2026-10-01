import Foundation
import JavaScriptCore
@_implementationOnly import idevice

final class ScriptRunner {

    private static let jitPageSize: UInt64 = 16384
    private static let jitPageCommandLength = 19
    private static let commandsPerBatch = 128

    private let targetPID: Int32
    private let debugProxy: OpaquePointer
    private let script: StikJIT.Script
    private let txmPresence: TXMPresence
    private let progress: (String) -> Void
    private var context: JSContext?
    private var executionError: StikJITError?
    private var completion = ScriptCompletionState()

    init(targetPID: Int32, debugProxy: OpaquePointer, script: StikJIT.Script, txmPresence: TXMPresence, progress: @escaping (String) -> Void) {
        self.targetPID = targetPID
        self.debugProxy = debugProxy
        self.script = script
        self.txmPresence = txmPresence
        self.progress = progress
    }

    func run() throws {
        let source = try BundledScript.source(for: script)

        guard let context = JSContext() else { throw StikJITError.scriptUnavailable }
        self.context = context
        defer {
            if completion.isAttached {
                // A protocol/JavaScript failure must not leave the target stopped.
                _ = sendCommand("D", raiseOnFailure: false)
            }
        }

        context.exceptionHandler = { [weak self] _, value in
            let detail = value?.toString() ?? "unknown JavaScript exception"
            self?.recordExecutionError(.scriptExecution(detail))
        }

        let getPID: @convention(block) () -> Int = { [targetPID] in Int(targetPID) }
        let send: @convention(block) (String?) -> String = { [weak self] command in
            guard let self else { return "" }
            if let error = self.executionError {
                self.fail(error)
                return ""
            }
            guard let command else {
                self.fail(.scriptExecution("The debugger command must be a string."))
                return ""
            }
            return self.sendCommand(command) ?? ""
        }
        let prepare: @convention(block) (Double, Double) -> String = { [weak self] address, length in
            guard let self else { return "" }
            if let error = self.executionError {
                self.fail(error)
                return ""
            }
            guard let address = UInt64(exactly: address), let length = UInt64(exactly: length) else {
                self.fail(.scriptExecution("The JIT memory address and length must be nonnegative integers in range."))
                return ""
            }
            return self.prepareMemoryRegion(address, length: length) ?? ""
        }
        let log: @convention(block) (JSValue?) -> Void = { [weak self] value in
            self?.progress(value?.toString() ?? "")
        }
        let hasTXM: @convention(block) () -> Bool = { [weak self] in
            guard let self else { return false }
            guard let present = self.txmPresence.isPresent else {
                // Unknown must not silently look like a non-TXM device.
                self.fail(.txmDetectionUnavailable)
                return false
            }
            return present
        }
        let resumeApp: @convention(block) () -> String = { [weak self] in
            self?.fail(.scriptExecution("resume_app() is not supported by this launcher script runtime. It requires a foreground app-launch callback; sending a process signal is not an equivalent operation."))
            return ""
        }
        let takeScreenshot: @convention(block) (String?) -> String = { [weak self] _ in
            self?.fail(.scriptExecution("take_screenshot() is not supported by this launcher script runtime."))
            return ""
        }

        context.setObject(getPID,  forKeyedSubscript: "get_pid" as NSString)
        context.setObject(send,    forKeyedSubscript: "send_command" as NSString)
        context.setObject(prepare, forKeyedSubscript: "prepare_memory_region" as NSString)
        context.setObject(log,     forKeyedSubscript: "log" as NSString)
        context.setObject(hasTXM,  forKeyedSubscript: "hasTXM" as NSString)
        context.setObject(resumeApp, forKeyedSubscript: "resume_app" as NSString)
        context.setObject(takeScreenshot, forKeyedSubscript: "take_screenshot" as NSString)

        progress("Running \(script.name) against pid \(targetPID)…")
        context.evaluateScript(source)
        if let executionError { throw executionError }
        // This must precede defer's best-effort cleanup: cleanup cannot turn an
        // incomplete or no-op script into a successfully completed JIT session.
        try completion.validateCompletion()
        progress("JIT script completed: memory preparation and detachment confirmed.")
    }

    private func sendCommand(_ command: String, raiseOnFailure: Bool = true) -> String? {
        if command.hasPrefix("vAttach;"),
           Int32(command.dropFirst("vAttach;".count), radix: 16) != targetPID {
            fail(.scriptExecution("The script tried to attach to a process other than the selected target."), raiseException: raiseOnFailure)
            return nil
        }
        guard let handle = command.withCString({ debugserver_command_new($0, nil, 0) }) else {
            fail(.scriptExecution("Failed to create debugger command."), raiseException: raiseOnFailure)
            return nil
        }
        defer { debugserver_command_free(handle) }
        var response: UnsafeMutablePointer<CChar>?
        defer { if let response { idevice_string_free(response) } }
        if let error = debug_proxy_send_command(debugProxy, handle, &response) {
            fail(IdeviceFFI.consume(error, fallback: "send_command"), raiseException: raiseOnFailure)
            return nil
        }
        let reply = response.map { String(cString: $0) }
        do {
            try completion.recordCommand(command, response: reply)
        } catch {
            fail(error as? StikJITError ?? .scriptExecution(error.localizedDescription), raiseException: raiseOnFailure)
            return nil
        }
        return reply ?? ""
    }

    private func prepareMemoryRegion(_ address: UInt64, length: UInt64) -> String? {
        guard length > 0 else { return "OK" }
        let pageCount = Int((length - 1) / Self.jitPageSize + 1)

        let commandBuffer = Self.makeBlessCommands(startAddress: address, pageCount: pageCount)

        for batchStart in stride(from: 0, to: pageCount, by: Self.commandsPerBatch) {
            let commandsInBatch = min(Self.commandsPerBatch, pageCount - batchStart)
            let byteOffset = batchStart * Self.jitPageCommandLength
            let byteCount = commandsInBatch * Self.jitPageCommandLength

            let sendError = commandBuffer.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                return debug_proxy_send_raw(debugProxy, base.advanced(by: byteOffset), UInt(byteCount))
            }
            if let sendError {
                fail(IdeviceFFI.consume(sendError, fallback: "debug_proxy_send_raw"))
                return nil
            }

            for _ in 0..<commandsInBatch {
                var response: UnsafeMutablePointer<CChar>?
                let readError = debug_proxy_read_response(debugProxy, &response)
                let reply = response.map { String(cString: $0) }
                if let response {
                    idevice_string_free(response)
                }
                if let readError {
                    fail(IdeviceFFI.consume(readError, fallback: "debug_proxy_read_response"))
                    return nil
                }
                do {
                    try DebugAttachResponse.validateMemoryWrite(reply)
                } catch {
                    fail(error as? StikJITError ?? .scriptExecution(error.localizedDescription))
                    return nil
                }
            }
        }

        completion.recordMemoryPreparation(length: length)
        progress("Blessed \(pageCount) JIT page(s) at 0x\(String(address, radix: 16))")
        return "OK"
    }

    private func recordExecutionError(_ error: StikJITError) {
        if executionError == nil {
            executionError = error
            progress(error.localizedDescription)
        }
    }

    private func fail(_ error: StikJITError, raiseException: Bool = true) {
        recordExecutionError(error)
        // Returning an empty string alone lets the bundled register-wait loop
        // continue indefinitely. A native JS exception stops evaluation instead.
        if raiseException, let context {
            context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
        }
    }

    private static func makeBlessCommands(startAddress: UInt64, pageCount: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: pageCount * jitPageCommandLength)

        for page in 0..<pageCount {
            let pageAddress = startAddress + UInt64(page) * jitPageSize
            let start = page * jitPageCommandLength

            buffer[start + 0] = UInt8(ascii: "$")
            buffer[start + 1] = UInt8(ascii: "M")
            writeHexAddress(pageAddress, into: &buffer, at: start + 2)
            buffer[start + 11] = UInt8(ascii: ",")
            buffer[start + 12] = UInt8(ascii: "1")
            buffer[start + 13] = UInt8(ascii: ":")
            buffer[start + 14] = UInt8(ascii: "6")
            buffer[start + 15] = UInt8(ascii: "9")
            buffer[start + 16] = UInt8(ascii: "#")
            writeChecksum(into: &buffer, bodyStart: start + 1, hashIndex: start + 16)
        }

        return buffer
    }

    private static func writeHexAddress(_ address: UInt64, into buffer: inout [UInt8], at index: Int) {
        for nibble in 0..<9 {
            let shift = UInt64((8 - nibble) * 4)
            buffer[index + nibble] = hexDigit(UInt8((address >> shift) & 0xf))
        }
    }

    private static func writeChecksum(into buffer: inout [UInt8], bodyStart: Int, hashIndex: Int) {
        var checksum: UInt8 = 0
        for index in bodyStart..<hashIndex {
            checksum &+= buffer[index]
        }
        buffer[hashIndex + 1] = hexDigit((checksum & 0xf0) >> 4)
        buffer[hashIndex + 2] = hexDigit(checksum & 0x0f)
    }

    private static func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? value + UInt8(ascii: "0") : value - 10 + UInt8(ascii: "a")
    }
}
