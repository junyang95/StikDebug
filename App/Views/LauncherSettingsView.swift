import SwiftUI

struct LauncherSettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    let openSetup: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var confirmingRemoval = false

    init(model: LauncherModel, openSetup: @escaping () -> Void) {
        self.model = model
        self.vpn = model.vpn
        self.openSetup = openSetup
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("settings.local_connection") {
                    ConnectionStatusLabel(status: vpn.status)
                }
                Button {
                    Task {
                        if vpn.isConnected { await vpn.disconnect() }
                        else { await vpn.connect() }
                    }
                } label: {
                    Label(vpn.isConnected ? "vpn.disconnect" : "vpn.connect", systemImage: vpn.isConnected ? "pause.circle" : "play.circle")
                }
                .disabled(model.isBusy || vpn.isBusy)
                if let message = vpn.errorMessage {
                    LauncherMessage(message: message, isError: true)
                }
            } header: {
                Text("settings.connection")
            } footer: {
                Text("vpn.local_only")
            }

            Section {
                if let name = model.pairingFileName {
                    LabeledContent("settings.pairing_file", value: name)
                    Button("pairing.remove", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .disabled(model.isBusy)
                } else {
                    Text("settings.no_pairing")
                        .foregroundStyle(.secondary)
                }
                Button("settings.show_setup", action: openSetup)
            } header: {
                Text("settings.pairing")
            } footer: {
                Text("pairing.privacy")
            }

            Section {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("settings.language_open", systemImage: "globe")
                }
            } header: {
                Text("settings.language")
            } footer: {
                Text("settings.language_hint")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("app.name")
                        .font(.headline)
                    Text("settings.about_body")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Link("settings.stikjit_source", destination: URL(string: "https://github.com/StikDebug/StikJIT")!)
                Link("settings.localdevvpn_source", destination: URL(string: "https://github.com/jkcoxson/LocalDevVPN")!)
                Link("settings.idevice_source", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
                NavigationLink("settings.licenses") {
                    LauncherLicensesView()
                }
            } header: {
                Text("settings.about")
            }
        }
        .navigationTitle("settings.title")
        .confirmationDialog("pairing.remove_title", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("pairing.remove", role: .destructive) { model.removePairingFile() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("pairing.remove_message")
        }
    }
}

private struct LauncherLicensesView: View {
    var body: some View {
        List {
            Section("StikJIT") {
                Text("Mozilla Public License 2.0")
                NavigationLink("settings.read_license") {
                    BundledLicenseView(project: "StikJIT")
                }
                Link("settings.view_license", destination: URL(string: "https://github.com/StikDebug/StikJIT/blob/main/LICENSE")!)
            }
            Section("LocalDevVPN") {
                Text("settings.localdevvpn_license")
                NavigationLink("settings.read_license") {
                    BundledLicenseView(project: "LocalDevVPN")
                }
                Link("settings.view_license", destination: URL(string: "https://github.com/jkcoxson/LocalDevVPN")!)
            }
            Section("idevice") {
                Text("settings.idevice_license")
                Link("settings.view_license", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
            }
        }
        .navigationTitle("settings.licenses")
    }
}

private struct BundledLicenseView: View {
    let project: String

    private var license: String? {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil, subdirectory: "ThirdParty/\(project)") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            Group {
                if let license {
                    Text(license)
                        .textSelection(.enabled)
                } else {
                    Text("settings.license_unavailable")
                }
            }
            .font(.footnote)
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(project)
        .navigationBarTitleDisplayMode(.inline)
    }
}
