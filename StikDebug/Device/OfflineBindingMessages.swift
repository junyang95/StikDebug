import Foundation

enum OfflineBindingMessages {
    static func status(for error: OfflineDeviceBindingError) -> Int32 {
        switch error {
        case .missingCredential: 80
        case .invalidCredential: 81
        case .invalidSignature: 82
        case .unsupportedCredential: 83
        case .wrongProduct: 84
        case .invalidDeviceIdentifier: 85
        case .deviceMismatch: 86
        }
    }

    static func message(for code: Int32) -> String? {
        switch code {
        case 80: "安装包缺少设备绑定凭据，请安装为本设备生成的完整安装包。".localized
        case 81, 82: "设备绑定凭据损坏或签名无效，请重新安装完整安装包。".localized
        case 83: "设备绑定凭据版本不受支持，请更新安装包。".localized
        case 84: "设备绑定凭据不适用于此 App，请安装正确的安装包。".localized
        case 85: "无法读取连接设备的有效标识，请检查配对与设备连接。".localized
        case 86: "此安装包与当前连接的设备不匹配，请使用为本设备生成的安装包。".localized
        default: nil
        }
    }

    static func error(_ error: OfflineDeviceBindingError) -> NSError {
        let code = status(for: error)
        return NSError(domain: "OfflineDeviceBinding", code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: message(for: code) ?? ""])
    }
}
