import SwiftUI

struct PlansView: View {
    @Environment(StateStore.self) private var store
    @State private var showNew = false
    @State private var error: String?
    @State private var cloneSource: Plan?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.state.plansSorted) { p in
                    let s = store.state.summary(of: p)
                    NavigationLink(value: p.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.name).font(.headline)
                                if p.isActive { Pill(text: "Active", color: .green) }
                            }
                            Text("\(p.days.map { LocalDate.dayShort[$0] }.joined(separator: " · ")) · \(p.weekCount) weeks · \(s.exerciseCount) exercises")
                                .font(.caption).foregroundStyle(.secondary)
                            if s.totalDays > 0 {
                                ProgressView(value: Double(min(s.completedDays, s.totalDays)), total: Double(s.totalDays))
                                    .tint(p.isActive ? .green : .secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.update { $0.deletePlan(p.id) } }
                        Button("Cycle") { cloneSource = p }.tint(.indigo)
                    }
                    .swipeActions(edge: .leading) {
                        if !p.isActive {
                            Button("Activate") { let t = store.today; error = store.update { try $0.activatePlan(p.id, today: t) }.errorMessage }.tint(.green)
                        }
                    }
                }
            }
            .navigationTitle("Plans")
            .navigationDestination(for: Int.self) { PlanEditorView(planID: $0) }
            .toolbar { Button { showNew = true } label: { Label("New plan", systemImage: "plus") } }
            .sheet(isPresented: $showNew) { NewPlanSheet() }
            .sheet(item: $cloneSource) { p in CloneSheet(plan: p) }
            .errorAlert($error)
            .overlay {
                if store.state.plans.isEmpty {
                    ContentUnavailableView("No plans", systemImage: "list.bullet.rectangle", description: Text("Tap + to create a workout plan."))
                }
            }
        }
    }
}

private struct NewPlanSheet: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var days: Set<Int> = [0, 2, 4]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Plan name", text: $name)
                Section("Training days") { DayToggles(days: $days) }
            }
            .navigationTitle("New plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let t = store.today
                        let r = store.update { s -> Int in
                            let id = try s.createPlan(name: name, days: Array(days), today: t)
                            if s.activePlan == nil { try s.activatePlan(id, today: t) }
                            return id
                        }
                        if let m = r.errorMessage { error = m } else { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($error)
        }
        .presentationDetents([.medium])
    }
}

/// Plan cycling: clone a plan, seeding targets from a week's logged performance.
private struct CloneSheet: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: Plan
    @State private var seedWeek = 0
    @State private var activate = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Seed weights from", selection: $seedWeek) {
                        Text("Current targets").tag(0)
                        ForEach(1...max(plan.weekCount, 1), id: \.self) { Text("Week \($0) performance").tag($0) }
                    }
                    Toggle("Make it the active plan", isOn: $activate)
                } footer: {
                    Text("Copies days and exercises into a fresh plan so you can run another cycle, starting from where you left off.")
                }
            }
            .navigationTitle("Cycle \(plan.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let t = store.today, sw = seedWeek == 0 ? nil : seedWeek, act = activate
                        store.update { s in
                            let id = try s.clonePlan(plan.id, seedWeek: sw, today: t)
                            if act { try s.activatePlan(id, today: t) }
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct DayToggles: View {
    @Binding var days: Set<Int>
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(String(LocalDate.dayShort[d].prefix(2)))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Plan editor: name, weeks, days, per-day exercise schedule, calendar.
struct PlanEditorView: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    let planID: Int
    @State private var addingDay: IDBox?
    @State private var editingExercise: IDBox?
    @State private var error: String?

    var body: some View {
        if let plan = store.state.plan(planID) {
            List {
                Section {
                    TextField("Name", text: Binding(get: { plan.name }, set: { n in store.update { try $0.updatePlan(planID, name: n) } }))
                        .font(.headline)
                    Stepper("\(plan.weekCount) weeks", value: Binding(get: { plan.weekCount }, set: { w in store.update { try $0.updatePlan(planID, weekCount: w) } }), in: 1...52)
                    DayToggles(days: Binding(get: { Set(plan.days) }, set: { d in store.update { try $0.setPlanDays(planID, days: Array(d)) } }))
                    if !plan.isActive {
                        Button { let t = store.today; error = store.update { try $0.activatePlan(planID, today: t) }.errorMessage } label: {
                            Label("Make active", systemImage: "checkmark.circle")
                        }
                    }
                }
                ForEach(plan.days, id: \.self) { d in daySection(plan, d) }
                Section("Calendar") {
                    PlanCalendarView(planID: planID).frame(minHeight: CGFloat(plan.weekCount) * 54 + 80)
                        .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .sheet(item: $addingDay) { box in
                ExercisePicker { exID in
                    error = store.update { try $0.addToSchedule(plan: planID, dow: box.id, exercise: exID) }.errorMessage
                }
            }
            .sheet(item: $editingExercise) { box in NavigationStack { ExerciseEditor(exerciseID: box.id, planID: planID) } }
            .errorAlert($error)
        } else {
            ContentUnavailableView("Plan deleted", systemImage: "trash")
        }
    }

    private func daySection(_ plan: Plan, _ d: Int) -> some View {
        let rows = store.state.scheduleRows(plan: planID, dow: d)
        return Section {
            ForEach(rows) { slot in
                if let ex = store.state.exercise(slot.exerciseID) {
                    HStack {
                        Button { editingExercise = IDBox(id: ex.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ex.name).foregroundStyle(.primary)
                                Text("\(ex.muscleGroup.capitalizedFirst) · \(ex.effRepMin)–\(ex.effRepMax) reps · +\(unit.format(ex.increment))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Stepper("\(slot.setCount) sets", value: Binding(get: { slot.setCount }, set: { n in
                            let t = store.today
                            store.update { try $0.setSlotSetCount(slot.id, count: n, today: t) }
                        }), in: 1...20)
                        .fixedSize()
                        .font(.subheadline.monospacedDigit())
                    }
                }
            }
            .onDelete { idx in store.update { s in for i in idx { s.removeFromSchedule(rows[i].id) } } }
            .onMove { from, to in
                var ids = rows.map(\.id); ids.move(fromOffsets: from, toOffset: to)
                store.update { $0.reorderDay(plan: planID, dow: d, slotIDs: ids) }
            }
            Button { addingDay = IDBox(id: d) } label: { Label("Add exercise", systemImage: "plus") }
        } header: {
            Text(LocalDate.dayLong[d])
        }
    }
}
