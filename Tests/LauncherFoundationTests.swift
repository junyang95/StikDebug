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

    static func readPlist(_ url: URL) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw Failure(description: "Stored property list is not a dictionary")
        }
        return dictionary
    }

    static func externalRequest(_ text: String) -> LauncherExternalRequest? {
        guard let url = URL(string: text) else { return nil }
        return LauncherExternalRequest(url: url)
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
            ("On-device identity and pairing record commit as one validated file", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let oldIdentity = Data(repeating: 0x11, count: 16)
                    let newIdentity = Data((0..<16).map(UInt8.init))
                    _ = try writePlist(["Fixture": "old record"], at: source)
                    try store.importRecord(from: source, hostAltIRK: oldIdentity) { _ in }
                    let previous = try Data(contentsOf: store.fileURL)
                    let original = try writePlist([
                        "Fixture": "new record",
                        "JITLauncherHostAltIRK": Data(repeating: 0xff, count: 16)
                    ], at: source, format: .binary)
                    var validatedBytes: Data?
                    try store.importRecord(from: source, hostAltIRK: newIdentity) { temporary in
                        try expect(temporary != source && temporary != store.fileURL, "Enriched record must be staged privately")
                        let staged = try readPlist(temporary)
                        try expect(staged["Fixture"] as? String == "new record", "Pairing fields changed during enrichment")
                        try expect(staged["JITLauncherHostAltIRK"] as? Data == newIdentity,
                                   "Validator did not receive the current host identity as plist Data")
                        try expect(try permissions(temporary) == 0o600, "Enriched record must be owner-only")
                        try expect(try Data(contentsOf: store.fileURL) == previous,
                                   "Previous identity/record changed before validation finished")
                        validatedBytes = try Data(contentsOf: temporary)
                    }
                    try expect(try Data(contentsOf: store.fileURL) == validatedBytes, "Commit differs from validated enriched bytes")
                    try expect(try readPlist(store.fileURL)["JITLauncherHostAltIRK"] as? Data == newIdentity,
                               "New host identity was not committed")
                    try expect(try Data(contentsOf: source) == original, "Import modified the source pairing file")
                    try expect(try permissions(store.fileURL) == 0o600, "Enriched commit lost private permissions")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Identity was stored separately or staging leaked")
                }
            }),
            ("Invalid host identity lengths preserve the existing record and identity", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": "old record"], at: source)
                    try store.importRecord(from: source, hostAltIRK: Data(repeating: 0x22, count: 16)) { _ in }
                    let previous = try Data(contentsOf: store.fileURL)
                    _ = try writePlist(["Fixture": "replacement"], at: source)
                    for length in [0, 1, 15, 17, 32] {
                        var called = false
                        try expectError("Invalid host identity length \(length)", matches: {
                            if case PairingRecordStore.StoreError.invalidHostIdentity = $0 { return true }; return false
                        }) {
                            try store.importRecord(from: source, hostAltIRK: Data(repeating: 0, count: length)) { _ in called = true }
                        }
                        try expect(!called, "Invalid host identity reached pairing validation")
                        try expect(try Data(contentsOf: store.fileURL) == previous, "Invalid identity changed the stored record")
                        try expect(try remainingFiles(store) == ["pairing.plist"], "Invalid identity leaked staged data")
                    }
                }
            }),
            ("Rejected on-device pairing preserves both previous keys and host identity", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    let oldIdentity = Data(repeating: 0x33, count: 16)
                    let rejectedIdentity = Data(repeating: 0x44, count: 16)
                    _ = try writePlist(["Fixture": "old record"], at: source)
                    try store.importRecord(from: source, hostAltIRK: oldIdentity) { _ in }
                    let previous = try Data(contentsOf: store.fileURL)
                    _ = try writePlist(["Fixture": "rejected record"], at: source)
                    try expectError("Rejected enriched record", matches: { $0 is RejectedRecord }) {
                        try store.importRecord(from: source, hostAltIRK: rejectedIdentity) { temporary in
                            try expect(try readPlist(temporary)["JITLauncherHostAltIRK"] as? Data == rejectedIdentity,
                                       "Test did not validate the enriched replacement")
                            throw RejectedRecord.incompatible
                        }
                    }
                    try expect(try Data(contentsOf: store.fileURL) == previous, "Rejected enrichment replaced the old record")
                    try expect(try readPlist(store.fileURL)["JITLauncherHostAltIRK"] as? Data == oldIdentity,
                               "Rejected import separated host identity from its previous record")
                    try expect(try remainingFiles(store) == ["pairing.plist"], "Rejected enriched temporary file leaked")
                }
            }),
            ("Manual import removes the previous on-device identity with its record", {
                try withStore { store, root in
                    let source = root.appendingPathComponent("source.plist")
                    _ = try writePlist(["Fixture": "on-device record"], at: source)
                    try store.importRecord(from: source, hostAltIRK: Data(repeating: 0x55, count: 16)) { _ in }
                    let manual = try writePlist(["Fixture": "manual record"], at: source)
                    try store.importRecord(from: source) { _ in }
                    try expect(try Data(contentsOf: store.fileURL) == manual, "Manual import retained previous pairing metadata")
                    try expect(try readPlist(store.fileURL)["JITLauncherHostAltIRK"] == nil,
                               "Old host identity leaked into a different pairing record")
                }
            }),
            ("Pairing PIN accepts six ASCII digits including leading zeroes", {
                for pin in ["000000", "000001", "012345", "123456", "999999"] {
                    try expect(PairingPIN.isValid(pin), "Valid six-digit PIN was rejected")
                }
            }),
            ("Pairing PIN rejects Unicode digits, whitespace, and incorrect lengths", {
                for pin in ["", "12345", "1234567", "123456\n", " 123456", "123456 ", "12 456",
                            "１２３４５６", "١٢٣٤٥٦", "12345１", "+12345", "12345a", "12345\0"] {
                    try expect(!PairingPIN.isValid(pin), "Invalid PIN was accepted")
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
            ("Location coordinates accept pole and antimeridian boundaries", {
                for (latitude, longitude) in [("90", "180"), ("-90", "-180"), ("0", "0")] {
                    let point = LauncherInput.coordinate(latitude, longitude)
                    try expect(point?.0 == Double(latitude) && point?.1 == Double(longitude),
                               "Valid geographic boundary was rejected or changed")
                }
            }),
            ("Location coordinates preserve decimal precision and trim input whitespace", {
                let point = LauncherInput.coordinate(" 37.334900\n", "\t-122.009020 ")
                try expect(point?.0 == 37.3349 && point?.1 == -122.00902,
                           "Trimmed decimal coordinates changed")
                let zero = LauncherInput.coordinate("-0.0", "+0.0")
                try expect(zero?.0 == 0 && zero?.1 == 0, "Signed geographic zero was rejected")
            }),
            ("Location coordinates reject values outside latitude and longitude bounds", {
                for (latitude, longitude) in [("90.000001", "0"), ("-90.000001", "0"),
                                               ("0", "180.000001"), ("0", "-180.000001"),
                                               ("100", "100"), ("1e20", "0"), ("0", "-1e20")] {
                    try expect(LauncherInput.coordinate(latitude, longitude) == nil,
                               "Out-of-range location was accepted: \(latitude), \(longitude)")
                }
            }),
            ("Location coordinates reject non-finite values in either component", {
                for value in ["nan", "NaN", "inf", "-inf", "+infinity", "-infinity", "1e309"] {
                    try expect(LauncherInput.coordinate(value, "0") == nil,
                               "Non-finite latitude was accepted")
                    try expect(LauncherInput.coordinate("0", value) == nil,
                               "Non-finite longitude was accepted")
                }
            }),
            ("Location coordinates reject malformed and ambiguous input", {
                for value in ["", " \n", "12 34", "37,3349", "37°", "north", "１２", "1.2.3", "0\0"] {
                    try expect(LauncherInput.coordinate(value, "0") == nil,
                               "Malformed latitude was accepted: \(value.debugDescription)")
                    try expect(LauncherInput.coordinate("0", value) == nil,
                               "Malformed longitude was accepted: \(value.debugDescription)")
                }
            }),
            ("External links map registered schemes and exact actions to requests", {
                for scheme in ["jitlauncher", "stikpair", "JITLAUNCHER", "STIKPAIR"] {
                    try expect(externalRequest("\(scheme)://enable-jit?bundle-id=com.example.App") == .enableJIT("com.example.App"),
                               "JIT action or registered scheme mapped incorrectly")
                    try expect(externalRequest("\(scheme)://launch-app/?bundle-id=com.example.App") == .launch("com.example.App"),
                               "App launch action mapped incorrectly")
                    try expect(externalRequest("\(scheme)://kill-process?pid=1234") == .terminate(1234),
                               "Termination action mapped incorrectly")
                }
            }),
            ("External links reject unregistered schemes and unknown actions", {
                for link in ["https://enable-jit?bundle-id=com.example.App",
                             "stikdebug://enable-jit?bundle-id=com.example.App",
                             "otherapp://launch-app?bundle-id=com.example.App",
                             "jitlauncher://execute?bundle-id=com.example.App",
                             "jitlauncher://launch?bundle-id=com.example.App",
                             "jitlauncher://?bundle-id=com.example.App"] {
                    try expect(externalRequest(link) == nil, "Unsupported link was accepted: \(link)")
                }
            }),
            ("External actions require their own exact parameter name", {
                for link in ["jitlauncher://kill-process?bundle-id=com.example.App",
                             "jitlauncher://enable-jit?pid=1234", "jitlauncher://launch-app?pid=1234",
                             "jitlauncher://enable-jit?bundleID=com.example.App",
                             "jitlauncher://enable-jit?Bundle-id=com.example.App",
                             "jitlauncher://kill-process?PID=1234",
                             "jitlauncher://enable-jit", "jitlauncher://enable-jit?bundle-id",
                             "jitlauncher://kill-process?pid="] {
                    try expect(externalRequest(link) == nil, "Mismatched or missing action parameter was accepted")
                }
            }),
            ("External links reject duplicate and unknown additional parameters", {
                for query in ["bundle-id=com.example.App&bundle-id=com.other.App",
                              "bundle-id=com.example.App&bundle-id=com.example.App",
                              "bundle-id=com.example.App&pid=1234",
                              "bundle-id=com.example.App&unknown=value",
                              "bundle-id=com.example.App&",
                              "unknown=com.example.App"] {
                    try expect(externalRequest("jitlauncher://enable-jit?" + query) == nil,
                               "Ambiguous or unknown query was accepted: \(query)")
                }
                try expect(externalRequest("jitlauncher://kill-process?pid=1&pid=2") == nil,
                           "Duplicate PIDs were accepted")
            }),
            ("External links cannot provide scripts or bypass confirmation", {
                for key in ["script", "script-data", "script-base64", "script-url", "url", "callback", "confirm"] {
                    let link = "jitlauncher://enable-jit?bundle-id=com.example.App&\(key)=ZXZhbCgp"
                    try expect(externalRequest(link) == nil, "External script/control parameter was accepted")
                }
                for action in ["run-script", "execute-script", "import-script"] {
                    try expect(externalRequest("jitlauncher://\(action)?bundle-id=com.example.App") == nil,
                               "External script action was accepted")
                }
            }),
            ("External links reject userinfo, ports, fragments, and action paths", {
                for link in ["jitlauncher://user@enable-jit?bundle-id=com.example.App",
                             "jitlauncher://user:password@enable-jit?bundle-id=com.example.App",
                             "jitlauncher://enable-jit:123?bundle-id=com.example.App",
                             "jitlauncher://enable-jit?bundle-id=com.example.App#fragment",
                             "jitlauncher://enable-jit/extra?bundle-id=com.example.App",
                             "jitlauncher://enable-jit//?bundle-id=com.example.App"] {
                    try expect(externalRequest(link) == nil, "Malformed action URL was accepted")
                }
            }),
            ("External bundle identifiers enforce length, segments, and ASCII characters", {
                let maximum = "com." + String(repeating: "a", count: 251)
                try expect(externalRequest("jitlauncher://launch-app?bundle-id=" + maximum) == .launch(maximum),
                           "Maximum-length bundle ID was rejected")
                try expect(externalRequest("jitlauncher://launch-app?bundle-id=com.example.my-App2") == .launch("com.example.my-App2"),
                           "Valid mixed-case, numeric or hyphenated bundle ID rejected")
                for identifier in [maximum + "a", "", "single", ".com.app", "com..app", "com.app.",
                                   "com.example_app", "com.example/app", "com.应用", "com.éxample", " com.app", "com.app "] {
                    var parts = URLComponents()
                    parts.scheme = "jitlauncher"; parts.host = "launch-app"
                    parts.queryItems = [URLQueryItem(name: "bundle-id", value: identifier)]
                    try expect(parts.url.flatMap(LauncherExternalRequest.init(url:)) == nil,
                               "Malformed bundle ID was accepted: \(identifier.debugDescription)")
                }
            }),
            ("External links validate percent-decoded values and reject invalid UTF-8 or NUL", {
                try expect(externalRequest("jitlauncher://enable-jit?bundle-id=com%2Eexample%2EApp") == .enableJIT("com.example.App"),
                           "Ordinary percent-encoded identifier failed to decode")
                for value in ["com.example.App%00", "com.%00example.App", "com.example.%FF", "com.example.%C0%AF",
                              "com.example.%E4%B8%AD", "com.example.App%0A", "com.example.App%2500"] {
                    try expect(externalRequest("jitlauncher://enable-jit?bundle-id=" + value) == nil,
                               "Encoded invalid bundle ID was accepted")
                }
                for value in ["123%00", "%00123", "123%0A", "%FF", "123%2500"] {
                    try expect(externalRequest("jitlauncher://kill-process?pid=" + value) == nil,
                               "Encoded invalid PID was accepted")
                }
            }),
            ("External process IDs accept only positive Int32 decimal values", {
                for (text, pid) in [("1", Int32(1)), ("00123", Int32(123)), ("2147483647", Int32.max)] {
                    try expect(externalRequest("jitlauncher://kill-process?pid=" + text) == .terminate(pid),
                               "Valid process ID was rejected")
                }
                for pid in ["0", "-1", "+1", "2147483648", "9999999999999999", "1.0", "1e3", "１２３", "123%20", "%20123"] {
                    try expect(externalRequest("jitlauncher://kill-process?pid=" + pid) == nil,
                               "Invalid process ID was accepted: \(pid)")
                }
            }),
            ("External parser leaves own-process authorization to execution validation", {
                let ownPID = ProcessInfo.processInfo.processIdentifier
                try expect(externalRequest("jitlauncher://kill-process?pid=\(ownPID)") == .terminate(ownPID),
                           "Parser unexpectedly performed process authorization")
                try expectError("Execution PID validator must protect launcher", matches: {
                    if case TargetPIDValidator.ValidationError.ownProcess = $0 { return true }; return false
                }) { _ = try TargetPIDValidator.validate(String(ownPID), ownPID: ownPID) }
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
