import SwiftUI

/// Restores the bundled developer image and prepares the device connection.
struct DDIRecoveryView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager

    init(model: LauncherModel) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
    }

    private var canRestore: Bool {
        model.isWiFiAvailable && !model.isBusy && !pairing.isRunning && !vpn.isBusy && model.canAttemptDeviceConnection
            && model.pairingFileName != nil && model.developerModeConfirmed
    }

    private var isPreparingImage: Bool {
        model.isBusy && [
            "progress.checking_device", "progress.checking_ddi", "progress.preparing_ddi",
            "progress.mounting_ddi", "progress.verifying_ddi"
        ].contains(model.progressKey)
    }

    var body: some View {
        Section {
            Button {
                model.restoreBundledDDI()
            } label: {
                Label {
                    Text("ddi.recovery.action", tableName: "DDI")
                } icon: {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(!canRestore)
            if isPreparingImage {
                PreparationProgress(model: model)
                    .padding(.vertical, 4)
            }
        } header: {
            Text("ddi.recovery.title", tableName: "DDI")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("ddi.recovery.help", tableName: "DDI")
                Text("ddi.recovery.requirements", tableName: "DDI")
                if !model.isWiFiAvailable { Text(LocalizedStringKey(model.wifiStatusKey)) }
            }
        }
    }
}
