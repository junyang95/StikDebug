import Foundation

extension DDIInstallationController {
    static let shared = DDIInstallationController(dependencies: .live)
}

extension DDIInstallationDependencies {
    static var live: Self {
        Self(
            prepare: {
                guard !DeveloperConnectionGate.isBlocked else {
                    throw DDIInstallationError.message("请先停止本机 WLOC 连接测试，再安装 DDI。".localized)
                }
                guard !WalkingSessionController.shared.isActive else {
                    throw DDIInstallationError.message("请先停止路线或摇杆，再安装 DDI。停止后会保留虚拟位置。".localized)
                }
                guard MountingProgress.shared.mountingThread == nil else {
                    throw DDIInstallationError.message("DDI 正在后台挂载，请稍后重新检查。".localized)
                }
                guard isPairing() else {
                    throw DDIInstallationError.message("请先在设置中完成设备配对，再安装 DDI。".localized)
                }
                MountingProgress.shared.installationInProgress = true
                if !EmbeddedVPNService.shared.status.isConnected {
                    await EmbeddedVPNService.shared.connect()
                }
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    if EmbeddedVPNService.shared.status.isConnected { return }
                    try await Task.sleep(for: .milliseconds(500))
                }
                throw DDIInstallationError.message("内置 VPN 尚未连接，请允许 VPN 连接后重试。".localized)
            },
            download: { force, progress in
                if force {
                    try await DeveloperDiskImageService.shared.redownload(progressHandler: progress)
                } else {
                    try await DeveloperDiskImageService.shared.downloadMissingFiles(progressHandler: progress)
                }
            },
            mount: {
                // Recheck after the download: a user may have started movement in another tab.
                guard !WalkingSessionController.shared.isActive, !DeveloperConnectionGate.isBlocked else {
                    throw DDIInstallationError.message("文件已下载。请先停止路线、摇杆或连接测试，再重试安装。".localized)
                }
                try await Task.detached(priority: .userInitiated) {
                    if checkMountStatus() == .mounted { return }
                    if let error = mountDeveloperDiskImage(from: DeveloperDiskImageService.directoryURL.path) {
                        throw DDIInstallationError.message(error)
                    }
                    guard checkMountStatus() == .mounted else {
                        throw DDIInstallationError.message("文件已下载，但未确认 DDI 挂载成功。请检查内置 VPN 和开发者模式后重试。".localized)
                    }
                }.value
                MountingProgress.shared.checkforMounted()
            },
            finish: {
                MountingProgress.shared.installationInProgress = false
                Task { await EnvironmentPreflightService.shared.refresh() }
            }
        )
    }
}

private enum DDIInstallationError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}
