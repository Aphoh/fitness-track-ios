import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var picker: PickerKind?
    @State private var exportDoc: JSONDoc?
    @State private var message: String?
    @State private var error: String?
    @State private var confirmReset = false

    enum PickerKind: Identifiable { case folder, openFile, restore; var id: Self { self } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Units", selection: $unit) { Text("kg").tag(WeightUnit.kg); Text("lbs").tag(WeightUnit.lbs) }
                        .pickerStyle(.segmented)
                    Picker("Appearance", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.label).tag($0) } }
                }
                Section("Training") {
                    NavigationLink("Exercises") { ExerciseLibraryView() }
                    NavigationLink("My equipment") { EquipmentView() }
                }
                Section {
                    LabeledContent("File", value: store.fileURL.lastPathComponent)
                    LabeledContent("Location", value: locationLabel)
                    if let d = store.lastSaved { LabeledContent("Saved", value: d.formatted(date: .omitted, time: .standard)) }
                    if let e = store.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                    Button { picker = .folder } label: { Label("Move data to a folder…", systemImage: "folder") }
                    Button { picker = .openFile } label: { Label("Open existing data file…", systemImage: "doc") }
                    if !store.isUsingDefaultLocation {
                        Button { store.useDefaultLocation() } label: { Label("Use On My iPhone", systemImage: "iphone") }
                    }
                } header: { Text("Data file") } footer: {
                    Text("All data lives in one JSON file. Move it to iCloud Drive to sync it across devices and keep it backed up; changes made elsewhere are picked up automatically.")
                }
                Section("Backup") {
                    Button { exportDoc = (try? store.exportData()).map(JSONDoc.init) } label: { Label("Export backup…", systemImage: "square.and.arrow.up") }
                    Button { picker = .restore } label: { Label("Restore from backup…", systemImage: "square.and.arrow.down") }
                    Button("Reset training history", role: .destructive) { confirmReset = true }
                }
                Section {
                    Text("iOS port of FitnessTrack by Giuliano Maciocci (MIT License).")
                    Link("github.com/Gman0909/FitnessTrack", destination: URL(string: "https://github.com/Gman0909/FitnessTrack")!)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                          allowedContentTypes: picker == .folder ? [.folder] : [.json],
                          onCompletion: handlePick)
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                          contentType: .json, defaultFilename: "fitnesstrack-backup-\(store.today).json") { r in
                if case .failure(let e) = r { error = e.localizedDescription }
            }
            .confirmationDialog("Delete all logged workouts and targets? Plans and exercises are kept.", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset history", role: .destructive) { store.update { $0.resetHistory() } }
            }
            .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
            .errorAlert($error)
        }
    }

    private var locationLabel: String {
        if store.isUsingDefaultLocation { return "On My iPhone" }
        return store.isInICloud ? "iCloud Drive · \(store.fileURL.deletingLastPathComponent().lastPathComponent)" : store.fileURL.deletingLastPathComponent().lastPathComponent
    }

    private func handlePick(_ result: Result<URL, Error>) {
        let kind = picker
        picker = nil
        switch result {
        case .failure(let e): error = e.localizedDescription
        case .success(let url):
            switch kind {
            case .folder: store.saveToFolder(url)
            case .openFile: store.openExistingFile(url)
            case .restore:
                do {
                    let c = try store.restore(from: url)
                    message = "Restored \(c.plans) plans, \(c.sessions) sessions and \(c.sets) sets."
                } catch { self.error = error.localizedDescription }
            case nil: break
            }
            if let e = store.lastError { error = e }
        }
    }
}

struct JSONDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct EquipmentView: View {
    @Environment(StateStore.self) private var store
    var body: some View {
        Form {
            Section {
                ForEach(store.state.allEquipmentKinds, id: \.self) { e in
                    Toggle(e.capitalizedFirst, isOn: Binding(get: { store.state.equipment.contains(e) }, set: { on in store.update { $0.setEquipment(e, owned: on) } }))
                }
            } footer: { Text("The exercise picker shows only exercises you have equipment for.") }
        }
        .navigationTitle("My equipment")
    }
}
