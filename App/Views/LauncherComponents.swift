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

/// A guide row describes a user action; only the pairing service reports completion.
struct PairingGuideRow<Content: View>: View {
    let number: Int
    let content: Content

    init(number: Int, @ViewBuilder content: () -> Content) {
        self.number = number
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 28, minHeight: 28)
                .background(Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityLabel(Text("setup.step \(number)"))
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
