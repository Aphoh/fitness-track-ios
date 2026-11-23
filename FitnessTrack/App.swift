import SwiftUI

@main
struct FitnessTrackApp: App {
    @State private var store: StateStore
    @AppStorage("appearance") private var appearance = Appearance.system

    init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoData") {
            let today = LocalDate.today()
            _store = State(initialValue: StateStore(preview: DemoData.make(today: today)))
        } else {
            _store = State(initialValue: StateStore())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    var label: String { rawValue.capitalized }
}
