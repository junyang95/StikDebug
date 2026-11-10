//
//  IdeviceFFIBridge.swift
//  StikDebug
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import UIKit
import idevice

private enum IdeviceBridge {
    static let processQueue = DispatchQueue(label: "com.stikdebug.processInspector", qos: .userInitiated)

    static func makeError(
        domain: String = "StikDebug",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "StikDebug"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let message = string(from: ffiError.pointee.message) ?? fallback
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        try context.withProtectedTunnel(body)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func plistDictionaries(adapter: OpaquePointer, handshake: OpaquePointer) throws -> [[String: Any]] {
        try withConnectedClient(
            fallback: "Failed to connect to installation proxy",
            missingClientMessage: "Installation proxy client was not created",
            connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
            cleanup: { installation_proxy_client_free($0) }
        ) { client in
            var rawApps: UnsafeMutableRawPointer?
            var count = 0
            if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
                throw consumeFFIError(ffiError, fallback: "Failed to fetch installed apps")
            }

            guard let rawApps, count > 0 else { return [] }

            let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
            defer {
                for index in 0..<count {
                    plist_free(apps[index])
                }
                idevice_data_free(
                    rawApps.assumingMemoryBound(to: UInt8.self),
                    UInt(count * MemoryLayout<plist_t?>.stride)
                )
            }

            var dictionaries: [[String: Any]] = []
            dictionaries.reserveCapacity(count)

            for index in 0..<count {
                var binaryPlist: UnsafeMutablePointer<CChar>?
                var binaryLength: UInt32 = 0
                let app = apps[index]

                guard plist_to_bin(app, &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                      let binaryPlist,
                      binaryLength > 0 else {
                    continue
                }

                let data = Data(bytes: binaryPlist, count: Int(binaryLength))
                plist_mem_free(binaryPlist)

                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any] else {
                    continue
                }

                dictionaries.append(dictionary)
            }

            return dictionaries
        }
    }

    static func appName(from dictionary: [String: Any]) -> String {
        if let displayName = dictionary["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = dictionary["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return "Unknown"
    }

    static func hasGetTaskAllow(_ dictionary: [String: Any]) -> Bool {
        guard let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return false
        }

        if let flag = entitlements["get-task-allow"] as? Bool {
            return flag
        }

        if let flag = entitlements["get-task-allow"] as? NSNumber {
            return flag.boolValue
        }

        return false
    }

    static func isHiddenSystemApp(_ dictionary: [String: Any]) -> Bool {
        guard let applicationType = dictionary["ApplicationType"] as? String,
              applicationType == "System" || applicationType == "HiddenSystemApp" else {
            return false
        }

        if let isHidden = dictionary["IsHidden"] as? Bool, isHidden {
            return true
        }

        if let isHidden = dictionary["IsHidden"] as? NSNumber, isHidden.boolValue {
            return true
        }

        guard let tags = dictionary["SBAppTags"] as? [String] else {
            return false
        }

        return tags.contains("hidden") || tags.contains("hidden-system-app")
    }

    static func appDictionary(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        requireGetTaskAllow: Bool,
        filter: (([String: Any]) -> Bool)? = nil
    ) throws -> [String: String] {
        let dictionaries = try plistDictionaries(adapter: adapter, handshake: handshake)
        var result: [String: String] = [:]
        result.reserveCapacity(dictionaries.count)

        for dictionary in dictionaries {
            if requireGetTaskAllow && !hasGetTaskAllow(dictionary) {
                continue
            }

            if let filter, !filter(dictionary) {
                continue
            }

            guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }

            result[bundleID] = appName(from: dictionary)
        }

        return result
    }


}

extension JITEnableContext {
    func isDeveloperDiskImageMounted() throws -> Bool {
        try withDDITunnel { adapter, handshake in
            guard DeveloperDiskImageService.usesCryptexDDI else {
                return try mountedDeviceCount(adapter: adapter, handshake: handshake) > 0
            }
            var installed: UnsafeMutablePointer<InstalledCryptexC>?
            let ffiError = cryptexd_installed_ddi(adapter, handshake, &installed)
            let queryError = ffiError.map {
                IdeviceBridge.consumeFFIError($0, fallback: "Failed to query installed DDI cryptex")
            }
            defer { cryptexd_free_installed_cryptex(installed) }
            if installed != nil {
                return true
            }

            // A developer image may already have been mounted by another tool.
            // Keep the upstream legacy check before treating the device as unmounted.
            if let deviceCount = try? mountedDeviceCount(adapter: adapter, handshake: handshake), deviceCount > 0 {
                return true
            }
            if let queryError {
                throw queryError
            }
            return false
        }
    }

