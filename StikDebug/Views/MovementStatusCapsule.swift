import CoreLocation
import SwiftUI

private struct MovementStatusPresentation {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let isProgressing: Bool
}

/// 地图上的统一状态入口。折叠时只保留最重要的运行信息，展开后再给出诊断和修复动作。
struct MovementStatusCapsule: View {
    @EnvironmentObject private var session: WalkingSessionController
    @EnvironmentObject private var preflight: EnvironmentPreflightService
    @EnvironmentObject private var vpn: EmbeddedVPNService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var fixedSession = FixedLocationSessionController.shared

    let selectedMode: MovementMode
    let selectedProfile: MovementProfile
    let selectedSpeedKilometersPerHour: Double

    @State private var isExpanded = false

    private var presentation: MovementStatusPresentation {
        if vpn.isExperimentEnabled {
            return MovementStatusPresentation(
                title: "本机透传实验".localized,
                detail: "不修改定位；请在设置中停止测试后再开始模拟。".localized,
                symbol: "network",
                tint: .blue,
                isProgressing: vpn.isTransitioning
            )
        }
        if let error = session.lastError,
           session.phase == .failed || session.phase == .paused {
            return MovementStatusPresentation(
                title: session.phase == .paused ? "连接中断".localized : "无法开始".localized,
                detail: error,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                isProgressing: false
            )
        }

        switch session.phase {
        case .preparing:
            return MovementStatusPresentation(
                title: "正在准备模拟…".localized,
                detail: "正在连接设备并发送起始位置".localized,
                symbol: "location.fill",
                tint: PikminUI.green,
                isProgressing: true
            )
        case .running:
            return MovementStatusPresentation(
                title: "位置模拟中".localized,
                detail: session.activeMode?.title ?? selectedMode.title,
                symbol: "location.fill.viewfinder",
                tint: PikminUI.green,
                isProgressing: false
            )
        case .reconnecting:
            return MovementStatusPresentation(
                title: "正在重新连接…".localized,
                detail: String(
                    format: "第 %1$d / %2$d 次尝试".localized,
                    max(session.reconnectAttempt, 1),
                    SessionReconnectPolicy.maximumAttempts
                ),
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                tint: .orange,
                isProgressing: true
            )
        case .paused:
            return MovementStatusPresentation(
                title: "模拟已暂停".localized,
                detail: "当前位置会保持不变".localized,
                symbol: "pause.circle.fill",
                tint: .orange,
                isProgressing: false
            )
        case .completed:
            return MovementStatusPresentation(
                title: "会话已完成".localized,
                detail: "可选择新位置或再次开始".localized,
                symbol: "checkmark.circle.fill",
                tint: PikminUI.green,
                isProgressing: false
            )
        case .failed:
            return MovementStatusPresentation(
                title: "无法开始".localized,
                detail: "展开查看需要处理的项目".localized,
                symbol: "xmark.octagon.fill",
                tint: .red,
                isProgressing: false
            )
        case .idle:
            if fixedSession.coordinate != nil {
                return MovementStatusPresentation(
                    title: "定点模拟中".localized,
                    detail: "后台持续刷新设备位置".localized,
                    symbol: "mappin.circle.fill",
                    tint: PikminUI.green,
                    isProgressing: false
                )
            }
            return idlePresentation
        }
    }

    private var idlePresentation: MovementStatusPresentation {
        switch vpn.status {
        case .loading, .connecting, .disconnecting:
            return MovementStatusPresentation(
                title: vpn.status.title,
                detail: "正在准备设备连接".localized,
                symbol: "network",
                tint: .blue,
                isProgressing: true
            )
        case .failed(let message):
            return MovementStatusPresentation(
                title: "VPN 连接失败".localized,
                detail: message,
                symbol: "exclamationmark.shield.fill",
                tint: .red,
                isProgressing: false
            )
        case .disconnected:
            return MovementStatusPresentation(
                title: "需要连接 VPN".localized,
                detail: "展开后可直接连接".localized,
                symbol: "network.slash",
                tint: .orange,
                isProgressing: false
            )
        case .connected:
            if preflight.isRefreshing {
                return MovementStatusPresentation(
                    title: "正在检查环境…".localized,
                    detail: "确认配对和设备通道".localized,
                    symbol: "checkmark.shield",
                    tint: .blue,
                    isProgressing: true
                )
            }
            if !preflight.canStartSession {
                return MovementStatusPresentation(
                    title: "环境未准备好".localized,
                    detail: "还有 \(preflight.blockingItems.count) 项需要处理",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    isProgressing: false
                )
            }
            return MovementStatusPresentation(
                title: "已准备好".localized,
                detail: "选择位置后即可开始".localized,
                symbol: "checkmark.circle.fill",
                tint: PikminUI.green,
                isProgressing: false
            )
        }
    }

