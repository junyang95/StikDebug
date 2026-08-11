//
//  PairingFileStore.swift
//  StikDebug
//

import CryptoKit
import Foundation
import UniformTypeIdentifiers
import idevice

enum PairingFileStore {
    static let fileName = "rp_pairing_file.plist"
    static let didChangeNotification = Notification.Name("PairingFileStoreDidChange")
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList
    ]

    enum SynchronizationResult: Equatable {
        case noCandidate
        case unchanged
        case updated
        case rejected
    }

    enum StoreError: LocalizedError {
        case invalidPairingFile

        var errorDescription: String? {
            switch self {
            case .invalidPairingFile:
                "pairing file 内容无效".localized
            }
        }
    }

    struct Locations {
        let directoryURL: URL
        let destinationURL: URL
        let documentCandidateURLs: [URL]
        let legacyInternalURLs: [URL]
    }

    typealias Validator = (URL) -> Bool

    private static let legacyFileName = "pairingFile.plist"
    private static let mutationLock = NSLock()

    static var url: URL {
        liveLocations(fileManager: .default).destinationURL
    }

    /// Ensures the protected storage directory exists and performs only a
    /// one-time migration from an older Application Support filename.
    /// Documents synchronization is intentionally separate so callers on the
    /// one-second location hot path never mutate pairing state.
    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        prepareURL(
            fileManager: fileManager,
            locations: liveLocations(fileManager: fileManager),
            validator: isValidPairingFile(at:)
        )
    }

    @discardableResult
    static func prepareURL(
        fileManager: FileManager,
        locations: Locations,
        validator: Validator
    ) -> URL {
        var didChange = false
        let destination = withMutationLock {
            try? fileManager.createDirectory(
                at: locations.directoryURL,
                withIntermediateDirectories: true
            )

            guard !fileManager.fileExists(atPath: locations.destinationURL.path) else {
                return locations.destinationURL
            }

            for legacyURL in locations.legacyInternalURLs
            where fileManager.fileExists(atPath: legacyURL.path) {
                do {
                    _ = try installCandidate(
                        at: legacyURL,
                        destination: locations.destinationURL,
                        fileManager: fileManager,
                        validator: validator
                    )
                    try? fileManager.removeItem(at: legacyURL)
                    didChange = true
                    break
                } catch StoreError.invalidPairingFile {
                    continue
                } catch {
                    break
                }
            }
            return locations.destinationURL
        }

        if didChange {
            notifyChanged()
        }
        return destination
    }

    /// Imports a user-selected file without first migrating it. This matters
    /// when the picker source itself is Documents/pairingFile.plist: moving the
    /// source before staging it would make the subsequent copy fail.
    static func replace(with sourceURL: URL, fileManager: FileManager = .default) throws {
        try replace(
            with: sourceURL,
            fileManager: fileManager,
            locations: liveLocations(fileManager: fileManager),
            validator: isValidPairingFile(at:)
        )
    }

    static func replace(
        with sourceURL: URL,
        fileManager: FileManager,
        locations: Locations,
        validator: Validator
    ) throws {
        try withMutationLock {
            try fileManager.createDirectory(
                at: locations.directoryURL,
                withIntermediateDirectories: true
            )
            _ = try installCandidate(
                at: sourceURL,
                destination: locations.destinationURL,
                fileManager: fileManager,
                validator: validator
            )
            removeDocumentCandidates(locations, fileManager: fileManager)
        }
        notifyChanged()
    }

    static func importFromPicker(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try replace(with: sourceURL, fileManager: fileManager)
    }

    /// Consumes the newest valid file delivered through House Arrest. Invalid
    /// candidates never replace the last known-good file. The Documents copies
    /// are removed only after a successful validated import because pairing
    /// records contain device trust material and should not remain file-shared.
    @discardableResult
    static func synchronizeFromDocuments(
        fileManager: FileManager = .default
    ) throws -> SynchronizationResult {
        try synchronizeFromDocuments(
            fileManager: fileManager,
            locations: liveLocations(fileManager: fileManager),
            validator: isValidPairingFile(at:)
        )
    }

    @discardableResult
    static func synchronizeFromDocuments(
        fileManager: FileManager,
        locations: Locations,
        validator: Validator
    ) throws -> SynchronizationResult {
        var shouldNotify = false
        let result = try withMutationLock {
            try fileManager.createDirectory(
                at: locations.directoryURL,
                withIntermediateDirectories: true
            )

            let candidates = sortedDocumentCandidates(locations, fileManager: fileManager)
            guard !candidates.isEmpty else {
                return SynchronizationResult.noCandidate
            }

            for candidate in candidates {
                do {
                    let changed = try installCandidate(
                        at: candidate,
                        destination: locations.destinationURL,
                        fileManager: fileManager,
                        validator: validator
                    )
                    removeDocumentCandidates(locations, fileManager: fileManager)
                    shouldNotify = changed
                    return changed ? .updated : .unchanged
                } catch StoreError.invalidPairingFile {
                    continue
                }
            }

            return .rejected
        }

        if shouldNotify {
            notifyChanged()
        }
        return result
    }

    static func remove(fileManager: FileManager = .default) throws {
        let locations = liveLocations(fileManager: fileManager)
        var didRemove = false
        try withMutationLock {
            let allURLs = [locations.destinationURL]
                + locations.legacyInternalURLs
                + locations.documentCandidateURLs
            for candidate in allURLs where fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
                didRemove = true
            }
        }

        if didRemove {
            notifyChanged()
        }
    }

    /// Includes a content digest so a same-size rewrite with a restored
    /// modification timestamp is still detected by the lightweight monitor.
    static func stateSignature(fileManager: FileManager = .default) -> String {
        stateSignature(
            fileManager: fileManager,
            locations: liveLocations(fileManager: fileManager)
        )
    }

    static func stateSignature(fileManager: FileManager, locations: Locations) -> String {
        withMutationLock {
            monitoredURLs(locations).map { url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                    return "\(url.path):missing"
                }
                let size = attributes[.size] as? NSNumber
                let modifiedAt = attributes[.modificationDate] as? Date
                let digest = (try? Data(contentsOf: url)).map { data in
                    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                } ?? "unreadable"
                return "\(url.path):\(size?.int64Value ?? -1):\(modifiedAt?.timeIntervalSince1970 ?? -1):\(digest)"
            }
            .joined(separator: "|")
        }
    }

    static func isValidPairingFile(at url: URL) -> Bool {
        var handle: OpaquePointer?
        let error = url.path.withCString { rp_pairing_file_read($0, &handle) }
        if let error {
            idevice_error_free(error)
            if let handle {
                rp_pairing_file_free(handle)
            }
            return false
        }
        guard let handle else {
            return false
        }
        rp_pairing_file_free(handle)
        return true
    }

    private static func liveLocations(fileManager: FileManager) -> Locations {
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport.appendingPathComponent("Pairing", isDirectory: true)
        return Locations(
            directoryURL: directory,
            destinationURL: directory.appendingPathComponent(fileName),
            documentCandidateURLs: [
                documents.appendingPathComponent(legacyFileName),
                documents.appendingPathComponent(fileName)
            ],
            legacyInternalURLs: [directory.appendingPathComponent(legacyFileName)]
        )
    }

    private static func installCandidate(
        at sourceURL: URL,
        destination: URL,
        fileManager: FileManager,
        validator: Validator
    ) throws -> Bool {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: sourceURL, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }

        guard validator(temporary) else {
            throw StoreError.invalidPairingFile
        }

        if fileManager.fileExists(atPath: destination.path),
           fileManager.contentsEqual(atPath: temporary.path, andPath: destination.path) {
            return false
        }

        protectPairingFile(at: temporary, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        protectPairingFile(at: destination, fileManager: fileManager)
        return true
    }

    private static func sortedDocumentCandidates(
        _ locations: Locations,
        fileManager: FileManager
    ) -> [URL] {
        locations.documentCandidateURLs.enumerated()
            .filter { fileManager.fileExists(atPath: $0.element.path) }
            .sorted { first, second in
                let firstDate = (try? first.element.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
                let secondDate = (try? second.element.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
                if firstDate == secondDate {
                    return first.offset < second.offset
                }
                return firstDate > secondDate
            }
            .map(\.element)
    }

    private static func removeDocumentCandidates(
        _ locations: Locations,
        fileManager: FileManager
    ) {
        for candidate in locations.documentCandidateURLs
        where fileManager.fileExists(atPath: candidate.path) {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func monitoredURLs(_ locations: Locations) -> [URL] {
        [locations.destinationURL]
            + locations.legacyInternalURLs
            + locations.documentCandidateURLs
    }

    private static func protectPairingFile(at url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func withMutationLock<T>(_ body: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try body()
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
