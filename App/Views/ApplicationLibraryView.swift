import SwiftUI
import UIKit

struct ApplicationLibraryView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var scripts: ScriptLibrary
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    let openSetup: () -> Void
    @State private var searchText = ""
    @State private var collection = ApplicationCollection.all
    @State private var selectedApplication: LauncherApplication?

    init(model: LauncherModel, openSetup: @escaping () -> Void) {
        self.model = model
        self.scripts = model.scripts
        self.vpn = model.vpn
        self.pairing = model.pairing
        self.openSetup = openSetup
    }

    private var isAvailable: Bool { model.isPrepared && vpn.isConnected }
    private var isWorking: Bool { model.isBusy || vpn.isBusy || pairing.isRunning }
    private var canRequestIcons: Bool { isAvailable && !model.isBusy && model.isDeviceAccessVerified }
    private var isLoadingApplications: Bool { model.isBusy && model.progressKey == "progress.loading_apps" }
    private var debuggableApplications: [LauncherApplication] { model.applications.filter(\.isDebuggable) }

    private var matchingApplications: [LauncherApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var apps = debuggableApplications.filter { app in
            let matchesSearch = query.isEmpty || app.name.localizedStandardContains(query) || app.bundleIdentifier.localizedStandardContains(query)
            let matchesCollection = collection == .all ||
                (collection == .favorites && scripts.isFavorite(app.id)) ||
                (collection == .recent && scripts.recentBundleIDs.contains(app.id))
            return matchesSearch && matchesCollection
        }
        if collection == .recent {
            let positions = Dictionary(uniqueKeysWithValues: scripts.recentBundleIDs.enumerated().map { ($0.element, $0.offset) })
            apps.sort { positions[$0.id, default: .max] < positions[$1.id, default: .max] }
        } else {
            apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return apps
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionStatusLabel(status: vpn.status)
                    if !isAvailable {
                        Text("apps.setup_body", tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(action: openSetup) {
                            Text("apps.open_setup", tableName: "Library")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("apps.introduction", tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if model.isBusy { PreparationProgress(model: model) }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker(selection: $collection) {
                    ForEach(ApplicationCollection.allCases) { option in
                        Text(LocalizedStringKey(option.key), tableName: "Library").tag(option)
                    }
                } label: {
                    Text("apps.collection", tableName: "Library")
                }
                .pickerStyle(.segmented)
            }

            if let error = model.applicationError {
                Section {
                    LauncherMessage(message: error, isError: true)
                    refreshButton
                }
            }

            Section {
                if debuggableApplications.isEmpty && isLoadingApplications {
                    Text("apps.loading_body", tableName: "Library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if debuggableApplications.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(isAvailable ? "apps.empty_title" : "apps.not_loaded_title", tableName: "Library")
                                .font(.headline)
                        } icon: {
                            Image(systemName: "square.grid.2x2")
                                .foregroundStyle(.secondary)
                        }
                        Text(isAvailable ? "apps.empty_body" : "apps.not_loaded_body", tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if isAvailable { refreshButton }
                    }
                    .padding(.vertical, 8)
                } else if matchingApplications.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyCollectionTitle, tableName: "Library")
                            .font(.headline)
                        Text(emptyCollectionBody, tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(matchingApplications) { app in
                        Button { selectedApplication = app } label: {
                            ApplicationLibraryRow(application: app,
                                                  iconData: model.applicationIcons[app.id] ?? app.iconPNG,
                                                  isFavorite: scripts.isFavorite(app.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("apps.row_hint", tableName: "Library"))
                        .task(id: ApplicationIconRequestID(bundleIdentifier: app.id, isReady: canRequestIcons, revision: model.iconLoadRevision)) {
                            if canRequestIcons { model.requestApplicationIcon(for: app) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { scripts.toggleFavorite(app.id) } label: {
                                Text(scripts.isFavorite(app.id) ? "apps.unfavorite" : "apps.favorite", tableName: "Library")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button { scripts.toggleFavorite(app.id) } label: {
                                Label {
                                    Text(scripts.isFavorite(app.id) ? "apps.unfavorite" : "apps.favorite", tableName: "Library")
                                } icon: {
                                    Image(systemName: scripts.isFavorite(app.id) ? "star.slash" : "star")
                                }
                            }
                        }
                    }
                }
            } header: {
                if debuggableApplications.isEmpty && isLoadingApplications {
                    Text("apps.collection.all", tableName: "Library")
                } else {
                    Text("apps.count \(matchingApplications.count)", tableName: "Library")
                }
            } footer: {
                Text("apps.compatibility", tableName: "Library")
            }

            if let message = model.successMessage {
                Section { LauncherMessage(message: message) }
            }
        }
        .navigationTitle(Text("apps.title", tableName: "Library"))
        .searchable(text: $searchText, prompt: Text("apps.search", tableName: "Library"))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { refreshButton }
        }
        .sheet(item: $selectedApplication) { app in
            ApplicationDetailSheet(model: model, application: app) {
                selectedApplication = nil
                openSetup()
            }
        }
        .onAppear {
            if isAvailable && !isWorking && model.applications.isEmpty {
                model.refreshApplications()
            }
        }
    }

    private var refreshButton: some View {
        Button { model.refreshApplications() } label: {
            Label {
                Text("apps.refresh", tableName: "Library")
            } icon: { Image(systemName: "arrow.clockwise") }
        }
        .disabled(!isAvailable || isWorking)
    }

    private var emptyCollectionTitle: LocalizedStringKey {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "apps.no_results" }
        return collection == .favorites ? "apps.favorites_empty" : "apps.recent_empty"
    }
    private var emptyCollectionBody: LocalizedStringKey {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "apps.no_results_body" }
        return collection == .favorites ? "apps.favorites_empty_body" : "apps.recent_empty_body"
    }
}

private enum ApplicationCollection: String, CaseIterable, Identifiable {
    case all, favorites, recent
    var id: String { rawValue }
    var key: String { "apps.collection.\(rawValue)" }
}

private struct ApplicationIconRequestID: Hashable {
    let bundleIdentifier: String
    let isReady: Bool
    let revision: Int
}

private struct ApplicationLibraryRow: View {
    let application: LauncherApplication
    let iconData: Data?
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            ApplicationIcon(data: iconData, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(application.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text("apps.favorite_badge", tableName: "Library"))
                    }
                }
                Text(application.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ApplicationIcon: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let icon = UIImage(data: data) {
                Image(uiImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

private struct ApplicationDetailSheet: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var scripts: ScriptLibrary
    @ObservedObject private var vpn: LocalVPNManager
    @ObservedObject private var pairing: OnDevicePairingManager
    let application: LauncherApplication
    let openSetup: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(model: LauncherModel, application: LauncherApplication, openSetup: @escaping () -> Void) {
        self.model = model
        self.scripts = model.scripts
        self.vpn = model.vpn
        self.pairing = model.pairing
        self.application = application
        self.openSetup = openSetup
    }

    private var canLaunch: Bool {
        model.isPrepared && vpn.isConnected && !model.isBusy && !vpn.isBusy && !pairing.isRunning
    }

    private var canRequestIcon: Bool {
        model.isPrepared && vpn.isConnected && !model.isBusy && model.isDeviceAccessVerified
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        ApplicationIcon(data: model.applicationIcons[application.id] ?? application.iconPNG, size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(application.name).font(.title2.bold())
                            Text(application.bundleIdentifier)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("apps.jit_eligible", tableName: "Library")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    Button { scripts.toggleFavorite(application.id) } label: {
                        Label {
                            Text(scripts.isFavorite(application.id) ? "apps.unfavorite" : "apps.favorite", tableName: "Library")
                        } icon: {
                            Image(systemName: scripts.isFavorite(application.id) ? "star.fill" : "star")
                        }
                    }
                }

                if application.isDebuggable {
                    Section {
                        Picker(selection: Binding(
                            get: { scripts.assignedScriptID(for: application.id) ?? "automatic" },
                            set: { scripts.assign($0 == "automatic" ? nil : $0, to: application.id) }
                        )) {
                            Text("apps.script_automatic", tableName: "Library").tag("automatic")
                            ForEach(scripts.items) { script in
                                Text(script.name).tag(script.id)
                            }
                        } label: {
                            Text("apps.script", tableName: "Library")
                        }
                        .disabled(model.isBusy)
                        Text("apps.selected_script \(scripts.selectedScript(for: application).name)", tableName: "Library")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("apps.script_hint", tableName: "Library")
                    }
                }

                Section {
                    if !model.isPrepared || !vpn.isConnected {
                        Text("apps.setup_body", tableName: "Library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(action: openSetup) { Text("apps.open_setup", tableName: "Library") }
                    }
                    if application.isDebuggable {
                        Button {
                            model.launchApplication(application, enableJIT: true)
                            dismiss()
                        } label: {
                            Label {
                                Text("apps.launch_jit", tableName: "Library")
                            } icon: { Image(systemName: "bolt.fill") }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canLaunch)
                    }
                    Button {
                        model.launchApplication(application, enableJIT: false)
                        dismiss()
                    } label: {
                        Label {
                            Text("apps.launch", tableName: "Library")
                        } icon: { Image(systemName: "play.fill") }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canLaunch)
                } footer: {
                    Text("apps.launch_hint", tableName: "Library")
                }
            }
            .navigationTitle(Text("apps.details", tableName: "Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("library.done", tableName: "Library") }
                }
            }
        }
        .task(id: ApplicationIconRequestID(bundleIdentifier: application.id, isReady: canRequestIcon, revision: model.iconLoadRevision)) {
            if canRequestIcon {
                model.requestApplicationIcon(for: application)
            }
        }
    }
}
