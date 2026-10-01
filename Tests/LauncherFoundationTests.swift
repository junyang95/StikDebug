import Foundation

/// Host-side tests exercise real filesystem operations and pure validation only.
/// They do not simulate a successful VPN, pairing handshake, or JIT operation.
@main
enum LauncherFoundationTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    enum RejectedRecord: Error { case incompatible }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func expectError(_ message: String, matches: (Error) -> Bool = { _ in true },
                            _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            try expect(matches(error), "\(message): unexpected error \(error)")
            return
        }
        throw Failure(description: "\(message): operation unexpectedly succeeded")
    }

    static func withStore(_ body: (PairingRecordStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JITLauncherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(PairingRecordStore(directory: root.appendingPathComponent("Pairing")), root)
    }

    static func writePlist(_ dictionary: [String: Any], at url: URL,
                           format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
        try data.write(to: url)
        return data
    }

    static func remainingFiles(_ store: PairingRecordStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
    }

    static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Import stages a private copy before committing", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let expected = try writePlist(["Fixture": "source record"], at: source)
                    var validatorCalls = 0
                    try store.importRecord(from: source) { temporary in
                        validatorCalls += 1
                        try expect(temporary != source && temporary != store.fileURL, "Validator did not receive a temporary copy")
                        try expect(try Data(contentsOf: temporary) == expected, "Staged bytes changed")
                        try expect(try permissions(temporary) == 0o600, "Staged record must be owner-only")
                        try expect(try permissions(store.directory) == 0o700, "Pairing directory must be owner-only")
                        try expect(!store.hasRecord, "Record was committed before validation")
                    }
                    try expect(validatorCalls == 1, "Validator must run exactly once")
                    try expect(store.hasRecord, "Committed record is missing")
                    try expect(try Data(contentsOf: store.fileURL) == expected, "Committed bytes changed")
                    try expect(try permissions(store.fileURL) == 0o600, "Committed record must be owner-only")
                    try expect(try permissions(store.directory) == 0o700, "Pairing directory permissions changed")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Temporary copy was not removed")
                    try expect(try Data(contentsOf: source) == expected, "Source file was modified")
                }
            }),
            ("Validator rejection preserves the previous record", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let previous = try writePlist(["Fixture": "last good record"], at: source)
                    try store.importRecord(from: source) { _ in }
                    _ = try writePlist(["Fixture": "rejected replacement"], at: source)
                    try expectError("Rejected validation", matches: { $0 is RejectedRecord }) {
                        try store.importRecord(from: source) { _ in throw RejectedRecord.incompatible }
                    }
                    try expect(try Data(contentsOf: store.fileURL) == previous, "Rejected import overwrote the previous record")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Rejected temporary file leaked")
                    try expect(try permissions(store.fileURL) == 0o600, "Existing record permissions changed")
                }
            }),
            ("First import rejection leaves no record or temporary file", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": true], at: source)
                    try expectError("First validation rejection", matches: { $0 is RejectedRecord }) {
                        try store.importRecord(from: source) { _ in throw RejectedRecord.incompatible }
                    }
                    try expect(!store.hasRecord, "Rejected record was committed")
                    try expect(try remainingFiles(store).isEmpty, "Rejected temporary file leaked")
                }
            }),
            ("Binary property lists can reach the actual pairing validator", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("binary.plist")
                    let expected = try writePlist(["Fixture": Data([0, 1, 2])], at: source, format: .binary)
                    var called = false
                    try store.importRecord(from: source) { _ in called = true }
                    try expect(called, "Binary plist did not reach the validator")
                    try expect(try Data(contentsOf: store.fileURL) == expected, "Binary plist bytes changed")
                }
            }),
            ("Malformed property lists preserve an existing record", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let previous = try writePlist(["Fixture": "last good record"], at: source)
                    try store.importRecord(from: source) { _ in }
                    try Data("not a property list".utf8).write(to: source)
                    var called = false
                    try expectError("Malformed plist", matches: {
                        if case PairingRecordStore.StoreError.invalidPropertyList = $0 { return true }; return false
                    }) {
                        try store.importRecord(from: source) { _ in called = true }
                    }
                    try expect(!called, "Malformed bytes reached pairing validation")
                    try expect(try Data(contentsOf: store.fileURL) == previous, "Malformed import overwrote the previous record")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Malformed import left temporary files")
                }
            }),
            ("Empty dictionaries and non-dictionary plists are rejected", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    for value in [[:], ["entry"]] as [Any] {
                        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
                        try data.write(to: source)
                        try expectError("Invalid plist root", matches: {
                            if case PairingRecordStore.StoreError.invalidPropertyList = $0 { return true }; return false
                        }) {
                            try store.importRecord(from: source) { _ in throw Failure(description: "Validator should not run") }
                        }
                    }
                    try expect(!store.hasRecord, "Invalid plist root was committed")
                }
            }),
            ("Oversized imports are rejected before pairing validation", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let previous = try writePlist(["Fixture": "last good record"], at: source)
                    try store.importRecord(from: source) { _ in }
                    try Data(repeating: 0, count: PairingRecordStore.maximumBytes + 1).write(to: source)
                    var called = false
                    try expectError("Oversized import", matches: {
                        if case PairingRecordStore.StoreError.tooLarge = $0 { return true }; return false
                    }) {
                        try store.importRecord(from: source) { _ in called = true }
                    }
                    try expect(!called, "Oversized input reached pairing validation")
                    try expect(try Data(contentsOf: store.fileURL) == previous, "Oversized import overwrote the previous record")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Oversized import left temporary files")
                }
            }),
            ("Successful replacement stores the newly validated bytes", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": "old"], at: source)
                    try store.importRecord(from: source) { _ in }
                    let replacement = try writePlist(["Fixture": "new"], at: source)
                    try store.importRecord(from: source) { temporary in
                        try expect(try Data(contentsOf: temporary) == replacement, "Incorrect replacement was validated")
                    }
                    try expect(try Data(contentsOf: store.fileURL) == replacement, "Replacement was not committed")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Replacement left temporary files")
                }
            }),
            ("Removal is idempotent and does not delete the source", {
                try withStore { store, root in
                    try store.removeRecord()
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": "record"], at: source)
                    try store.importRecord(from: source) { _ in }
                    try store.removeRecord()
                    try store.removeRecord()
                    try expect(!store.hasRecord, "Removed record is still readable")
                    try expect(try remainingFiles(store).isEmpty, "Removal left stored files")
                    try expect(FileManager.default.fileExists(atPath: source.path), "Removal deleted the imported source")
                }
            }),
            ("A failed commit removes its temporary copy", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": "record"], at: source)
                    // An existing directory cannot be replaced by a regular file.
                    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
                    var validated = false
                    try expectError("Commit failure", matches: { ($0 as NSError).domain == NSPOSIXErrorDomain }) {
                        try store.importRecord(from: source) { _ in validated = true }
                    }
                    try expect(validated, "Test did not reach the commit step")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Failed commit leaked temporary files")
                    var isDirectory: ObjCBool = false
                    try expect(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                               "Failed commit changed the destination")
                }
            }),
            ("PID accepts positive Int32 values and trims whitespace", {
                try expect(try TargetPIDValidator.validate(" 1234\n", ownPID: 99) == 1234, "Whitespace was not trimmed")
                try expect(try TargetPIDValidator.validate("1", ownPID: 99) == 1, "Small positive PID rejected")
                try expect(try TargetPIDValidator.validate("2147483647", ownPID: 99) == Int32.max, "Maximum PID rejected")
            }),
            ("PID rejects zero, overflow, signs, fractions, and non-ASCII digits", {
                for input in ["", " \n", "0", "-1", "+1", "2147483648", "999999999999999999999", "1.0", "1e3", "12 34", "１２３", "١٢٣"] {
                    try expectError("Invalid PID \(input)", matches: {
                        if case TargetPIDValidator.ValidationError.invalid = $0 { return true }; return false
                    }) {
                        _ = try TargetPIDValidator.validate(input, ownPID: 99)
                    }
                }
            }),
            ("PID rejects the launcher's own process", {
                for input in ["99", " 99\n", "00099"] {
                    try expectError("Own process", matches: {
                        if case TargetPIDValidator.ValidationError.ownProcess = $0 { return true }; return false
                    }) {
                        _ = try TargetPIDValidator.validate(input, ownPID: 99)
                    }
                }
            }),
            ("Default VPN pair routes only to the developer endpoint", {
                let pair = try CIDRValidator.shared.validatePair(tunnelIfaceInput: TunnelConstants.defaultIfaceIP,
                                                                tunnelPeerInput: TunnelConstants.defaultPeerIP)
                try expect(pair.iface.ip == "10.7.1.1", "Unexpected interface address")
                try expect(pair.peer.ip == "10.7.0.1", "Unexpected developer endpoint")
                try expect(pair.iface.prefix == 32 && pair.peer.prefix == 32, "Default route scope changed")
                try expect(pair.peer.totalAddresses == 1 && pair.peer.category == .unicast, "Peer must remain a single unicast host")
            }),
            ("CIDR rejects identical endpoints and malformed addresses", {
                try expectError("Identical endpoints", matches: {
                    if case CIDRError.identicalEndpoints = $0 { return true }; return false
                }) {
                    _ = try CIDRValidator.shared.validatePair(tunnelIfaceInput: "10.7.0.1/32", tunnelPeerInput: "10.7.0.1/32")
                }
                for input in ["10.7.0.1/33", "10.7.0.256/32", "10.7.0.1", "10.07.0.1/32"] {
                    try expectError("Invalid CIDR \(input)") { _ = try CIDRValidator.shared.validateCIDR(input) }
                }
            }),
            ("Debugger accepts only actual stop replies before detach", {
                for reply in ["T05thread:1234;", "T11", "S05", "S0a"] {
                    try DebugAttachResponse.validateAttach(reply)
                }
                for reply: String? in [nil, "", "OK", "E01", "W00", "X09", "T", "T5", "Tzz", "S05garbage"] {
                    try expectError("Invalid debugger attach reply") { try DebugAttachResponse.validateAttach(reply) }
                }
            }),
            ("Debugger requires an explicit OK detach acknowledgement", {
                try DebugAttachResponse.validateDetach("OK")
                for reply: String? in [nil, "", "E01", "T05", "OKextra", "ok"] {
                    try expectError("Invalid debugger detach reply") { try DebugAttachResponse.validateDetach(reply) }
                }
            }),
            ("Script writes reject missing and remote-error acknowledgements", {
                try DebugAttachResponse.validateMemoryWrite("OK")
                for reply: String? in [nil, "", "E01", "E0f;write failed", "T05", "OKextra"] {
                    try expectError("Unacknowledged JIT write") { try DebugAttachResponse.validateMemoryWrite(reply) }
                }
                for command in ["vAttach;123", "D", "M123,1:69", "P20=123;", "c", "vCont;S05:123", "m123,4", "_M1000,rx"] {
                    try expectError("Script command missing response") {
                        try DebugAttachResponse.validateScriptCommand(command, response: nil)
                    }
                    try expectError("Script command remote failure") {
                        try DebugAttachResponse.validateScriptCommand(command, response: "E01")
                    }
                }
            }),
            ("Script detects exited targets and extended memory errors", {
                for response in ["W00", "X09"] {
                    try expectError("Target exited while running") {
                        try DebugAttachResponse.validateScriptCommand("c", response: response)
                    }
                }
                try expectError("Extended memory error") {
                    try DebugAttachResponse.validateScriptCommand("m123,4", response: "E01;cannot read memory")
                }
                try DebugAttachResponse.validateScriptCommand("m123,4", response: "E0102030")
                try DebugAttachResponse.validateScriptCommand("_M1000,rx", response: "12345000")
                try DebugAttachResponse.validateScriptCommand("c", response: "T05thread:123;")
            }),
            ("Optional debugger queries keep their unsupported response semantics", {
                try DebugAttachResponse.validateScriptCommand("qSupported", response: "")
                try DebugAttachResponse.validateScriptCommand("QEnableErrorStrings", response: nil)
                try DebugAttachResponse.validateScriptCommand("qMemoryRegionInfo:123", response: "E01")
            })
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) host tests passed. Device-only VPN / FFI / JIT behavior is not covered.")
        if failures > 0 { exit(EXIT_FAILURE) }
    }
}
