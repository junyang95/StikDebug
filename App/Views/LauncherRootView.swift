import SwiftUI

struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("launcher.selectedTab") private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                PairingSetupView(model: model) { selectedTab = 1 }
            }
            .tabItem { Label("tabs.setup", systemImage: "list.number") }
            .tag(0)

            NavigationStack {
                LaunchView(model: model) { selectedTab = 0 }
            }
            .tabItem { Label("tabs.launch", systemImage: "bolt.fill") }
            .tag(1)

            NavigationStack {
                LauncherSettingsView(model: model) { selectedTab = 0 }
            }
            .tabItem { Label("tabs.settings", systemImage: "gearshape") }
            .tag(2)
        }
        .task { await model.refreshState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refreshState() }
            }
        }
        .alert("common.action_failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearMessages() } }
        )) {
            Button("common.ok") { model.clearMessages() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