    func installCryptexDDI(from directoryPath: String) throws {
        var assets: OpaquePointer?
        if let ffiError = cryptex1_assets_load(directoryPath, &assets) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to load DDI cryptex assets")
        }
        guard let assets else {
            throw IdeviceBridge.makeError(message: "DDI cryptex assets were not loaded")
        }
        defer { cryptex1_assets_free(assets) }

        try withDDITunnel(requiresBinding: true) { adapter, handshake in
            if let ffiError = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install DDI cryptex")
            }
        }
    }

    func getMountedDeviceCount() throws -> Int {
        try withDDITunnel { adapter, handshake in
            try mountedDeviceCount(adapter: adapter, handshake: handshake)
        }
    }

    private func mountedDeviceCount(adapter: OpaquePointer, handshake: OpaquePointer) throws -> Int {
        try IdeviceBridge.withConnectedClient(
            fallback: "Failed to connect to image mounter",
            missingClientMessage: "Image mounter client was not created",
            connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
            cleanup: { image_mounter_free($0) }
        ) { client in
            var devices: UnsafeMutablePointer<plist_t?>?
            var deviceCount = 0
            if let ffiError = image_mounter_copy_devices(client, &devices, &deviceCount) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch mounted devices")
            }

            if let devices {
                for index in 0..<deviceCount {
                    plist_free(devices[index])
                }
                idevice_data_free(
                    UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                    UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                )
            }

            return deviceCount
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try withDDITunnel(requiresBinding: true) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }

                defer {
                    if let uniqueChipIDPlist {
                        plist_free(uniqueChipIDPlist)
                    }
                }

                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                        manifestData.withUnsafeBytes { manifestBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                            image_mounter_mount_personalized_with_callback_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID,
                                progressCallback,
                                nil
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }

    func fetchAllProfiles() throws -> [Data] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                var profileLengths: UnsafeMutablePointer<Int>?
                var profileCount = 0

                if let ffiError = misagent_copy_all(misagentClient, &profilePointers, &profileLengths, &profileCount) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to fetch provisioning profiles",
                        domain: "profiles"
                    )
                }

                defer {
                    if let profilePointers, let profileLengths {
                        misagent_free_profiles(profilePointers, profileLengths, profileCount)
                    }
                }

                guard let profilePointers, let profileLengths else { return [] }

                var result: [Data] = []
                result.reserveCapacity(profileCount)

                for index in 0..<profileCount {
                    guard let bytes = profilePointers[index] else { continue }
                    result.append(Data(bytes: bytes, count: profileLengths[index]))
                }

                return result
            }
        }
    }

    func removeProfile(withUUID uuid: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                if let ffiError = misagent_remove(misagentClient, uuid) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to remove provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func addProfile(_ profile: Data) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                let ffiError = profile.withUnsafeBytes { rawBuffer in
                    misagent_install(
                        misagentClient,
                        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        profile.count
                    )
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to add provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func fetchProcessList() throws -> [NSDictionary] {
        try IdeviceBridge.processQueue.sync {
            try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Unable to open AppService",
                    missingClientMessage: "AppService client was not created",
                    connect: { app_service_connect_rsd(adapter, handshake, $0) },
                    cleanup: { app_service_free($0) }
                ) { appService in
                    var processes: UnsafeMutablePointer<ProcessTokenC>?
                    var count = UInt(0)
                    if let ffiError = app_service_list_processes(appService, &processes, &count) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to list processes")
                    }

                    defer {
                        if let processes {
                            app_service_free_process_list(processes, count)
                        }
                    }

                    guard let processes else { return [] }

                    var result: [NSDictionary] = []
                    result.reserveCapacity(Int(count))

                    for index in 0..<Int(count) {
                        let process = processes[index]
                        var dictionary: [String: Any] = ["pid": NSNumber(value: process.pid)]
                        if let executableURL = IdeviceBridge.string(from: process.executable_url) {
                            dictionary["path"] = executableURL
                        }
                        result.append(dictionary as NSDictionary)
                    }

                    return result
                }
            }
        }
    }

    func sendSignal(_ signal: Int32, toProcessWithPID pid: Int32) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Unable to open AppService",
                missingClientMessage: "AppService client was not created",
                connect: { app_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { app_service_free($0) }
            ) { appService in
                var response: UnsafeMutablePointer<SignalResponseC>?
                let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(signal), &response)
                defer {
                    if let response {
                        app_service_free_signal_response(response)
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to send signal \(signal) to process")
                }
            }
        }
    }

    func killProcess(withPID pid: Int32) throws {
        try sendSignal(Int32(SIGKILL), toProcessWithPID: pid)
    }

    func getAppList() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: true
            )
        }
    }

    func getAllApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false
            )
        }
    }

    func getHiddenSystemApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false,
                filter: IdeviceBridge.isHiddenSystemApp
            )
        }
    }

    func getSideloadedApps() throws -> [NSDictionary] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
                .filter { $0["ProfileValidated"] != nil }
                .map { $0 as NSDictionary }
        }
    }

    func getAppIcon(withBundleId bundleId: String) throws -> UIImage {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to SpringBoard Services",
                missingClientMessage: "SpringBoard Services client was not created",
                connect: { springboard_services_connect_rsd(adapter, handshake, $0) },
                cleanup: { springboard_services_free($0) }
            ) { client in
                var rawIconData: UnsafeMutableRawPointer?
                var rawIconLength = 0
                if let ffiError = springboard_services_get_icon(client, bundleId, &rawIconData, &rawIconLength) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to get app icon")
                }

                guard let rawIconData, rawIconLength > 0 else {
                    throw IdeviceBridge.makeError(message: "App icon data was empty")
                }

                defer { free(rawIconData) }

                let data = Data(bytes: rawIconData, count: rawIconLength)
                guard let image = UIImage(data: data) else {
                    throw IdeviceBridge.makeError(message: "Failed to decode app icon image")
                }

                return image
            }
        }
    }

    func ideviceInfoInit() throws -> OpaquePointer {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.connectClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                domain: "profiles",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) }
            )
        }
    }

    func ideviceInfoGetXML(withLockdownClient lockdownClient: OpaquePointer?) throws -> UnsafeMutablePointer<CChar>? {
        guard let lockdownClient else { return nil }

        var plistObject: plist_t?
        if let ffiError = lockdownd_get_value(lockdownClient, nil, nil, &plistObject) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch device info")
        }

        guard let plistObject else {
            return nil
        }

        defer { plist_free(plistObject) }

        var xml: UnsafeMutablePointer<CChar>?
        var xmlLength: UInt32 = 0
        guard plist_to_xml(plistObject, &xml, &xmlLength) == PLIST_ERR_SUCCESS,
              let xml,
              xmlLength > 0 else {
            throw IdeviceBridge.makeError(message: "Failed to serialize device info plist")
        }

        return xml
    }
}

