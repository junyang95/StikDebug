import SwiftUI

struct WLOCProbeView: View {
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmStart = false

    private var ready: Bool {
        vpn.mode == .wlocProbe && vpn.status.isConnected && vpn.probeSnapshot?.listening == true
    }

    var body: some View {
        Form {
            Section {
                Label("第一阶段 · 只透传，不修改定位", systemImage: "network.badge.shield.half.filled")
                    .font(.headline)
                Text("不需要 CA、配对文件、快捷指令或远程代理。仅验证四个定位域名的 HTTPS 连接；其他网络不经过本代理。")
                    .foregroundStyle(.secondary)
                Text("请先恢复真实定位，并关闭 Shadowrocket 等其他 VPN。实验不能与定点、摇杆或路线同时运行。")
                    .foregroundStyle(.secondary)
            }

            Section("连接状态") {
                LabeledContent("当前模式", value: vpn.modeTitle)
                LabeledContent("VPN", value: vpn.status.title)
                LabeledContent("本机代理", value: ready ? "已就绪".localized : "未就绪".localized)
                if ready, let port = vpn.probeSnapshot?.port {
                    LabeledContent("监听地址", value: "127.0.0.1:\(port)")
                        .font(.caption.monospaced())
                }
                if vpn.isTransitioning {
                    ProgressView("正在切换隧道，请稍候…")
                }
                Button(vpn.isExperimentEnabled ? "停止测试并恢复隧道" : "开始本机测试") {
                    if vpn.isExperimentEnabled { Task { await vpn.stopProbe() } }
                    else { confirmStart = true }
                }
                .disabled(vpn.isTransitioning)
                .accessibilityIdentifier("wlocProbe.toggle")
                if let error = vpn.lastProbeError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section {
                NavigationLink {
                    WLOCCertificateView()
                } label: {
                    Label("第二阶段 · 本机实验证书", systemImage: "lock.doc")
                }
            } footer: {
                Text("透传验证后，可独立准备证书并检查信任。这一步仍不解密流量或修改位置。")
            }

            Section {
                Button {
                    Task { await vpn.runProbeSelfTest() }
                } label: {
                    if vpn.isSelfTesting { ProgressView("正在自测…") }
                    else { Label("运行 HTTPS 出网自测", systemImage: "checkmark.shield") }
                }
                .disabled(!ready || vpn.isTransitioning || vpn.isSelfTesting)
                .accessibilityIdentifier("wlocProbe.selfTest")
                if let result = vpn.selfTestResult {
                    Text(result).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("第一步 · App 内自测")
            } footer: {
                Text("自测会清空旧记录并关闭已有测试连接，然后通过系统代理设置请求 Apple 域名。不会跳转到网站，也不会绕过证书校验。")
            }

            Section {
                Button("清空记录并开始观察") {
                    Task { await vpn.resetProbeStatistics() }
                }
                .disabled(!ready || vpn.isTransitioning || vpn.isSelfTesting)
                .accessibilityIdentifier("wlocProbe.reset")
                if let snapshot = vpn.probeSnapshot {
                    LabeledContent("目标域名连接", value: "\(snapshot.totalConnections)")
                    LabeledContent("活动连接", value: "\(snapshot.activeConnections)")
                    LabeledContent("已发送", value: bytes(snapshot.uploadedBytes))
                    LabeledContent("已接收", value: bytes(snapshot.downloadedBytes))
                    LabeledContent("统计开始") { Text(snapshot.resetAt, style: .time) }
                    ForEach(WLOCProbePolicy.hosts, id: \.self) { host in
                        let activity = snapshot.hosts[host] ?? ProbeHostActivity()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(host).font(.caption.monospaced()).textSelection(.enabled)
                            Text(String(format: "%d 个连接 · ↑ %@ · ↓ %@".localized,
                                        activity.connections, bytes(activity.uploadedBytes), bytes(activity.downloadedBytes)))
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = activity.lastActivity {
                                Text(date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let error = snapshot.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("第二步 · 打开系统地图观察")
            } footer: {
                Text("清空会关闭之前的透传连接。随后打开系统地图，再回来查看计数；也可切后台 5 分钟后重试。这里只能确认域名连接，不能识别 /clls/wloc 或证明定位成功。没有新连接也可能是定位缓存或请求未触发。")
            }

            Section("实验限制") {
                Text("仅用于签名测试版本。网络扩展内托管本机代理不是 Apple 支持的用途；本阶段不提供正式分发或长期兼容保证。停止测试不会清除系统定位缓存，也不会恢复之前的模拟坐标。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本机 WLOC 连接测试")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("开始前请确认", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("已关闭其他 VPN，开始测试") { Task { await vpn.startProbe() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认旧的模拟定位已恢复。测试期间不会修改坐标；不要同时开启其他 VPN。")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await vpn.load()
            while !Task.isCancelled {
                await vpn.refreshProbeStatus()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
