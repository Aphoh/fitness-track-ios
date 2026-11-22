import SwiftUI

/// Today / logging screen: pick a (week, day) slot of the active plan, then log sets.
struct WorkoutView: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    @State private var selection: Slot?
    @State private var showCalendar = false
    @State private var recapSessionID: Int?
    @State private var error: String?

    struct Slot: Hashable { var week: Int; var dow: Int }

    var body: some View {
        NavigationStack {
            Group {
                if let plan = store.state.activePlan {
                    content(plan)
                } else {
                    ContentUnavailableView {
                        Label("No active plan", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Create or activate a plan in the Plans tab to start logging.")
                    }
                }
            }
            .navigationTitle(title)
            .errorAlert($error)
        }
    }

    private var title: String {
        guard let s = resolvedSlot else { return "Workout" }
        return LocalDate.dayLong[s.dow]
    }

    private var resolvedSlot: Slot? {
        guard let p = store.state.activePlan else { return nil }
        if let selection, p.days.contains(selection.dow) { return selection }
        if let c = store.state.currentSlot(plan: p) { return Slot(week: c.week, dow: c.dow) }
        return p.days.first.map { Slot(week: p.weekCount, dow: $0) }
    }

    @ViewBuilder
    private func content(_ plan: Plan) -> some View {
        if let slot = resolvedSlot {
            let session = store.state.session(plan: plan.id, week: slot.week, dow: slot.dow)
            let info = slotInfo(plan, slot)
            let cards = store.state.workoutView(plan: plan.id, dow: slot.dow, week: slot.week)
            List {
                Section {
                    DayStrip(plan: plan, selection: slot) { selection = $0 }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
                if info.isCurrent || slot == currentSlot(plan) {
                    DeloadBanner()
                }
                if info.isLocked {
                    Section {
                        Label("Finish the earlier sessions first — sessions are done in order.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                } else if cards.isEmpty {
                    Section {
                        Text("No exercises scheduled for this day. Add some in Plans.").foregroundStyle(.secondary)
                    }
                } else {
                    if let session, slotDone(session) {
                        Section {
                            HStack {
                                Label("Session complete", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                Spacer()
                                Button("Recap") { recapSessionID = session.id }.buttonStyle(.bordered)
                            }
                        }
                    }
                    ForEach(cards) { card in
                        ExerciseCardSection(card: card, sessionID: session?.id, locked: session.map(slotDone) ?? false,
                                            onError: { error = $0 })
                    }
                }
            }
            .listSectionSpacing(.compact)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
                }
                ToolbarItem(placement: .topBarTrailing) { sessionMenu(session) }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("\(plan.name) · Week \(slot.week) of \(plan.weekCount)")
                    if let d = session?.date { Text("· \(LocalDate.display(d))") }
                    Spacer()
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.bottom, 4)
                .background(.bar)
            }
            .task(id: slot) { ensureSession(plan, slot) }
            .onChange(of: session.map(slotDone) ?? false) { old, new in
                if !old && new, let session { recapSessionID = session.id }
            }
            .sheet(isPresented: $showCalendar) {
                NavigationStack {
                    PlanCalendarView(planID: plan.id) { w, d in
                        selection = Slot(week: w, dow: d); showCalendar = false
                    }
                    .navigationTitle("Calendar")
                    .toolbar { Button("Done") { showCalendar = false } }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { recapSessionID.map(IDBox.init) }, set: { recapSessionID = $0?.id })) { box in
                RecapView(sessionID: box.id)
            }
        } else {
            ContentUnavailableView("No training days", systemImage: "calendar.badge.exclamationmark",
                                   description: Text("Pick training days for \(plan.name) in the Plans tab."))
        }
    }

    private func currentSlot(_ plan: Plan) -> Slot? {
        store.state.currentSlot(plan: plan).map { Slot(week: $0.week, dow: $0.dow) }
    }

    private func slotInfo(_ plan: Plan, _ slot: Slot) -> AppState.SlotInfo {
        var copy = store.state
        return (try? copy.openSlot(plan: plan.id, week: slot.week, dow: slot.dow)) ?? .init(sessionID: nil, isCurrent: false, isLocked: true)
    }

    private func ensureSession(_ plan: Plan, _ slot: Slot) {
        guard store.state.session(plan: plan.id, week: slot.week, dow: slot.dow) == nil else { return }
        let info = slotInfo(plan, slot)
        guard !info.isLocked else { return }
        store.update { _ = try $0.openSlot(plan: plan.id, week: slot.week, dow: slot.dow) }
    }

    @ViewBuilder
    private func sessionMenu(_ session: WorkoutSession?) -> some View {
        Menu {
            if let session {
                if slotDone(session) {
                    Button { recapSessionID = session.id } label: { Label("Show recap", systemImage: "chart.bar") }
                    Button {
                        let t = store.today
                        error = store.update { try $0.unlockSession(session.id, today: t) }.errorMessage
                    } label: { Label("Unlock session", systemImage: "lock.open") }
                } else {
                    Button(role: .destructive) {
                        let t = store.today
                        error = store.update { try $0.skipSession(session.id, today: t) }.errorMessage
                    } label: { Label("Skip session", systemImage: "forward") }
                }
            }
            if let p = store.state.activePlan, let c = currentSlot(p) {
                Button { selection = c } label: { Label("Go to current session", systemImage: "arrow.uturn.backward") }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }
}

struct IDBox: Identifiable { let id: Int }

/// Horizontal week/day picker for the active plan.
private struct DayStrip: View {
    @Environment(StateStore.self) private var store
    let plan: Plan
    let selection: WorkoutView.Slot
    let onSelect: (WorkoutView.Slot) -> Void

    var body: some View {
        let weeks = store.state.calendar(plan: plan.id, today: store.today)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(weeks) { week in
                        ForEach(week.days) { day in
                            let slot = WorkoutView.Slot(week: week.weekNum, dow: day.dayOfWeek)
                            Button { onSelect(slot) } label: {
                                VStack(spacing: 2) {
                                    Text("W\(week.weekNum)").font(.caption2).foregroundStyle(.secondary)
                                    Text(LocalDate.dayShort[day.dayOfWeek]).font(.subheadline.weight(.semibold))
                                    Image(systemName: day.isDone ? "checkmark.circle.fill" : day.isLocked ? "lock.fill" : day.isCurrent ? "circle.dotted" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(day.isDone ? Color.green : day.isCurrent ? Color.accentColor : Color.secondary)
                                }
                                .frame(width: 52, height: 64)
                                .background(slot == selection ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(slot == selection ? Color.accentColor : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .opacity(day.isLocked ? 0.5 : 1)
                            .id(slot)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
        }
    }
}

private struct DeloadBanner: View {
    @Environment(StateStore.self) private var store
    var body: some View {
        let advice = store.state.deloadAdviceForActivePlan(today: store.today)
        if advice.suggest {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Consider a deload week").font(.subheadline.weight(.semibold))
                        Text("\(advice.slow) of \(advice.judged) lifts have fallen short two sessions running: \(advice.slowLifts.joined(separator: ", ")). Try ~10% lighter for a week.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "battery.25percent").foregroundStyle(.orange) }
            }
        }
    }
}

/// One exercise: header (name, range, hint) and its set rows.
struct ExerciseCardSection: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    let card: AppState.ExerciseCard
    let sessionID: Int?
    let locked: Bool
    let onError: (String) -> Void
    @State private var showHistory = false

    var body: some View {
        Section {
            ForEach(card.sets) { set in
                SetRow(card: card, set: set, unit: unit, enabled: sessionID != nil && !locked) { reps, weight, skipped in
                    log(set.setNum, reps: reps, weight: weight, skipped: skipped)
                } onClear: {
                    guard let sid = sessionID else { return }
                    let t = store.today
                    if let m = store.update({ try $0.unlogSet(session: sid, exercise: card.exercise.id, setNum: set.setNum, today: t) }).errorMessage { onError(m) }
                }
            }
        } header: {
            header
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack { ExerciseHistoryView(exerciseID: card.exercise.id) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Button { showHistory = true } label: {
                    Text(card.exercise.name).font(.headline).foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                if card.isComplete { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            HStack(spacing: 6) {
                Pill(text: "\(card.repMin)–\(card.repMax) reps")
                Pill(text: card.exercise.equipment.capitalizedFirst)
                if card.exercise.pauseWeight { Pill(text: "Weight paused", color: .orange) }
                if let hint, !card.isComplete {
                    Text(hint.text).font(.caption.weight(.semibold)).foregroundStyle(hint.tone.color)
                }
            }
        }
        .textCase(nil)
        .padding(.top, 6)
    }

    private var hint: ProgressionHintResult? {
        ProgressionHint.compute(
            sets: card.sets.map { HintSet(weight: $0.weight, reps: $0.reps, prevWeight: $0.prevWeight, prevReps: $0.prevReps) },
            repMin: card.repMin, repMax: card.repMax, exerciseComplete: card.isComplete,
            isBodyweight: card.exercise.isBodyweight, unit: unit)
    }

    private func log(_ setNum: Int, reps: Int?, weight: Double?, skipped: Bool) {
        guard let sid = sessionID else { return }
        let t = store.today
        let ex = card.exercise.id
        let r = store.update { try $0.logSet(session: sid, exercise: ex, setNum: setNum, repsDone: skipped ? nil : reps,
                                               skipped: skipped, weightUsed: skipped ? nil : weight, today: t) }
        if let m = r.errorMessage { onError(m) }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

/// A set: weight · reps fields pre-filled with the target, and a single tap to log.
struct SetRow: View {
    let card: AppState.ExerciseCard
    let set: AppState.CardSet
    let unit: WeightUnit
    let enabled: Bool
    let onLog: (_ reps: Int?, _ weightKg: Double?, _ skipped: Bool) -> Void
    let onClear: () -> Void

    @State private var weightText = ""
    @State private var repsText = ""
    @FocusState private var focus: Field?
    enum Field { case weight, reps }

    private var logged: LoggedSet? { self.set.logged }
    private var isBodyweight: Bool { card.exercise.isBodyweight }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(set.setNum)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
            if logged?.skipped == true {
                Text("Skipped").foregroundStyle(.secondary).italic()
                Spacer()
            } else {
                field(text: $weightText, placeholder: set.weight.map { unit.format($0, withUnit: false) } ?? (isBodyweight ? "BW" : "–"),
                      suffix: isBodyweight ? "\(unit.rawValue) BW" : unit.rawValue, keyboard: .decimalPad)
                    .focused($focus, equals: .weight)
                Text("×").foregroundStyle(.secondary)
                field(text: $repsText, placeholder: "\(adjustedTarget ?? set.reps)", suffix: "reps", keyboard: .numberPad)
                    .focused($focus, equals: .reps)
                Spacer(minLength: 0)
                feedback
            }
            logButton
        }
        .disabled(!enabled)
        .onAppear(perform: sync)
        .onChange(of: logged) { _, _ in sync() }
        .onChange(of: focus) { old, new in
            // Committing an edit on an already-logged set re-logs it.
            if old != nil && new == nil, let l = logged, !l.skipped { commit() }
        }
        .swipeActions(edge: .trailing) {
            if logged != nil {
                Button("Clear", role: .destructive, action: onClear)
            } else {
                Button("Skip") { onLog(nil, nil, true) }.tint(.orange)
            }
        }
        .contextMenu {
            Button { onLog(nil, nil, true) } label: { Label("Skip set", systemImage: "forward") }
            if logged != nil { Button(role: .destructive, action: onClear) { Label("Clear", systemImage: "xmark") } }
        }
        .toolbar {
            if focus != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
    }

    private func field(text: Binding<String>, placeholder: String, suffix: String, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 3) {
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit().weight(.medium))
                .frame(minWidth: 36, maxWidth: 64)
            Text(suffix).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Weight entered (kg), falling back to the target.
    private var weightKg: Double? {
        if let w = unit.parseToKg(weightText) { return w }
        return set.weight ?? (isBodyweight ? 0 : nil)
    }

    /// Rep target re-scaled for an off-target weight (±15% band), nil when out of band.
    private var adjustment: Progression.Adjusted {
        Progression.weightAdjustedTarget(set.weight.map { Target(weight: $0, reps: set.reps) }, actualWeight: unit.parseToKg(weightText) ?? logged?.weightUsed,
                                         repMin: card.repMin, repMax: card.repMax)
    }
    private var adjustedTarget: Int? { self.set.weight == nil || isBodyweight ? self.set.reps : adjustment.reps }

    @ViewBuilder private var feedback: some View {
        if let l = logged, let r = l.repsDone {
            if isBodyweight || set.weight == nil {
                glyph(Progression.setPerformance(targetReps: set.reps, actualReps: r))
            } else if let t = adjustment.reps, adjustment.inBand {
                glyph(Progression.setPerformance(targetReps: t, actualReps: r))
            } else {
                Text("?").font(.headline).foregroundStyle(.secondary).frame(width: 18)
            }
        } else {
            Color.clear.frame(width: 18)
        }
    }

    private func glyph(_ p: SetPerformance?) -> some View {
        Text(p?.glyph ?? "").font(.headline).foregroundStyle(p?.color ?? .secondary).frame(width: 18)
    }

    private var logButton: some View {
        Button {
            if logged != nil { onClear() } else { commit() }
        } label: {
            Image(systemName: logged == nil ? "circle" : (logged!.skipped ? "forward.circle.fill" : "checkmark.circle.fill"))
                .font(.title2)
                .foregroundStyle(logged == nil ? Color.secondary : (logged!.skipped ? Color.orange : Color.green))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(logged == nil ? "Log set \(set.setNum)" : "Clear set \(set.setNum)")
    }

    private func commit() {
        let reps = Int(repsText) ?? adjustedTarget ?? set.reps
        guard let w = weightKg else { focus = .weight; return }
        focus = nil
        onLog(reps, w, false)
    }

    private func sync() {
        if let l = logged, !l.skipped {
            weightText = l.weightUsed.map { isBodyweight && $0 == 0 ? "" : unit.format($0, withUnit: false) } ?? ""
            repsText = l.repsDone.map(String.init) ?? ""
        } else if logged == nil {
            weightText = ""; repsText = ""
        }
    }
}
