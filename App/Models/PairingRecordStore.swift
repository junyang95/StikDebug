import Foundation
import Darwin

/// Owns a private, atomically replaced pairing record. Never logs record contents.
final class PairingRecordStore {
    enum StoreError: Error {
        case tooLarge
        case invalidPropertyList
        case invalidHostIdentity
        case readFailed(Error)
        case validationFailed(Error)
        case writeFailed(Error)
    }

    static let maximumBytes = 5 * 1024 * 1024
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("pairing.plist") }
    var hasRecord: Bool { FileManager.default.isReadableFile(atPath: fileURL.path) }

    init(directory: URL) { self.directory = directory }

    func importRecord(from source: URL, hostAltIRK: Data? = nil, validate: (URL) throws -> Void) throws {
        var data = try readSnapshot(from: source)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              var dictionary = plist as? [String: Any], !dictionary.isEmpty else {
            throw StoreError.invalidPropertyList
        }
        if let hostAltIRK {
            guard hostAltIRK.count == 16 else { throw StoreError.invalidHostIdentity }
            // The RPPairing parser ignores unknown keys. Persist the host identity
            // in the same protected transaction as its keys and peer record;
            // FFI reserialization would discard this app-owned metadata.
            dictionary["JITLauncherHostAltIRK"] = hostAltIRK
            do {
                data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            } catch {
                throw StoreError.invalidPropertyList
            }
            guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        }

        let fm = FileManager.default
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? fm.removeItem(at: temporary) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try data.write(to: temporary, options: options)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        } catch {
            throw StoreError.writeFailed(error)
        }
        // The framework parses RPPairing before the last valid record is replaced.
        do {
            try validate(temporary)
        } catch {
            throw StoreError.validationFailed(error)
        }
        // Same-directory rename replaces atomically and preserves the validated
        // file's protection and 0600 permissions through the entire transaction.
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw StoreError.writeFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
    }

    private func readSnapshot(from source: URL) throws -> Data {
        // Copy-mode pickers return a local temporary file, which can be readable
        // even when no additional security scope is granted. External callers
        // still get coordinated access for the entire snapshot operation.
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            if isPrivateCopy(source) { return try Self.readBoundedFile(at: source) }
            var snapshot: Result<Data, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                snapshot = Result { try Self.readBoundedFile(at: url) }
            }
            if let coordinationError { throw coordinationError }
            guard let snapshot else { throw CocoaError(.fileReadUnknown) }
            return try snapshot.get()
        } catch StoreError.tooLarge {
            throw StoreError.tooLarge
        } catch {
            throw StoreError.readFailed(error)
        }
    }

    private func isPrivateCopy(_ source: URL) -> Bool {
        var roots = [FileManager.default.temporaryDirectory, directory]
        #if os(iOS)
        roots.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        #endif
        let components = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return roots.contains { root in
            components.starts(with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
        }
    }

    private static func readBoundedFile(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        if let size = values.fileSize, size > maximumBytes { throw StoreError.tooLarge }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Never memory-map provider-owned bytes: they can disappear or change.
        // The extra byte detects growth after the metadata check without an
        // unbounded allocation, including when file size metadata is missing.
        var data = Data()
        while data.count <= maximumBytes {
            let limit = min(64 * 1024, maximumBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: limit), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        return data
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
