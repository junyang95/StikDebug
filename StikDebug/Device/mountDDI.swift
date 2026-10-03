//
//  mountDDI.swift
//  StikDebug
//
//  Created by Stossy11 on 29/03/2025.
//

import Foundation

typealias RpPairingFileHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias ImageMounterHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer

func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
    MountingProgress.shared.progressCallback(progress: progress, total: total, context: context)
}

enum MountCheckResult {
    case mounted
    case notMounted
    case unreachable
}

func isMounted() -> Bool {
    return checkMountStatus() == .mounted
}

func checkMountStatus() -> MountCheckResult {
    do {
        return try JITEnableContext.shared.isDeveloperDiskImageMounted() ? .mounted : .notMounted
    } catch {
        return .unreachable
    }
}

/// Shared by the guided installer and automatic tunnel mounting.
func mountDeveloperDiskImage(from directoryPath: String) -> String? {
    guard DeveloperDiskImageService.filesAreReady else {
        return "DDI 文件尚未下载完成，请先安装 DDI。".localized
    }

    do {
        if DeveloperDiskImageService.usesCryptexDDI {
            try JITEnableContext.shared.installCryptexDDI(from: directoryPath)
        } else {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            try JITEnableContext.shared.mountPersonalDDI(
                withImagePath: directory.appendingPathComponent("Image.dmg").path,
                trustcachePath: directory.appendingPathComponent("Image.dmg.trustcache").path,
                manifestPath: directory.appendingPathComponent("BuildManifest.plist").path
            )
        }
    } catch {
        LogManager.shared.addErrorLog("Failed to mount DDI: \(error.localizedDescription)")
        return error.localizedDescription
    }
    return nil
}