func FetchDeviceProcessList(_ error: NSErrorPointer) -> [NSDictionary]? {
    do {
        return try JITEnableContext.shared.fetchProcessList()
    } catch let nsError as NSError {
        error?.pointee = nsError
        return nil
    }
}

func KillDeviceProcess(_ pid: Int32, _ error: NSErrorPointer) -> Bool {
    do {
        try JITEnableContext.shared.killProcess(withPID: pid)
        return true
    } catch let nsError as NSError {
        error?.pointee = nsError
        return false
    }
}

struct ProcessInfoEntry: Identifiable {
    let pid: Int
    private let rawPath: String
    let bundleID: String?
    let name: String?

    init?(dictionary: NSDictionary) {
        guard let pidNumber = dictionary["pid"] as? NSNumber else { return nil }
        pid = pidNumber.intValue
        rawPath = dictionary["path"] as? String ?? "Unknown"
        bundleID = dictionary["bundleID"] as? String
        name = dictionary["name"] as? String
    }

    static func currentEntries(_ error: NSErrorPointer = nil) -> [ProcessInfoEntry] {
        let entries = FetchDeviceProcessList(error) ?? []
        return entries.compactMap(Self.init(dictionary:))
    }

    var id: Int { pid }

    var executablePath: String {
        rawPath.replacingOccurrences(of: "file://", with: "")
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let component = executablePath.split(separator: "/").last {
            return String(component)
        }
        return "Process \(pid)"
    }

