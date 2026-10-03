import CryptoKit
import Foundation

enum DDIMountMethod: String {
    case personalized, cryptex

    static func select(for version: OperatingSystemVersion) -> Self {
        version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
            ? .cryptex : .personalized
    }

    var directoryName: String {
        self == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
    }
}

struct DDIDownloadItem: Equatable {
    let fileName: String
    let size: Int64
    let sha256: String
}

struct DDIAssetSet {
    static let releaseID = "6eae353ae694bda1c421d4a3eee5459ae59c99a1"

    let release: String
    let method: DDIMountMethod
    let files: [DDIDownloadItem]

    var cacheKey: String { "\(release)/\(method.rawValue)" }

    func url(for item: DDIDownloadItem) -> URL {
        URL(string: "https://static.wow-app.store/Xcode_iOS_DDI_Personalized/releases/\(release)/\(method.directoryName)/\(item.fileName)")!
    }

    static func current(for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Self {
        let method = DDIMountMethod.select(for: version)
        return Self(release: releaseID, method: method, files: method == .cryptex ? cryptexFiles : personalizedFiles)
    }

    func verifyFile(at url: URL, item: DDIDownloadItem) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == item.size else {
            throw DDIDownloadError.invalidFile(item.fileName)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == item.sha256 else { throw DDIDownloadError.invalidFile(item.fileName) }
    }

    private static let personalizedFiles: [DDIDownloadItem] = [
        .init(fileName: "BuildManifest.plist", size: 801505, sha256: "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54"),
        .init(fileName: "Image.dmg", size: 15733248, sha256: "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca"),
        .init(fileName: "Image.dmg.trustcache", size: 1895, sha256: "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c")
    ]

    private static let cryptexFiles: [DDIDownloadItem] = [
        .init(fileName: "BuildManifest.plist", size: 804946, sha256: "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012"),
        .init(fileName: "Image.dmg", size: 15895040, sha256: "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176"),
        .init(fileName: "Image.dmg.trustcache", size: 1895, sha256: "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0"),
        .init(fileName: "Image.dmg.cryptex_info", size: 430, sha256: "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c"),
        .init(fileName: "Image.dmg.root_hash", size: 229, sha256: "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302")
    ]
}
