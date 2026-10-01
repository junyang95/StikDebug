import Foundation
import Darwin

/// Owns a private, atomically replaced pairing record. Never logs record contents.
final class PairingRecordStore {
    enum StoreError: Error {
        case tooLarge
        case invalidPropertyList
    }

    static let maximumBytes = 5 * 1024 * 1024
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("pairing.plist") }
    var hasRecord: Bool { FileManager.default.isReadableFile(atPath: fileURL.path) }

    init(directory: URL) { self.directory = directory }

    func importRecord(from source: URL, validate: (URL) throws -> Void) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maximumBytes { throw StoreError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any], !dictionary.isEmpty else {
            throw StoreError.invalidPropertyList
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? fm.removeItem(at: temporary) }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: temporary, options: options)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // The framework parses RPPairing before the last valid record is replaced.
        try validate(temporary)
        // Same-directory rename replaces atomically and preserves the validated
        // file's protection and 0600 permissions through the entire transaction.
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func removeRecord() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

enum TargetPIDValidator {
    enum ValidationError: Error { case invalid, ownProcess }

    static func validate(_ text: String, ownPID: Int32) throws -> Int32 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int32(value), pid > 0 else { throw ValidationError.invalid }
        guard pid != ownPID else { throw ValidationError.ownProcess }
        return pid
    }
}