    var stableIdentifier: String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return displayName
    }
}

@objcMembers
final class CMSDecoderHelper: NSObject {
    static func decodeCMSData(_ cmsData: Data) throws -> Data {
        guard !cmsData.isEmpty else {
            throw IdeviceBridge.makeError(
                domain: NSCocoaErrorDomain,
                code: NSURLErrorBadURL,
                message: "Invalid or empty CMS payload"
            )
        }

        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        let binaryMagic = Data("bplist00".utf8)

        if let startRange = cmsData.range(of: xmlStart),
           let endRange = cmsData.range(of: plistEnd, options: [], in: startRange.lowerBound..<cmsData.endIndex) {
            return cmsData[startRange.lowerBound..<endRange.upperBound]
        }

        if let binaryRange = cmsData.range(of: binaryMagic) {
            return cmsData[binaryRange.lowerBound..<cmsData.endIndex]
        }

        throw IdeviceBridge.makeError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            message: "Unable to extract plist from CMS payload"
        )
    }
}

enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

/// The identity is read from the same RSD tunnel that will perform the operation.
/// No UI flag, pairing-file UDID, or separate probe connection can authorize it.
func verifyOfflineDeviceBinding(adapter: OpaquePointer, handshake: OpaquePointer) throws {
    do {
        let credential = try OfflineDeviceBinding.credential(expectedProduct: "pikmin-helper")
        let udid = try IdeviceBridge.withConnectedClient(
            fallback: "无法读取连接设备的有效标识，请检查配对与设备连接。".localized,
            missingClientMessage: "无法读取连接设备的有效标识，请检查配对与设备连接。".localized,
            connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
            cleanup: { lockdownd_client_free($0) }
        ) { lockdown in
            var value: plist_t?
            if let error = lockdownd_get_value(lockdown, "UniqueDeviceID", nil, &value) {
                idevice_error_free(error)
                if let value { plist_free(value) }
                throw OfflineDeviceBindingError.invalidDeviceIdentifier
            }
            defer { if let value { plist_free(value) } }
            guard let value, plist_get_node_type(value) == PLIST_STRING else {
                throw OfflineDeviceBindingError.invalidDeviceIdentifier
            }
            var length: UInt64 = 0
            guard let bytes = plist_get_string_ptr(value, &length), length == 25 || length == 40,
                  let udid = String(data: Data(bytes: bytes, count: Int(length)), encoding: .utf8) else {
                throw OfflineDeviceBindingError.invalidDeviceIdentifier
            }
            return udid
        }
        try credential.validate(actualUDID: udid)
    } catch let error as OfflineDeviceBindingError {
        throw OfflineBindingMessages.error(error)
    } catch {
        throw OfflineBindingMessages.error(.invalidDeviceIdentifier)
    }
}

private struct LocationTunnel {
    let adapter: OpaquePointer
    let handshake: OpaquePointer
}

private struct LocationController {
    let location: OpaquePointer
    let server: OpaquePointer
}

private struct LocationCommandError: Error {
    let status: Int32
}

