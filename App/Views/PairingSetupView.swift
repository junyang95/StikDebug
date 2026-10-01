import SwiftUI
import UniformTypeIdentifiers

struct PairingSetupView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    let openLaunch: () -> Void
    @State private var importingPairing = false
    @State private var importerError: String?

    init(model: LauncherModel, openLaunch: @escaping () -> Void) {
        self.model = model
        self.vpn = model.vpn
        self.openLaunch = openLaunch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("setup.title")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("setup.introduction")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    developerModeStep
                    Divider().padding(.leading, 72)
                    pairingStep
                    Divider().padding(.leading, 72)
                    vpnStep
                    Divider().padding(.leading, 72)
                    preparationStep
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                Text("setup.reuse_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("app.name")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.importPairingFile(from: url)
            case .failure(let error): importerError = error.localizedDescription
            }
        }
        .alert("pairing.import_failed", isPresented: Binding(
            get: { importerError != nil },
            set: { if !$0 { importerError = nil } }
        )) {
            Button("common.ok") { importerError = nil }
        } message: {
            Text(importerError ?? "")
        }
    }

    private var developerModeStep: some View {
        SetupStep(number: 1, title: "setup.developer.title", status: model.developerModeConfirmed ? "setup.confirmed" : "setup.confirm_needed", isComplete: model.developerModeConfirmed) {
            Text("setup.developer.instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle("setup.developer.confirm", isOn: $model.developerModeConfirmed)
                .font(.subheadline)
                .disabled(model.isBusy)
                .accessibilityHint("setup.developer.confirm_hint")
            DisclosureGroup("setup.developer.missing_title") {
                Text("setup.developer.missing_body")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.subheadline)
        }
    }

    private var pairingStep: some View {
        SetupStep(number: 2, title: "setup.pairing.title", status: model.pairingFileName == nil ? "setup.pending" : "setup.imported", isComplete: model.pairingFileName != nil) {
            Text("setup.pairing.instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let name = model.pairingFileName {
                Label(name, systemImage: "doc.badge.gearshape")
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("pairing.current_file \(name)"))
            }
            Button {
                importingPairing = true
            } label: {
                Label(model.pairingFileName == nil ? "pairing.import" : "pairing.replace", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            DisclosureGroup("pairing.create_title") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("pairing.create.instructions")
                        .foregroundStyle(.secondary)
                    Link("pairing.create.open_tool", destination: URL(string: "https://github.com/jkcoxson/idevice_pair")!)
                    Text("pairing.create.remote_only")
                        .foregroundStyle(.secondary)
                    Text("pairing.privacy")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
    }

    private var vpnStep: some View {
        SetupStep(number: 3, title: "setup.vpn.title", status: vpn.isConnected ? "setup.connected" : "setup.pending", isComplete: vpn.isConnected) {
            Text("setup.vpn.instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ConnectionStatusLabel(status: vpn.status)
            Button {
                Task { await vpn.connect() }
            } label: {
                HStack(spacing: 8) {
                    if vpn.isBusy { ProgressView().controlSize(.small) }
                    Text(vpn.isConnected ? "vpn.connected" : "vpn.connect")
                }
            }
            .buttonStyle(.bordered)
            .disabled(vpn.isBusy || vpn.isConnected || model.isBusy)
            if let message = vpn.errorMessage {
                LauncherMessage(message: message, isError: true)
            }
            Text("vpn.local_only")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var preparationStep: some View {
        SetupStep(number: 4, title: "setup.prepare.title", status: model.isPrepared ? "setup.ready" : "setup.pending", isComplete: model.isPrepared) {
            Text("setup.prepare.instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.isBusy {
                PreparationProgress(model: model)
            }
            Button {
                model.prepareDevice()
            } label: {
                Label(model.isPrepared ? "setup.prepare.again" : "setup.prepare.action", systemImage: "iphone.badge.play")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || vpn.isBusy || !model.developerModeConfirmed || model.pairingFileName == nil || !vpn.isConnected)
            if model.isPrepared {
                Button("setup.open_launch", action: openLaunch)
                    .buttonStyle(.bordered)
            }
        }
    }
}
