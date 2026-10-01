import SwiftUI
import UniformTypeIdentifiers

struct PairingSetupView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    let openLaunch: () -> Void
    @State private var importingPairing = false
    @State private var importerError: String?

    init(model: LauncherModel, openLaunch: @escaping () -> Void) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
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

                pairingGuide
                pairingStatus
                manualPairing
                afterPairing

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

    private var pairingGuide: some View {
        VStack(spacing: 0) {
            PairingGuideRow(number: 1) {
                Button {
                    Task { await pairing.start() }
                } label: {
                    Label("pairing.on_device.start", systemImage: "iphone.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || vpn.isBusy || pairing.isRunning || !pairing.isSupported)
                .accessibilityHint("pairing.on_device.start_hint")
            }
            ForEach(2...7, id: \.self) { number in
                Divider().padding(.leading, 60)
                PairingGuideRow(number: number) {
                    Text(LocalizedStringKey("pairing.guide.step" + String(number)))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var pairingStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pairing.isSupported {
                Label("pairing.on_device.unsupported", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if pairing.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(pairing.statusKey))
                        .font(.subheadline)
                }
                if pairing.isRunning {
                    Button("pairing.on_device.cancel") { pairing.cancel() }
                        .buttonStyle(.bordered)
                }
            }

            if let code = pairing.pinCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("pairing.on_device.pin_title")
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: code)
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("pairing.on_device.pin_accessibility \(code.map(String.init).joined(separator: " "))"))
                    Text("pairing.on_device.pin_hint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            if let message = pairing.notificationMessage {
                Label(message, systemImage: "bell.badge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = pairing.errorMessage {
                LauncherMessage(message: message, isError: true)
            }
            Text("pairing.on_device.guide_hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let name = model.pairingFileName {
                Label {
                    Text("pairing.current_file \(name)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }

    private var manualPairing: some View {
        DisclosureGroup("pairing.manual.title") {
            VStack(alignment: .leading, spacing: 12) {
                Text("pairing.manual.instructions")
                    .foregroundStyle(.secondary)
                Button {
                    importingPairing = true
                } label: {
                    Label(model.pairingFileName == nil ? "pairing.import" : "pairing.replace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || pairing.isRunning)
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
            }
            .font(.subheadline)
            .padding(.top, 12)
        }
        .font(.subheadline)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var afterPairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("setup.after_pairing")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 20) {
                Toggle("setup.developer.confirm", isOn: $model.developerModeConfirmed)
                    .font(.subheadline)
                    .disabled(model.isBusy || pairing.isRunning)
                    .accessibilityHint("setup.developer.confirm_hint")
                Text("setup.developer.instructions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Divider()
                vpnSection
                Divider()
                preparationSection
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var vpnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("setup.vpn.title", systemImage: "network.badge.shield.half.filled")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
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
            .disabled(vpn.isBusy || vpn.isConnected || model.isBusy || pairing.isRunning)
            if let message = vpn.errorMessage {
                LauncherMessage(message: message, isError: true)
            }
            Text("vpn.local_only")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("setup.prepare.title", systemImage: "iphone.badge.play")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("setup.prepare.instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.isBusy {
                PreparationProgress(model: model)
            }
            Button {
                model.prepareDevice()
            } label: {
                Text(model.isPrepared ? "setup.prepare.again" : "setup.prepare.action")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || pairing.isRunning || vpn.isBusy || !model.developerModeConfirmed || model.pairingFileName == nil || !vpn.isConnected)
            if model.isPrepared {
                Button("setup.open_launch", action: openLaunch)
                    .buttonStyle(.bordered)
            }
        }
    }
}
