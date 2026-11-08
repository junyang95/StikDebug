import Foundation

public enum StikJITError: Error, LocalizedError {

    case offlineDeviceBinding(OfflineDeviceBindingFailure)

    case pairingFile(String)

    case scriptUnavailable

    case debugProxyUnavailable

    case device(code: Int32, subCode: Int32, message: String)

    case ddiInstallation(String)

    case ddiFilesMissing(String)

    case ddiNotMounted

    case deviceNotReady(String)

    case txmDetectionUnavailable

    case customScript(String)

    case scriptExecution(String)

    public var errorDescription: String? {
        switch self {
        case .offlineDeviceBinding(let failure):
            return failure.localizedDescription
        case .pairingFile(let detail):
            return "Pairing file error: \(detail)."
        case .scriptUnavailable:
            return "The bundled JIT script could not be loaded from the StikJIT framework."
        case .debugProxyUnavailable:
            return "Failed to establish a debugserver connection to the target process."
        case .device(let code, let subCode, let message):
            return "\(message) (idevice code \(code)/\(subCode))."
        case .ddiInstallation(let detail):
            return "Failed to prepare bundled Developer Disk Image: \(detail)."
        case .ddiFilesMissing(let detail):
            return "Developer Disk Image files missing: \(detail)."
        case .ddiNotMounted:
            return "The Developer Disk Image was not mounted after the mount operation completed."
        case .deviceNotReady(let detail):
            return "The device is not ready for JIT: \(detail)"
        case .txmDetectionUnavailable:
            return "Whether TXM is present could not be determined. Enable forced script execution to bypass this check."
        case .customScript(let detail):
            return "Custom JIT script error: \(detail)."
        case .scriptExecution(let detail):
            return "JIT script failed: \(detail)."
        }
    }
}

/// Stable binding failures also remain usable by SDK clients without exposing
/// device identifiers in logs or error messages.
public enum OfflineDeviceBindingFailure: String, Error, LocalizedError {
    case missingCredential
    case invalidCredential
    case invalidSignature
    case unsupportedCredential
    case wrongProduct
    case invalidDeviceIdentifier
    case deviceMismatch
    case identityUnavailable

    public var errorDescription: String? {
        let fallback: String
        switch self {
        case .missingCredential: fallback = "This package is missing its offline device credential (wowdevice.plist). Install a package signed for this device."
        case .invalidCredential: fallback = "The offline device credential is damaged or invalid. Install a valid package for this device."
        case .invalidSignature: fallback = "The offline device credential signature is invalid. Install a valid package for this device."
        case .unsupportedCredential: fallback = "This offline device credential format is unsupported. Install a compatible package."
        case .wrongProduct: fallback = "This offline device credential is for a different app. Install the JIT Launcher package for this device."
        case .invalidDeviceIdentifier: fallback = "The device identifier is invalid. Check the package, pairing record, and actual connected device."
        case .deviceMismatch: fallback = "This package is bound to a different device. Connect its matching device or install a package signed for the connected device."
        case .identityUnavailable: fallback = "Could not read the connected device’s identifier. Check pairing and the local VPN connection, then try again."
        }
        return NSLocalizedString("binding.error." + rawValue, tableName: nil,
                                 bundle: .main, value: fallback, comment: "Offline device binding failure")
    }
}
