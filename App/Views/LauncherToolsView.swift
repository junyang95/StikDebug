import SwiftUI
import UniformTypeIdentifiers
import MapKit

func toolsString(_ key: String) -> String { NSLocalizedString(key, tableName: "Tools", comment: "") }

struct LauncherToolsView: View {
    @ObservedObject var model: LauncherModel
    let openSetup: () -> Void

    var body: some View {
        List {
            if !model.isPrepared {
                Section {
                    Text(toolsString("tools.prepare_hint")).foregroundStyle(.secondary)
                    Button(toolsString("tools.open_setup"), action: openSetup)
                }
            }
            Section {
                NavigationLink { ScriptLibraryView(library: model.scripts) } label: {
                    toolRow("tools.scripts", "tools.scripts.detail", "scroll")
                }
                NavigationLink { LaunchView(model: model, openSetup: openSetup) } label: {
                    toolRow("tools.processes", "tools.processes.detail", "rectangle.stack")
                }
                NavigationLink { LauncherConsoleView(model: model) } label: {
                    toolRow("tools.console", "tools.console.detail", "terminal")
                }
            } header: { Text(toolsString("tools.debugging")) }
            Section {
                NavigationLink { LauncherDeviceView(model: model) } label: {
                    toolRow("tools.device", "tools.device.detail", "iphone")
                }
                NavigationLink { LauncherProfilesView(model: model) } label: {
                    toolRow("tools.profiles", "tools.profiles.detail", "calendar.badge.clock")
                }
                NavigationLink { LauncherLocationView(model: model) } label: {
                    toolRow("tools.location", "tools.location.detail", "location")
                }
            } header: { Text(toolsString("tools.device_tools")) }
            Section {
                Text(toolsString("tools.shortcuts.detail"))
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text(verbatim: "jitlauncher://enable-jit?bundle-id=com.example.app")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: { Text(toolsString("tools.shortcuts")) }
        }
        .navigationTitle(toolsString("tools.title"))
    }

    private func toolRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(toolsString(title))
                Text(toolsString(detail)).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
    }
}

private struct LauncherDeviceView: View {
    @ObservedObject var model: LauncherModel
    var body: some View {
        List {
            if model.deviceDetails.isEmpty {
                Text(toolsString("device.empty")).foregroundStyle(.secondary)
            }
            ForEach(model.deviceDetails.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Text(model.deviceDetails[key] ?? "").textSelection(.enabled)
                }
            }
        }
        .navigationTitle(toolsString("tools.device"))
        .toolbar {
            Button(toolsString("common.refresh")) { model.refreshDeviceDetails() }
                .disabled(model.isBusy || model.pairing.isRunning)
        }
        .overlay { if model.isBusy { ProgressView() } }
    }
}

