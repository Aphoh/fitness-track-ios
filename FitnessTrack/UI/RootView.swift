import SwiftUI

struct RootView: View {
    @Environment(StateStore.self) private var store
    @SceneStorage("tab") private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            WorkoutView().tabItem { Label("Workout", systemImage: "dumbbell") }.tag(0)
            PlansView().tabItem { Label("Plans", systemImage: "list.bullet.rectangle") }.tag(1)
            ProgressTabView().tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.reloadFromDisk() } }
        .onAppear {
            if let t = ProcessInfo.processInfo.arguments.firstIndex(of: "-tab").map({ ProcessInfo.processInfo.arguments[$0 + 1] }), let i = Int(t) { tab = i }
        }
    }
}
