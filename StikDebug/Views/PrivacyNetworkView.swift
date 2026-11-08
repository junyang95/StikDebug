import SwiftUI

struct PrivacyNetworkView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                disclosure(
                    title: "无分析与跟踪",
                    detail: "App 不包含分析、广告、崩溃上报或遥测 SDK，也不建立用户账号。",
                    symbol: "hand.raised.fill",
                    tint: PikminUI.green
                )
                disclosure(
                    title: "只在设备保存",
                    detail: "pairing file、收藏、最近位置、路线和会话记录保存在本 App 容器中，不由 StikDebug 上传。",
                    symbol: "iphone.gen3.lock",
                    tint: .blue
                )
                disclosure(
                    title: "Apple 地图服务",
                    detail: "只有在使用地点搜索或路线规划时，搜索文字和路线端点会由系统 MapKit 交给 Apple 处理。直接输入坐标、导入 GPX 和手绘不需要这项请求。",
                    symbol: "map.fill",
                    tint: .indigo
                )
                disclosure(
                    title: "本地设备通信",
                    detail: "内置 VPN、配对和定位命令只访问本机与已配对设备的本地地址；VPN 不连接外部服务器。",
                    symbol: "network.badge.shield.half.filled",
                    tint: .mint
                )
                disclosure(
                    title: "本地设备绑定",
                    detail: "开始定位或开发操作前，App 会在本地核对安装包凭据与实际连接设备的标识，不向网站发送设备标识。恢复真实定位不受绑定检查限制。",
                    symbol: "checkmark.shield",
                    tint: .blue
                )
                disclosure(
                    title: "内置开发者镜像",
                    detail: "DDI 文件已内置，只有你选择安装时才会准备和挂载。挂载按系统要求进行，可能需要连接 Apple 服务；App 不以 DDI 安装状态阻止定位操作。",
                    symbol: "externaldrive.badge.questionmark",
                    tint: .orange
                )
                disclosure(
                    title: "由你主动分享",
                    detail: "GPX 和诊断日志只在你使用系统导出或分享面板后离开 App。诊断日志不包含 pairing file 内容或模拟坐标。",
                    symbol: "square.and.arrow.up",
                    tint: .purple
                )
            }
            .navigationTitle("隐私与网络")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(PikminUI.green)
    }

    private func disclosure(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title.localized).font(.subheadline.weight(.semibold))
                Text(detail.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
