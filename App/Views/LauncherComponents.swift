import NetworkExtension
import SwiftUI

/// Reports the app's observed connection state. External mode is verified by
/// a successful device-service check, not by reading another app's VPN profile.
struct DeviceConnectionStatusLabel: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager

    init(model: LauncherModel) {
        self.model = model
        self.vpn = model.vpn
    }

    var body: some View {
        Label(LocalizedStringKey(model.connectionStatusKey), systemImage: model.isDeviceConnectionReady ? "checkmark.shield.fill" : "shield")
            .foregroundStyle(model.isDeviceConnectionReady ? Color.green : Color.secondary)
            .font(.subheadline)
            .accessibilityElement(children: .combine)
    }
}

struct DeviceConnectionModePicker: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    @ObservedObject private var console: LauncherConsole

    init(model: LauncherModel) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
        self.console = model.console
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("connection.mode.title")
                .font(.subheadline.weight(.semibold))
            Picker("connection.mode.title", selection: Binding(
                get: { model.connectionMode },
                set: { model.setConnectionMode($0) }
            )) {
                Text("connection.mode.builtIn").tag(DeviceConnectionMode.builtIn)
                Text("connection.mode.external").tag(DeviceConnectionMode.external)
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy || vpn.isBusy || pairing.isRunning || console.isRunning || console.isStopping)
            .accessibilityHint("connection.mode.hint")
        }
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
            if let fraction = model.progressFraction, fraction.isFinite {
                ProgressView(value: min(max(fraction, 0), 1)) {
                    Text(LocalizedStringKey(model.progressKey))
                } currentValueLabel: {
                    Text(min(max(fraction, 0), 1), format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(LocalizedStringKey(model.progressKey))
                        .font(.subheadline)
                }
            }
            if let detail = model.progressDetail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
