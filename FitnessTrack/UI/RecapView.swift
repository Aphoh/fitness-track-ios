import SwiftUI

/// Post-workout recap: week-on-week verdict per lift.
struct RecapView: View {
    @Environment(StateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("unit") private var unit = WeightUnit.kg
    let sessionID: Int

    var body: some View {
        NavigationStack {
            List {
                if let r = store.state.recap(session: sessionID, today: store.today) {
                    Section {
                        HStack {
                            stat("\(r.counts.up)/\(r.counts.comparable)", "lifts up")
                            Divider()
                            stat(r.volumeDeltaPct.map { String(format: "%+.1f%%", $0) } ?? "—", "volume")
                            Divider()
                            stat(r.repsAdded == 0 ? "0" : String(format: "%+d", r.repsAdded), "reps")
                        }
                        .frame(maxWidth: .infinity)
                    } footer: {
                        Text(r.comparison == .baseline ? "First time on this day — this is your baseline."
                             : "Compared with week \(r.comparedWeek ?? 0).")
                    }
                    Section("Lifts") {
                        ForEach(r.lifts) { l in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(l.exercise.name).font(.subheadline.weight(.semibold))
                                        if l.pr { Pill(text: "PR", color: .yellow) }
                                    }
                                    Text(line(l)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Pill(text: l.verdict.label, color: l.verdict.color)
                                    Label(l.tempo.label, systemImage: l.tempo.symbol).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workout recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack { Text(v).font(.title2.weight(.bold).monospacedDigit()); Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }

    private func line(_ l: AppState.RecapLift) -> String {
        let now = l.exercise.isBodyweight ? "\(l.thisTopReps) reps" : "\(unit.format(l.thisTopWeight)) × \(l.thisTopReps)"
        guard let pw = l.prevTopWeight, let pr = l.prevTopReps else { return now }
        let before = l.exercise.isBodyweight ? "\(pr) reps" : "\(unit.format(pw)) × \(pr)"
        return "\(before) → \(now)"
    }
}

/// Position-based plan calendar (weeks × training days).
struct PlanCalendarView: View {
    @Environment(StateStore.self) private var store
    let planID: Int
    var onSelect: ((Int, Int) -> Void)? = nil

    var body: some View {
        let weeks = store.state.calendar(plan: planID, today: store.today)
        let days = store.state.plan(planID)?.days ?? []
        ScrollView {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 34)
                    ForEach(days, id: \.self) { d in
                        Text(LocalDate.dayShort[d]).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                ForEach(weeks) { w in
                    GridRow {
                        Text("W\(w.weekNum)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 34)
                        ForEach(w.days) { d in cell(w, d) }
                    }
                }
            }
            .padding()
            HStack(spacing: 14) {
                legend("checkmark.circle.fill", .green, "Done")
                legend("circle.dotted", .accentColor, "Current")
                legend("lock.fill", .secondary, "Locked")
            }
            .font(.caption).padding(.bottom)
        }
    }

    private func cell(_ w: AppState.CalendarWeek, _ d: AppState.CalendarDay) -> some View {
        Button { onSelect?(w.weekNum, d.dayOfWeek) } label: {
            VStack(spacing: 3) {
                Image(systemName: d.isDone ? "checkmark.circle.fill" : d.isCurrent ? "circle.dotted" : d.isLocked ? "lock.fill" : "circle")
                    .foregroundStyle(d.isDone ? Color.green : d.isCurrent ? Color.accentColor : Color.secondary)
                Text(d.date.map { LocalDate.display($0) } ?? " ").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(d.isCurrent ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil || d.isLocked)
    }

    private func legend(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(color) }.foregroundStyle(.secondary)
    }
}
