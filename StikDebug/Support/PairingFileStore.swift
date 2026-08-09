//
//  PairingFileStore.swift
//  StikDebug
//

import Foundation
import UniformTypeIdentifiers

enum PairingFileStore {
    static let fileName = "rp_pairing_file.plist"
    static let didChangeNotification = Notification.Name("PairingFileStoreDidChange")
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList
    ]

    private static let legacyFileName = "pairingFile.plist"

    static var url: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // idevice_pair writes /Documents/pairingFile.plist through House Arrest.
        // Always prefer a newly delivered legacy file, even if an older pairing
        // file already exists in Application Support.
        if legacyURLs.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
            migrateLegacyCopy(to: destination, fileManager: fileManager)
        }
        return destination
    }

    static func replace(with sourceURL: URL, fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        removeLegacyCopies(fileManager: fileManager)
        try fileManager.copyItem(at: sourceURL, to: destination)
        protectPairingFile(at: destination, fileManager: fileManager)
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

    static func remove(fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        removeLegacyCopies(fileManager: fileManager)
        notifyChanged()
    }

    static func stateSignature(fileManager: FileManager = .default) -> String {
        monitoredURLs(fileManager: fileManager).map { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return "\(url.lastPathComponent):missing"
            }
            let size = attributes[.size] as? NSNumber
            let modifiedAt = attributes[.modificationDate] as? Date
            return "\(url.lastPathComponent):\(size?.int64Value ?? -1):\(modifiedAt?.timeIntervalSince1970 ?? -1)"
        }
        .joined(separator: "|")
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    private static func monitoredURLs(fileManager: FileManager) -> [URL] {
        [url] + legacyURLs
    }

    private static var legacyURLs: [URL] {
        [
            URL.documentsDirectory.appendingPathComponent(fileName),
            URL.documentsDirectory.appendingPathComponent(legacyFileName)
        ]
    }

    private static func migrateLegacyCopy(to destination: URL, fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            var didMigrate = false
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            do {
                try fileManager.moveItem(at: legacyURL, to: destination)
                didMigrate = true
            } catch {
                if let data = try? Data(contentsOf: legacyURL) {
                    try? data.write(to: destination, options: .atomic)
                    try? fileManager.removeItem(at: legacyURL)
                    didMigrate = true
                }
            }

            protectPairingFile(at: destination, fileManager: fileManager)
            if didMigrate {
                notifyChanged()
            }
            break
        }
    }

    private static func removeLegacyCopies(fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private static func protectPairingFile(at url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
