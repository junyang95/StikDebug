import Foundation

/// The debugger transport can succeed while the remote command returns an error.
/// Only protocol acknowledgements establish that attach and detach succeeded.
enum DebugAttachResponse {
    static func validateAttach(_ response: String?) throws {
        let bytes = Array((response ?? "").utf8)
        guard bytes.count >= 3,
              bytes[0] == 0x54 || (bytes[0] == 0x53 && bytes.count == 3),
              isHexDigit(bytes[1]), isHexDigit(bytes[2]) else {
            throw failure("Debugger did not stop the target process", response: response)
        }
    }

    static func validateDetach(_ response: String?) throws {
        guard response == "OK" else {
            throw failure("Debugger did not confirm detaching from the target process", response: response)
        }
    }

    static func validateMemoryWrite(_ response: String?) throws {
        guard response == "OK" else {
            throw failure("Debugger did not confirm writing the JIT page", response: response)
        }
    }

    static func validateScriptCommand(_ command: String, response: String?) throws {
        // Query commands may legitimately return an empty unsupported response;
        // custom scripts can interpret those without being forced to abort.
        if command.hasPrefix("q") || command.hasPrefix("Q") { return }
        if command.hasPrefix("vAttach;") {
            try validateAttach(response)
        } else if command == "D" {
            try validateDetach(response)
        } else if command.hasPrefix("M") || command.hasPrefix("P") {
            try validateMemoryWrite(response)
        } else if command == "c" || command.hasPrefix("vCont;") {
            // A W/X exit response must stop the script rather than spin forever
            // waiting for registers from a process which no longer exists.
            try validateAttach(response)
        } else {
            let bytes = Array((response ?? "").utf8)
            if bytes.count >= 3, bytes[0] == 0x45,
               isHexDigit(bytes[1]), isHexDigit(bytes[2]),
               bytes.count == 3 || bytes[3] == 0x3B {
                // The semicolon form is the extended RSP error. Longer plain
                // hex data beginning with E must remain valid for memory reads.
                throw failure("Debugger command failed", response: response)
            }
            if (command.hasPrefix("m") || command.hasPrefix("_M")) && bytes.isEmpty {
                throw failure("Debugger returned no memory response", response: response)
            }
        }
    }

    private static func isHexDigit(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value) || (0x41...0x46).contains(value) || (0x61...0x66).contains(value)
    }

    private static func failure(_ message: String, response: String?) -> StikJITError {
        let detail = response.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? "no response"
        return .device(code: -1, subCode: 0, message: "\(message): \(detail)")
    }
}
