//
//  MountingProgress.swift
//  StikDebug
//

import Foundation
import idevice

final class MountingProgress: ObservableObject {
    static let shared = MountingProgress()

    @Published private(set) var mountProgress: Double = 0.0
    @Published private(set) var mountingThread: Thread?
    @Published private(set) var coolisMounted: Bool = false

    // Reserved by the guided installer, including its download stage.
    var installationInProgress = false

    private init() {}

    func checkforMounted() {
        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()
            DispatchQueue.main.async {
                self.coolisMounted = mounted
            }
        }
    }

    func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
        guard total > 0 else { return }
        let percentage = Double(progress) / Double(total) * 100.0
        DispatchQueue.main.async {
            self.mountProgress = percentage
        }
    }

    func pubMount() {
        mount()
    }

    private func mount() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.mount() }
            return
        }
        guard !installationInProgress, mountingThread == nil, !DeveloperConnectionGate.isBlocked else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }
            guard isPairing() else {
                DispatchQueue.main.async {
                    self.coolisMounted = false
                    self.mountingThread = nil
                }
                return
            }
            var confirmedMounted = isMounted()
            var mountError: String?
            if !confirmedMounted {
                mountError = mountDeveloperDiskImage(from: DeveloperDiskImageService.directoryURL.path)
                if mountError == nil {
                    confirmedMounted = isMounted()
                    if !confirmedMounted {
                        mountError = "文件已下载，但未确认 DDI 挂载成功。请检查内置 VPN 和开发者模式后重试。".localized
                    }
                }
            }

            let resultMounted = confirmedMounted
            let resultError = mountError
            DispatchQueue.main.async {
                self.coolisMounted = resultMounted
                self.mountingThread = nil
                if let mountError = resultError {
                    showAlert(title: "DDI Mount Failed", message: mountError, showOk: true, showTryAgain: true) { shouldTryAgain in
                        if shouldTryAgain {
                            self.mount()
                        }
                    }
                }
            }
        }

        thread.qualityOfService = .background
        thread.name = "mounting"
        mountingThread = thread
        thread.start()
    }
}

func isPairing() -> Bool {
    let pairingPath = PairingFileStore.prepareURL().path
    var pairingFile: RpPairingFileHandle?
    let error = rp_pairing_file_read(pairingPath, &pairingFile)
    if let error {
        idevice_error_free(error)
        return false
    }
    rp_pairing_file_free(pairingFile)
    return true
}
