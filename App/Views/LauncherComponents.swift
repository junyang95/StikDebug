import NetworkExtension
import SwiftUI

struct ConnectionStatusLabel: View {
    let status: NEVPNStatus

    var body: some View {
        Label(LocalizedStringKey(status.localizationKey), systemImage: status == .connected ? "checkmark.shield.fill" : "shield")
            .foregroundStyle(status == .connected ? Color.green : Color.secondary)
            .font(.subheadline)
            .accessibilityElement(children: .combine)
    }
}

extension NEVPNStatus {
    var localizationKey: String {
        switch self {
        case .invalid: return "vpn.status.not_configured"
        case .disconnected: return "vpn.status.disconnected"
        case .connecting: return "vpn.status.connecting"
        case .connected: return "vpn.status.connected"
        case .reasserting: return "vpn.status.reconnecting"
        case .disconnecting: return "vpn.status.disconnecting"
        @unknown default: return "vpn.status.unknown"
        }
    }
}

struct LauncherMessage: View {
    let message: String
    var isError = false

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PreparationProgress: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = model.progressFraction {
                ProgressView(value: fraction) {
                    Text(LocalizedStringKey(model.progressKey))
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(LocalizedStringKey(model.progressKey))
                        .font(.subheadline)
                }
            }
            Text(model.progressKey == "progress.enabling_jit" ? "launch.continue_in_target" : "common.keep_open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SetupStep<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let status: LocalizedStringKey
    let isComplete: Bool
    let content: Content

    init(number: Int, title: LocalizedStringKey, status: LocalizedStringKey, isComplete: Bool, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.status = status
        self.isComplete = isComplete
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number, format: .number)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(isComplete ? Color.white : Color.accentColor)
                .frame(minWidth: 36, minHeight: 36)
                .background(isComplete ? Color.accentColor : Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(Text("setup.step \(number)") + Text(". ") + Text(title))
                    Label(status, systemImage: isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isComplete ? Color.green : Color.secondary)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }
}
