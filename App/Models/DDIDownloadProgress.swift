import Foundation

/// Renders only structured progress from the bundled image installer.
struct DDIDownloadProgress {
    let phase: String
    let source: String
    let file: String
    let received: Int64
    let expected: Int64

    init?(_ status: String) {
        let fields = status.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, fields[0] == "ddi",
              ["copying", "verifying", "committing"].contains(fields[1]),
              fields[2] == "bundle",
              ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"].contains(fields[3]),
              let received = Int64(fields[4]), let expected = Int64(fields[5]),
              received >= 0, expected > 0, received <= expected else { return nil }
        phase = fields[1]
        source = fields[2]
        file = fields[3]
        self.received = received
        self.expected = expected
    }

    var displayText: String {
        let origin = localized("ddi.prepare.source.bundle")
        let counts = String(format: localized("ddi.prepare.bytes"),
                            ByteCountFormatter.string(fromByteCount: received, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))
        return localized("ddi.prepare." + phase) + "\n" + "\(origin) · \(file)\n\(counts)"
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "DDI", comment: "")
    }
}
