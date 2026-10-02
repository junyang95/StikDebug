import SwiftUI

/// Replaces only the downloaded developer image; the model rechecks device access.
struct DDIRecoveryView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager

    init(model: LauncherModel) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
    }

    private var canRedownload: Bool {
        !model.isBusy && !pairing.isRunning && !vpn.isBusy && vpn.isConnected
            && model.pairingFileName != nil && model.developerModeConfirmed
    }

    private var isPreparingImage: Bool {
        model.isBusy && [
            "progress.checking_device", "progress.checking_ddi", "progress.downloading_ddi",
            "progress.mounting_ddi", "progress.verifying_ddi"
        ].contains(model.progressKey)
    }

    var body: some View {
        Section {
            Button {
                model.redownloadDDI()
            } label: {
                Label {
                    Text("ddi.recovery.action", tableName: "DDI")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(!canRedownload)
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
            }
        }
    }
}
