import SwiftUI

struct DDIInstallationView: View {
    @ObservedObject var installer: DDIInstallationController = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(PikminUI.green)
                            .accessibilityHidden(true)
                        Text("为额外开发服务安装 DDI")
                            .font(.title2.bold())
                        Text("DDI 是可选组件，未安装也可以使用定位模拟。")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("下载缺少的文件", systemImage: "arrow.down.circle")
                        Label("自动连接并挂载到设备", systemImage: "externaldrive.badge.checkmark")
                        Text("下载来源：static.wow-app.store。文件较大，建议使用 Wi‑Fi；使用 4G/5G 会消耗流量。已下载的完整文件会保留，重试时无需重复下载。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pikminCard()

                    status
                    VStack(spacing: 12) {
                        if !installer.isRunning {
                            Button { installer.start() } label: {
                                Text(installer.phase == .idle ? "下载并安装 DDI" : "重新检查并安装")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PikminUI.actionGreen)
                            if case .failed = installer.phase {
                                Button("重新下载全部文件并安装") { installer.start(redownload: true) }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .buttonStyle(.bordered)
                            }
                        } else if installer.canCancel {
                            Button("取消下载") { installer.cancel() }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .buttonStyle(.bordered)
                        }
                        if installer.isRunning {
                            Text("请保持 App 在前台。可以关闭此页面，安装会在 App 内继续。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(PikminUI.pageBackground)
            .navigationTitle("DDI 安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }.frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch installer.phase {
        case .idle: EmptyView()
        case .preparing: progress("正在检查配对与内置 VPN…")
        case .downloading:
            VStack(alignment: .leading, spacing: 10) {
                Text("正在下载 DDI…").font(.headline)
                ProgressView(value: installer.downloadProgress)
                Text(installer.downloadDetail).font(.footnote).foregroundStyle(.secondary)
            }
        case .mounting:
            progress("正在挂载 DDI，请稍候…")
            Text("挂载可能需要几分钟。完成后会自动检查安装结果。")
                .font(.footnote).foregroundStyle(.secondary)
        case .cancelling: progress("正在取消下载…")
        case .completed:
            Label("DDI 已安装并挂载", systemImage: "checkmark.circle.fill")
                .foregroundStyle(PikminUI.green)
        case .cancelled:
            Label("下载已取消，可以稍后继续。", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("DDI 安装未完成", systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(.orange)
                Text(message).font(.subheadline).textSelection(.enabled)
            }
        }
    }

    private func progress(_ title: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
            Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