private struct LauncherProfilesView: View {
    @ObservedObject var model: LauncherModel
    @State private var importing = false
    @State private var exportItem: LauncherProfile?
    @State private var exporting = false
    @State private var removing: LauncherProfile?
    @State private var fileError: String?
    var body: some View {
        List {
            Section {
                Text(toolsString("profiles.help")).font(.subheadline).foregroundStyle(.secondary)
                Button(toolsString("profiles.import")) { importing = true }
                    .disabled(model.isBusy || model.pairing.isRunning)
            }
            if model.profiles.isEmpty {
                Text(toolsString("profiles.empty")).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.headline)
                        Text(profile.appIdentifier).font(.caption).textSelection(.enabled)
                        if let expiration = profile.expirationDate {
                            LabeledContent(toolsString("profiles.expiry")) {
                                Text(expiration, format: .dateTime.year().month().day())
                                    .foregroundStyle(expiration < Date() ? Color.red : .secondary)
                            }.font(.subheadline)
                        }
                        Text(profile.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button(toolsString("profiles.export")) { exportItem = profile; exporting = true }
                            Spacer()
                            Button(toolsString("profiles.remove"), role: .destructive) { removing = profile }
                        }.buttonStyle(.borderless).disabled(model.isBusy)
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(toolsString("tools.profiles"))
        .toolbar {
            Button(toolsString("common.refresh")) { model.refreshProfiles() }
                .disabled(model.isBusy || model.pairing.isRunning)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): model.importProfile(from: url)
            case .failure(let error): fileError = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: LauncherProfileDocument(data: exportItem?.data ?? Data()),
                      contentType: .data, defaultFilename: "profile.mobileprovision") { result in
            if case .failure(let error) = result { fileError = error.localizedDescription }
        }
        .confirmationDialog(toolsString("profiles.remove_title"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button(toolsString("profiles.remove"), role: .destructive) {
                if let removing { model.removeProfile(removing) }
                removing = nil
            }
        } message: { Text(toolsString("profiles.remove_warning")) }
        .alert(toolsString("common.error"), isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("common.ok") { fileError = nil }
        } message: { Text(fileError ?? "") }
        .overlay { if model.isBusy { ProgressView() } }
    }
}

private struct LauncherProfileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct LauncherConsoleView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var console: LauncherConsole
    @State private var source = 0
    @State private var search = ""
    init(model: LauncherModel) { self.model = model; console = model.console }
    private var lines: [String] {
        let all = source == 0 ? model.operationLog : console.lines
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker(toolsString("console.source"), selection: $source) {
                Text(toolsString("console.jit")).tag(0)
                Text(toolsString("console.system")).tag(1)
            }.pickerStyle(.segmented).padding()
            if source == 1 {
                HStack {
                    Button(toolsString(console.isRunning ? "console.stop" : "console.start")) {
                        if console.isRunning { console.stop() } else { model.startConsole() }
                    }.disabled(console.isStopping || model.isBusy || model.pairing.isRunning)
                    if console.isRunning {
                        Button(toolsString(console.isPaused ? "console.resume" : "console.pause")) { console.isPaused.toggle() }
                            .disabled(console.isStopping)
                    }
                    Spacer()
                    Text("\(console.lines.count)/1500").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal)
                if console.isStopping {
                    Text(toolsString("console.stopping")).font(.caption).foregroundStyle(.secondary).padding()
                }
                if let error = console.errorMessage { LauncherMessage(message: error, isError: true).padding() }
            }
            if lines.isEmpty {
                ContentUnavailableView(toolsString("console.empty"), systemImage: "terminal",
                                       description: Text(toolsString("console.empty_help")))
            } else {
                List(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }.listStyle(.plain)
            }
        }
        .navigationTitle(toolsString("tools.console"))
        .searchable(text: $search, prompt: toolsString("console.search"))
        .toolbar {
            Button(toolsString("console.clear")) {
                if source == 0 { model.clearOperationLog() } else { console.clear() }
            }
        }
        .onDisappear { console.stop() }
    }
}

private struct LauncherLocationView: View {
    @ObservedObject var model: LauncherModel
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var confirming = false
    private var point: CLLocationCoordinate2D? {
        guard let value = LauncherInput.coordinate(latitude, longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: value.0, longitude: value.1)
    }
    var body: some View {
        Form {
            Section {
                MapReader { proxy in
                    Map(position: $camera) {
                        if let point { Marker(toolsString("location.target"), coordinate: point) }
                    }
                    .onTapGesture { position in
                        guard let coordinate = proxy.convert(position, from: .local) else { return }
                        latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
                        longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
                    }
                }.frame(height: 240)
                Text(toolsString("location.map_hint")).font(.caption).foregroundStyle(.secondary)
                TextField(toolsString("location.latitude"), text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField(toolsString("location.longitude"), text: $longitude).keyboardType(.numbersAndPunctuation)
            }
            Section {
                Button(toolsString("location.apply")) { confirming = true }
                    .disabled(point == nil || model.isBusy || model.pairing.isRunning)
                Button(toolsString("location.restore")) { model.restoreLocation() }
                    .disabled(model.isBusy || model.pairing.isRunning)
                if model.locationIsSimulated {
                    Label(toolsString("location.active"), systemImage: "location.fill").foregroundStyle(.orange)
                }
            } footer: { Text(toolsString("location.warning")) }
            if let message = model.successMessage { Section { LauncherMessage(message: message) } }
        }
        .navigationTitle(toolsString("tools.location"))
        .confirmationDialog(toolsString("location.apply"), isPresented: $confirming, titleVisibility: .visible) {
            Button(toolsString("location.apply")) { model.simulateLocation(latitude: latitude, longitude: longitude) }
        } message: { Text(toolsString("location.warning")) }
    }
}
