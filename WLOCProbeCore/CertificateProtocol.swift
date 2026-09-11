import Foundation

/// Only public material crosses provider IPC. Never add a private key or PKCS#12 here.
public struct WLOCCertificateInfo: Codable, Equatable, Sendable {
    public let commonName: String
    public let fingerprintSHA256: String
    public let notBefore: Date
    public let notAfter: Date
    public let certificateDER: Data

    public init(commonName: String, fingerprintSHA256: String, notBefore: Date,
                notAfter: Date, certificateDER: Data) {
        self.commonName = commonName
        self.fingerprintSHA256 = fingerprintSHA256
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.certificateDER = certificateDER
    }
}

enum WLOCCertificateCommand: String, Codable {
    case status = "certificate.status"
    case prepare = "certificate.prepare"
    case download = "certificate.download"
    case verifyTrust = "certificate.verifyTrust"
}

struct WLOCCertificateReply: Codable {
    var info: WLOCCertificateInfo?
    var systemTrusted: Bool?
    var checkedAt: Date?
    var downloadURL: URL?
    var error: String?
}

enum WLOCCertificateProfile {
    /// A removable, public-root-only configuration profile: no VPN, MDM, proxy, or identity payload.
    static func make(info: WLOCCertificateInfo) throws -> Data {
        let hex = info.fingerprintSHA256.lowercased().filter { $0 != ":" && $0 != " " }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }),
              !info.certificateDER.isEmpty, info.certificateDER.count <= 16 * 1024 else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        let identifier = "com.stikdebug.wloc.ca.\(hex)"
        // Stable IDs avoid multiple copies of the same CA when downloading again.
        func uuid(_ value: Substring) -> String {
            let chars = Array(value)
            return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
                .map { String(chars[$0]) }.joined(separator: "-").uppercased()
        }
        let payload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).root",
            "PayloadUUID": uuid(hex.prefix(32)),
            "PayloadDisplayName": info.commonName,
            "PayloadContent": info.certificateDER,
            "PayloadCertificateFileName": "StikDebug-WLOC.cer"
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid(hex.suffix(32)),
            "PayloadDisplayName": "StikDebug WLOC 实验证书",
            "PayloadDescription": "仅包含此设备生成的公开根证书，不含私钥、VPN 或管理权限。完全信任后此 CA 可签发 HTTPS 证书；仅在自己的测试设备上使用。结束实验后请在设置中移除此描述文件。当前版本尚未启用 HTTPS 解密或位置改写。",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
