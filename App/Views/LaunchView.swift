import SwiftUI

struct LaunchView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    let openSetup: () -> Void
    @State private var searchText = ""
    @State private var terminating: LauncherProcess?
    @FocusState private var pidFocused: Bool

    init(model: LauncherModel, openSetup: @escaping () -> Void) {
        self.model = model
        self.vpn = model.vpn
        self.pairing = model.pairing
        self.openSetup = openSetup
    }

    private var matchingProcesses: [LauncherProcess] {
        guard !searchText.isEmpty else { return model.processes }
        return model.processes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || String($0.id).contains(searchText)
        }
    }

    private var canLaunch: Bool {
        model.isPrepared && vpn.isConnected && !model.isBusy && !vpn.isBusy && !pairing.isRunning && Int32(model.targetPID).map { $0 > 0 } == true
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionStatusLabel(status: vpn.status)
                    Text("launch.instructions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !model.isPrepared || !vpn.isConnected {
                        Button("launch.finish_setup", action: openSetup)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text("launch.pid_label")
                    TextField("launch.pid_placeholder", text: $model.targetPID)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($pidFocused)
                        .disabled(model.isBusy || pairing.isRunning)
                        .accessibilityLabel("launch.pid_label")
                }
            } footer: {
                Text("launch.pid_hint")
            }

            Section {
                if model.processes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("launch.processes_empty_title")
                            .font(.headline)
                        Text("launch.processes_empty_body")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else if matchingProcesses.isEmpty {
                    Text("launch.no_search_results")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matchingProcesses) { process in
                        Button {
                            model.targetPID = String(process.id)
                            pidFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(process.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("launch.pid \(Int(process.id))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if model.targetPID == String(process.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy || pairing.isRunning)
                        .accessibilityAddTraits(model.targetPID == String(process.id) ? .isSelected : [])
                        .accessibilityHint("launch.select_process_hint")
                        .contextMenu {
                            Button(toolsString("process.terminate"), role: .destructive) { terminating = process }
                                .disabled(model.isBusy || pairing.isRunning)
                        }
                        .swipeActions {
                            Button(role: .destructive) { terminating = process } label: {
                                Label(toolsString("process.terminate"), systemImage: "stop.circle")
                            }.disabled(model.isBusy || pairing.isRunning)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("launch.processes_title")
                    Spacer()
                    Button {
                        pidFocused = false
                        model.refreshProcesses()
                    } label: {
                        Label("launch.refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(!model.isPrepared || !vpn.isConnected || model.isBusy || vpn.isBusy || pairing.isRunning)
                }
            } footer: {
                Text("launch.compatibility")
            }

            if let message = model.successMessage {
                Section { LauncherMessage(message: message) }
            }
        }
        .navigationTitle(toolsString("tools.processes"))
        .confirmationDialog(toolsString("process.confirm"), isPresented: Binding(
            get: { terminating != nil }, set: { if !$0 { terminating = nil } }
        ), titleVisibility: .visible) {
            Button(toolsString("process.terminate"), role: .destructive) {
                if let terminating { model.terminateProcess(terminating) }
                terminating = nil
            }
        } message: { Text(toolsString("process.warning")) }
        .searchable(text: $searchText, prompt: "launch.search")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isBusy { PreparationProgress(model: model) }
                Button {
                    pidFocused = false
                    model.enableJIT()
                } label: {
                    Label("launch.enable", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunch)
            }
            .frame(maxWidth: 680)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .onAppear {
            if model.isPrepared && vpn.isConnected && model.processes.isEmpty && !model.isBusy {
                model.refreshProcesses()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("common.done") { pidFocused = false }
            }
        }
    }
}
