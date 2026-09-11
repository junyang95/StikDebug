import SwiftUI

/// Certificate preparation is deliberately separate from proxy interception and map controls.
struct WLOCCertificateView: View {
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmPrepare = false
    @State private var handoffMessage: String?

    private var available: Bool { vpn.status.isConnected && !vpn.isTransitioning && !vpn.isCertificateBusy }

    var body: some View {
        Form {
            Section {
                Label("第二阶段 A · 准备本机证书", systemImage: "lock.shield")
                    .font(.headline)
                Text("这一小步只生成证书、安装并检查系统信任。现有代理仍然只透传，不解密、不改写位置。")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("本机隧道", value: vpn.status.title)
                if !vpn.status.isConnected {
                    Button("连接普通本机隧道") { Task { await vpn.connect() } }
                        .disabled(vpn.isTransitioning || vpn.isExperimentEnabled)
                    Text("证书由网络扩展保管，需要 StikDebug 的隧道保持连接。无需开始透传测试，也无需配对文件；请先关闭其他 VPN。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if vpn.isTransitioning || vpn.isCertificateBusy {
                    ProgressView("正在处理，请稍候…")
                }
                if let error = vpn.certificateError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary).textSelection(.enabled)
                }
            } header: { Text("连接") }

            Section {
                if let info = vpn.certificateInfo {
                    Label("本机证书已生成", systemImage: "checkmark.circle")
                    Text(info.commonName).textSelection(.enabled)
                    LabeledContent("有效期至") { Text(info.notAfter, style: .date) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHA-256 指纹").font(.subheadline)
                        Text(formattedFingerprint(info.fingerprintSHA256))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button("生成此设备的实验证书") { confirmPrepare = true }
                        .disabled(!available)
                        .accessibilityIdentifier("wlocCertificate.prepare")
                }
            } header: { Text("1 · 生成") } footer: {
                Text("每台设备独立生成，有效期 90 天。私钥只保存在本机钥匙串，不经 USB 诊断导出，也不上传。重复操作会复用同一证书，不会悄悄更换。")
            }

            Section {
                Button {
                    Task {
                        handoffMessage = nil
                        guard let url = await vpn.performCertificateCommand(.download) else { return }
                        let opened = await UIApplication.shared.open(url)
                        handoffMessage = opened
                            ? "已交给系统浏览器。请允许下载，然后到设置安装描述文件。若未下载，返回后重试。".localized
                            : "无法打开本机下载，请确认系统浏览器可用后重试。".localized
                    }
                } label: {
                    Label("下载本机证书描述文件", systemImage: "arrow.down.doc")
                }
                .disabled(!available || vpn.certificateInfo == nil)
                .accessibilityIdentifier("wlocCertificate.download")
                if let handoffMessage { Text(handoffMessage).foregroundStyle(.secondary) }
                Text("下载后前往「设置 → 通用 → VPN 与设备管理」，安装“StikDebug WLOC 实验证书”。这里只含公开根证书，不含 VPN、设备管理或私钥。")
                    .foregroundStyle(.secondary)
            } header: { Text("2 · 安装") } footer: {
                Text("下载地址仅在这台手机的 127.0.0.1 上开放，两分钟后失效，成功下载后关闭。系统浏览器只是用于本机安装，不访问第三方网站。")
            }

            Section {
                Text("前往「设置 → 通用 → 关于本机 → 证书信任设置」，为上方同名证书开启完全信任，然后回到这里检查。")
                Button {
                    Task { await vpn.performCertificateCommand(.verifyTrust) }
                } label: {
                    Label("检查系统证书信任", systemImage: "checkmark.shield")
                }
                .disabled(!available || vpn.certificateInfo == nil)
                .accessibilityIdentifier("wlocCertificate.verify")
                if let trusted = vpn.certificateSystemTrusted {
                    Label(trusted ? "系统证书链校验已通过" : "系统证书链校验未通过",
                          systemImage: trusted ? "checkmark.circle" : "exclamationmark.circle")
                    if !trusted {
                        Text("请核对证书名称、有效期和完全信任开关，再重新检查。安装描述文件并不等于已经信任。")
                            .foregroundStyle(.secondary)
                    }
                    if let date = vpn.certificateCheckedAt {
                        LabeledContent("上次检查") { Text(date, style: .time) }
                    }
                } else {
                    Text("尚未检查系统信任").foregroundStyle(.secondary)
                }
            } header: { Text("3 · 信任与验证") } footer: {
                Text("使用此 CA 签发的临时证书交给系统 HTTPS 策略校验，不添加自定义信任锚，也不跳过验证。通过仅代表证书准备就绪，不代表 TLS 解密或定位成功。")
            }

            Section("结束实验") {
                Text("完全信任根证书会扩大系统的 HTTPS 信任范围；即使本 App 尚未启用解密，也请仅在自己的测试设备上操作。停止隧道不会移除系统已安装的证书。")
                Text("不再测试时，到「设置 → 通用 → VPN 与设备管理」移除“StikDebug WLOC 实验证书”。无需移除其他证书或描述文件。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("WLOC 实验证书")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("生成本机实验证书？", isPresented: $confirmPrepare, titleVisibility: .visible) {
            Button("生成证书") { Task { await vpn.performCertificateCommand(.prepare) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("生成不会开启解密，也不会自动安装或信任。只有你在系统设置中确认后，系统才可能信任此 CA。")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await vpn.load()
            await vpn.performCertificateCommand(.status)
        }
        .onChange(of: vpn.status) { _, newValue in
            if newValue.isConnected { Task { await vpn.performCertificateCommand(.status) } }
        }
    }

    private func formattedFingerprint(_ fingerprint: String) -> String {
        let characters = Array(fingerprint)
        return stride(from: 0, to: characters.count, by: 8).map { offset in
            String(characters[offset..<min(offset + 8, characters.count)])
        }.joined(separator: " ")
    }
}
