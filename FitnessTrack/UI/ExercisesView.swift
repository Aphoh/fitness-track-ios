import SwiftUI

/// Searchable exercise library for adding to a plan day.
struct ExercisePicker: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onPick: (Int) -> Void
    @State private var search = ""
    @State private var group: String?
    @State private var ownedOnly = true
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                let list = store.state.exercises(muscleGroup: group, ownedEquipmentOnly: ownedOnly && !store.state.equipment.isEmpty)
                    .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                ForEach(list) { ex in
                    Button { onPick(ex.id); dismiss() } label: { ExerciseRow(exercise: ex) }.buttonStyle(.plain)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .safeAreaInset(edge: .top) { GroupFilter(group: $group).background(.bar) }
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("My equipment only", isOn: $ownedOnly)
                        Button { showNew = true } label: { Label("New custom exercise", systemImage: "plus") }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .sheet(isPresented: $showNew) { NavigationStack { NewExerciseForm { onPick($0); dismiss() } } }
        }
    }
}

struct GroupFilter: View {
    @Environment(StateStore.self) private var store
    @Binding var group: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("All", nil)
                ForEach(store.state.muscleGroups, id: \.self) { chip($0.capitalizedFirst, $0) }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }
    private func chip(_ label: String, _ value: String?) -> some View {
        Button(label) { group = value }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            .tint(group == value ? .accentColor : .secondary)
    }
}

struct ExerciseRow: View {
    @AppStorage("unit") private var unit = WeightUnit.kg
    let exercise: Exercise
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(exercise.name)
                if exercise.isCustom { Pill(text: "Custom", color: .blue) }
                if exercise.pauseWeight { Pill(text: "Paused", color: .orange) }
            }
            Text("\(exercise.muscleGroup.capitalizedFirst) · \(exercise.equipment.capitalizedFirst) · \(exercise.effRepMin)–\(exercise.effRepMax) reps · +\(unit.format(exercise.increment))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct NewExerciseForm: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("unit") private var unit = WeightUnit.kg
    var onCreate: ((Int) -> Void)? = nil
    @State private var name = ""
    @State private var group = "chest"
    @State private var equipment = "barbell"
    @State private var increment = 2.5
    @State private var repMin = 8
    @State private var repMax = 12
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Muscle group", selection: $group) { ForEach(store.state.muscleGroups, id: \.self) { Text($0.capitalizedFirst).tag($0) } }
            Picker("Equipment", selection: $equipment) { ForEach(store.state.allEquipmentKinds, id: \.self) { Text($0.capitalizedFirst).tag($0) } }
            Stepper("Rep range \(repMin)–\(repMax)", onIncrement: { repMax = min(100, repMax + 1) }, onDecrement: { repMax = max(repMin + 1, repMax - 1) })
            Stepper("Min reps \(repMin)", value: $repMin, in: 1...(repMax - 1))
            Stepper("Increment \(unit.format(increment))", value: $increment, in: 0.5...50, step: 0.5)
        }
        .navigationTitle("New exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let r = store.update { try $0.createCustomExercise(name: name, muscleGroup: group, equipment: equipment, increment: increment, repMin: repMin, repMax: repMax) }
                    switch r {
                    case .success(let id): dismiss(); onCreate?(id)
                    case .failure(let e): error = e.localizedDescription
                    }
                }
            }
        }
        .errorAlert($error)
    }
}

/// Per-exercise settings: rep range, increment, pause weight; custom exercises can be renamed/deleted.
struct ExerciseEditor: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("unit") private var unit = WeightUnit.kg
    let exerciseID: Int
    var planID: Int? = nil
    @State private var error: String?

    var body: some View {
        if let ex = store.state.exercise(exerciseID) {
            Form {
                Section {
                    if ex.isCustom {
                        TextField("Name", text: Binding(get: { ex.name }, set: { n in error = store.update { try $0.updateExercise(exerciseID, name: n) }.errorMessage }))
                        Picker("Muscle group", selection: Binding(get: { ex.muscleGroup }, set: { g in store.update { try $0.updateExercise(exerciseID, muscleGroup: g) } })) {
                            ForEach(store.state.muscleGroups, id: \.self) { Text($0.capitalizedFirst).tag($0) }
                        }
                        Picker("Equipment", selection: Binding(get: { ex.equipment }, set: { e in store.update { try $0.updateExercise(exerciseID, equipment: e) } })) {
                            ForEach(store.state.allEquipmentKinds, id: \.self) { Text($0.capitalizedFirst).tag($0) }
                        }
                    } else {
                        LabeledContent("Muscle group", value: ex.muscleGroup.capitalizedFirst)
                        LabeledContent("Equipment", value: ex.equipment.capitalizedFirst)
                    }
                }
                Section("Progression") {
                    Stepper("Min reps: \(ex.effRepMin)", value: Binding(get: { ex.effRepMin }, set: { v in error = store.update { try $0.updateExercise(exerciseID, repMin: v) }.errorMessage }), in: 1...99)
                    Stepper("Max reps: \(ex.effRepMax)", value: Binding(get: { ex.effRepMax }, set: { v in error = store.update { try $0.updateExercise(exerciseID, repMax: v) }.errorMessage }), in: 2...100)
                    Stepper("Increment: \(unit.format(ex.increment))", value: Binding(get: { ex.increment }, set: { v in store.update { try $0.updateExercise(exerciseID, increment: v) } }), in: 0.5...50, step: 0.5)
                    if ex.isBodyweight {
                        Stepper("Max sets: \(ex.effOptimalSets)", value: Binding(get: { ex.effOptimalSets }, set: { v in store.update { try $0.updateExercise(exerciseID, optimalSets: v) } }), in: 1...20)
                    }
                }
                Section {
                    Toggle("Pause weight increases", isOn: Binding(get: { ex.pauseWeight }, set: { on in
                        let t = store.today, pid = planID ?? store.state.activePlan?.id
                        store.update { $0.setPauseWeight(exerciseID, paused: on, plan: pid, today: t) }
                    }))
                    if let cap = ex.pauseCapKg { LabeledContent("Weight cap", value: unit.format(cap)) }
                } footer: {
                    Text("Keeps the current top weight as a cap; reps keep climbing and sets are added once every set is pinned at the cap and the rep ceiling.")
                }
                if ex.isCustom {
                    Section {
                        Button("Delete exercise", role: .destructive) {
                            let r = store.update { try $0.deleteCustomExercise(exerciseID) }
                            if let m = r.errorMessage { error = m } else { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(ex.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .errorAlert($error)
        }
    }
}

/// Full library management (Settings → Exercises).
struct ExerciseLibraryView: View {
    @Environment(StateStore.self) private var store
    @State private var search = ""
    @State private var group: String?
    @State private var editing: IDBox?
    @State private var showNew = false

    var body: some View {
        List {
            ForEach(store.state.exercises(muscleGroup: group).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { ex in
                Button { editing = IDBox(id: ex.id) } label: { ExerciseRow(exercise: ex) }.buttonStyle(.plain)
            }
        }
        .searchable(text: $search)
        .safeAreaInset(edge: .top) { GroupFilter(group: $group).background(.bar) }
        .navigationTitle("Exercises")
        .toolbar { Button { showNew = true } label: { Label("New", systemImage: "plus") } }
        .sheet(item: $editing) { box in NavigationStack { ExerciseEditor(exerciseID: box.id) } }
        .sheet(isPresented: $showNew) { NavigationStack { NewExerciseForm() } }
    }
}
