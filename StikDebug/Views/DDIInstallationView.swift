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
                        Text("DDI 可选安装，App 不以安装状态阻止定位操作。")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("准备内置开发者镜像", systemImage: "shippingbox")
                        Label("自动连接并挂载到设备", systemImage: "externaldrive.badge.checkmark")
                        Text("镜像文件已内置。安装时会校验文件并按系统要求挂载，请保持设备连接。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pikminCard()

                    status
                    VStack(spacing: 12) {
                        if !installer.isRunning {
                            Button { installer.start() } label: {
                                Text(installer.phase == .idle ? "准备并安装内置 DDI" : "重新检查并安装")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PikminUI.actionGreen)
                            if case .failed = installer.phase {
                                Button("恢复内置文件并安装") { installer.start(restore: true) }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .buttonStyle(.bordered)
                            }
                        } else if installer.canCancel {
                            Button("取消准备") { installer.cancel() }
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
        case .installing:
            VStack(alignment: .leading, spacing: 10) {
                Text("正在准备内置 DDI…").font(.headline)
                ProgressView(value: installer.installationProgress)
                Text(installer.installationDetail).font(.footnote).foregroundStyle(.secondary)
            }
        case .mounting:
            progress("正在挂载 DDI，请稍候…")
            Text("挂载按系统要求进行，完成后会自动检查安装结果。")
                .font(.footnote).foregroundStyle(.secondary)
        case .cancelling: progress("正在取消准备…")
        case .completed:
            Label("DDI 已安装并挂载", systemImage: "checkmark.circle.fill")
                .foregroundStyle(PikminUI.green)
        case .cancelled:
            Label("准备已取消，可以稍后继续。", systemImage: "pause.circle")
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
