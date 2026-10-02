import SwiftUI

struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var actions = LauncherActionRouter.shared
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("superapp.selectedTab") private var selectedTab = 0
    @State private var selectedInitialTab = false
    @State private var invalidLink = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ApplicationLibraryView(model: model) { selectedTab = 1 }
            }
            .tabItem { Label(NSLocalizedString("apps.title", tableName: "Library", comment: ""), systemImage: "square.grid.2x2") }
            .tag(0)
            NavigationStack {
                PairingSetupView(model: model) { selectedTab = 0 }
            }
            .tabItem { Label("tabs.setup", systemImage: "link") }
            .tag(1)
            NavigationStack {
                LauncherToolsView(model: model) { selectedTab = 1 }
            }
            .tabItem { Label(toolsString("tools.title"), systemImage: "wrench.and.screwdriver") }
            .tag(2)
            NavigationStack {
                LauncherSettingsView(model: model) { selectedTab = 1 }
            }
            .tabItem { Label("tabs.settings", systemImage: "gearshape") }
            .tag(3)
        }
        .task {
            model.enteredForeground()
            await model.refreshState()
            if !selectedInitialTab {
                selectedInitialTab = true
                selectedTab = model.pairingFileName == nil ? 1 : 0
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.enteredForeground()
                Task { await model.refreshState() }
            }
            else if phase == .background { model.enteredBackground() }
        }
        .onOpenURL { url in
            guard let request = LauncherExternalRequest(url: url) else { invalidLink = true; return }
            actions.request = request
        }
        .confirmationDialog(toolsString("external.confirm"), isPresented: Binding(
            get: { actions.request != nil }, set: { if !$0 { actions.request = nil } }
        ), titleVisibility: .visible) {
            if let request = actions.request {
                Button(toolsString(request.actionKey), role: request.isDestructive ? .destructive : nil) {
                    actions.request = nil
                    selectedTab = 0
                    model.executeExternal(request)
                }
            }
        } message: {
            if let request = actions.request { Text(toolsString(request.actionKey) + "\n" + request.target) }
        }
        .alert("common.action_failed", isPresented: Binding(
            get: { model.errorMessage != nil || invalidLink },
            set: { if !$0 { model.clearMessages(); invalidLink = false } }
        )) {
            Button("common.ok") { model.clearMessages(); invalidLink = false }
        } message: { Text(invalidLink ? toolsString("external.invalid") : (model.errorMessage ?? "")) }
    }
}

private extension LauncherExternalRequest {
    var isDestructive: Bool { if case .terminate = self { return true }; return false }
}