private enum LocationSimulationState {
    static let session = LocationSimulationSession<LocationTunnel, LocationController>(dependencies: .init(
        verifyBinding: { try verifyOfflineDeviceBinding(adapter: $0.adapter, handshake: $0.handshake) },
        makeController: { tunnel in
            var remoteServer: OpaquePointer?
            if let error = remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &remoteServer) {
                idevice_error_free(error)
                if let remoteServer { remote_server_free(remoteServer) }
                throw LocationCommandError(status: LocationSimulationStatus.remoteServer)
            }
            guard let remoteServer else { throw LocationCommandError(status: LocationSimulationStatus.remoteServer) }
            var controller: OpaquePointer?
            if let error = location_simulation_new(remoteServer, &controller) {
                idevice_error_free(error)
                if let controller { location_simulation_free(controller) }
                remote_server_free(remoteServer)
                throw LocationCommandError(status: LocationSimulationStatus.locationSimulation)
            }
            guard let controller else {
                remote_server_free(remoteServer)
                throw LocationCommandError(status: LocationSimulationStatus.locationSimulation)
            }
            // The bundled FFI controller borrows the server; keep both alive.
            return LocationController(location: controller, server: remoteServer)
        },
        set: { controller, latitude, longitude in
            guard LocationNetworkGate.shared.state.isReady else {
                throw LocationCommandError(status: LocationNetworkGate.blockedStatus)
            }
            if let error = location_simulation_set(controller.location, latitude, longitude) {
                idevice_error_free(error)
                throw LocationCommandError(status: LocationSimulationStatus.locationSet)
            }
        },
        clear: { controller in
            if let error = location_simulation_clear(controller.location) {
                idevice_error_free(error)
                throw LocationCommandError(status: LocationSimulationStatus.locationClear)
            }
        },
        freeController: {
            location_simulation_free($0.location)
            remote_server_free($0.server)
        },
        freeConnection: { rsd_handshake_free($0.handshake); adapter_free($0.adapter) }
    ))
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.stik.location-sim", qos: .userInitiated)
}

/// Invalidate successful binding whenever the transport disconnects.
func invalidate_location_connection() {
    LocationSimulationCommandQueue.shared.async { LocationSimulationState.session.disconnect() }
}

private func createLocationTunnel(deviceIP: String, pairingFile: String) throws -> LocationTunnel {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian
    guard deviceIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
        throw LocationCommandError(status: LocationSimulationStatus.invalidIP)
    }
    var pairingHandle: OpaquePointer?
    if let error = pairingFile.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
        idevice_error_free(error)
        if let pairingHandle { rp_pairing_file_free(pairingHandle) }
        throw LocationCommandError(status: LocationSimulationStatus.pairingRead)
    }
    guard let pairingHandle else { throw LocationCommandError(status: LocationSimulationStatus.pairingRead) }
    defer { rp_pairing_file_free(pairingHandle) }
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let error = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                   "StikDebugLocation", pairingHandle, nil, nil, &adapter, &handshake)
        }
    }
    if let error { idevice_error_free(error) }
    guard error == nil, let adapter, let handshake else {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        throw LocationCommandError(status: LocationSimulationStatus.providerCreate)
    }
    return LocationTunnel(adapter: adapter, handshake: handshake)
}

private func locationConnectionIdentity(_ ip: String, _ pairingFile: String) -> String {
    "\(ip)|\(pairingFile)|\(PairingFileStore.stateSignature())"
}

private func locationStatus(for error: Error, fallback: Int32) -> Int32 {
    if let error = error as? LocationCommandError { return error.status }
    let error = error as NSError
    if error.domain == "OfflineDeviceBinding" { return Int32(error.code) }
    LogManager.shared.addErrorLog(error.localizedDescription)
    return fallback
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    guard LocationNetworkGate.shared.state.isReady else { return LocationNetworkGate.blockedStatus }
    return DeveloperConnectionGate.performLocationCommand(clear: false) {
        do {
            try LocationSimulationState.session.set(
                identity: locationConnectionIdentity(deviceIP, pairingFile),
                latitude: latitude, longitude: longitude,
                connect: {
                    guard LocationNetworkGate.shared.state.isReady else {
                        throw LocationCommandError(status: LocationNetworkGate.blockedStatus)
                    }
                    return try createLocationTunnel(deviceIP: deviceIP, pairingFile: pairingFile)
                }
            )
            return LocationSimulationStatus.ok
        } catch { return locationStatus(for: error, fallback: LocationSimulationStatus.locationSet) }
    }
}

/// Reconnect if needed to restore real GPS, without requiring a binding credential.
func clear_simulated_location(_ deviceIP: String, _ pairingFile: String) -> Int32 {
    DeveloperConnectionGate.performLocationCommand(clear: true) {
        do {
            try LocationSimulationState.session.clear {
                try createLocationTunnel(deviceIP: deviceIP, pairingFile: pairingFile)
            }
            return LocationSimulationStatus.ok
        } catch { return locationStatus(for: error, fallback: LocationSimulationStatus.locationClear) }
    }
}