    private var effectiveMode: MovementMode {
        session.activeMode ?? selectedMode
    }

    private var effectiveSpeed: Double {
        session.activeSpeedKilometersPerHour ?? selectedSpeedKilometersPerHour
    }

    private var usesPikminIcon: Bool {
        if session.lastError != nil,
           session.phase == .failed || session.phase == .paused {
            return false
        }

        switch session.phase {
        case .preparing, .running, .reconnecting, .paused, .completed:
            return true
        case .failed:
            return false
        case .idle:
            if fixedSession.coordinate != nil { return true }
            switch vpn.status {
            case .failed, .disconnected:
                return false
            case .loading, .connecting, .disconnecting, .connected:
                return true
            }
        }
    }

    private var animatesPikmin: Bool {
        switch session.phase {
        case .preparing, .running, .reconnecting:
            return true
        case .idle:
            if fixedSession.coordinate != nil { return true }
            switch vpn.status {
            case .loading, .connecting, .disconnecting:
                return true
            case .connected:
                return preflight.isRefreshing
            case .failed, .disconnected:
                return false
            }
        case .paused, .completed, .failed:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy(duration: 0.24)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                collapsedContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("位置模拟状态：\(presentation.title)")
            .accessibilityHint(isExpanded ? "轻点收起诊断" : "轻点展开诊断")

            if isExpanded {
                Divider()
                    .padding(.top, 10)

                diagnosticContent
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.24), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 7)
    }

    private var collapsedContent: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(presentation.tint.opacity(0.16))
                    .frame(width: 34, height: 34)

                if usesPikminIcon {
                    PikminBounceIcon(
                        isAnimating: animatesPikmin,
                        size: 29,
                        amplitude: 2.2
                    )
                } else if presentation.isProgressing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(presentation.tint)
                } else {
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(presentation.tint)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private var summaryLine: String {
        if session.phase == .running || session.phase == .reconnecting || session.phase == .paused {
            if session.phase == .reconnecting {
                return presentation.detail
            }
            let profileTitle = selectedProfile.title
            let modeTitle = effectiveMode.title
            return String(format: "%1$@ · %2$@ · %3$.1f km/h".localized, profileTitle, modeTitle, effectiveSpeed)
        }
        return presentation.detail
    }

    private var diagnosticContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coordinate = session.currentCoordinate ?? fixedSession.coordinate {
                diagnosticRow(
                    title: "模拟坐标".localized,
                    value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                    symbol: "mappin.and.ellipse"
                )
            }

            diagnosticRow(
                title: "内置 VPN".localized,
                value: vpn.status.title,
                symbol: "network.badge.shield.half.filled"
            )

            if !preflight.blockingItems.isEmpty {
                ForEach(preflight.blockingItems) { item in
                    diagnosticRow(
                        title: item.kind.title,
                        value: item.status.message,
                        symbol: item.kind.systemImage
                    )
                }
            } else {
                diagnosticRow(
                    title: "设备通道".localized,
                    value: "检查已通过".localized,
                    symbol: "checkmark.shield.fill"
                )
            }

            HStack(spacing: 10) {
                if !vpn.status.isConnected {
                    Button {
                        Task { await vpn.connect() }
                    } label: {
                        Label("连接 VPN", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PikminUI.green)
                    .disabled(vpn.status == .connecting || vpn.status == .disconnecting)
                }

                Button {
                    Task { await preflight.refresh() }
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PikminUI.green)
                .disabled(preflight.isRefreshing)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func diagnosticRow(title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(PikminUI.deepGreen)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PikminBounceIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isAnimating: Bool
    let size: CGFloat
    let amplitude: CGFloat

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 15,
            paused: reduceMotion || !isAnimating
        )) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let wave = abs(sin(elapsed * .pi * 2 / 0.72))
            let lift = reduceMotion || !isAnimating ? 0 : wave * amplitude

            Image("PikminSprout")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .offset(y: -lift)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
