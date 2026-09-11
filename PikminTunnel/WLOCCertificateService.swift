import Foundation

/// Only the extension code creates/reads the CA key; IPC and app files receive public material.
/// The effective Keychain access group is determined by signing, not process isolation.
/// No certificate command changes tunnel routes, proxy settings, or CONNECT forwarding.
final class WLOCCertificateService {
    private let queue = DispatchQueue(label: "com.jy.stikdebug.wloc-certificate")
    private let authority = WLOCCertificateAuthority()
    private var profileServer: CertificateProfileServer?
    private var stopped = false
    private var generation: UInt64 = 0

    func handle(_ command: WLOCCertificateCommand, completion: @escaping (WLOCCertificateReply) -> Void) {
        queue.async { [self] in
            guard !stopped else {
                completion(WLOCCertificateReply(error: "隧道已停止，请重新连接后再试。"))
                return
            }
            do {
                switch command {
                case .status:
                    completion(WLOCCertificateReply(info: try authority.status()))
                case .prepare:
                    completion(WLOCCertificateReply(info: try authority.prepare()))
                case .verifyTrust:
                    let info = try authority.status()
                    guard info != nil else {
                        completion(WLOCCertificateReply(error: "请先生成本机实验证书。"))
                        return
                    }
                    completion(WLOCCertificateReply(info: info,
                        systemTrusted: try authority.verifySystemTrust(), checkedAt: Date()))
                case .download:
                    guard let info = try authority.status() else {
                        completion(WLOCCertificateReply(error: "请先生成本机实验证书。"))
                        return
                    }
                    profileServer?.stop()
                    generation &+= 1
                    let revision = generation
                    let server = CertificateProfileServer(profile: try WLOCCertificateProfile.make(info: info))
                    profileServer = server
                    server.start { [weak self] result in
                        guard let self else { completion(WLOCCertificateReply(error: "隧道已停止。")); return }
                        self.queue.async {
                            guard !self.stopped, self.generation == revision else {
                                server.stop()
                                completion(WLOCCertificateReply(error: "下载已取消，请重新操作。"))
                                return
                            }
                            switch result {
                            case .success(let url): completion(WLOCCertificateReply(info: info, downloadURL: url))
                            case .failure: completion(WLOCCertificateReply(error: "无法启动本机证书下载，请重试。"))
                            }
                        }
                    }
                }
            } catch {
                // The CA implementation uses typed errors; never serialize keys or response bodies.
                completion(WLOCCertificateReply(error: error.localizedDescription))
            }
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            stopped = true
            generation &+= 1
            if let profileServer { profileServer.stop(completion: completion) }
            else { completion() }
            profileServer = nil
        }
    }
}
