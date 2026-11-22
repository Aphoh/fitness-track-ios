import Charts
import SwiftUI

struct ProgressTabView: View {
    @State private var mode = 0
    var body: some View {
        NavigationStack {
            Group {
                if mode == 0 { StatsView() } else { HistoryListView() }
            }
            .safeAreaInset(edge: .top) {
                Picker("", selection: $mode) { Text("Stats").tag(0); Text("Exercises").tag(1) }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6).background(.bar)
            }
            .navigationTitle("Progress")
            .navigationDestination(for: Int.self) { ExerciseHistoryView(exerciseID: $0) }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-exercisesMode") { mode = 1 }
        }
    }
}

private struct HistoryListView: View {
    @Environment(StateStore.self) private var store
    var body: some View {
        let list = store.state.exercisesWithHistory
        List(list) { ex in
            NavigationLink(value: ex.id) {
                VStack(alignment: .leading) {
                    Text(ex.name)
                    Text("\(store.state.exerciseHistory(ex.id).count) sessions").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if list.isEmpty { ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line", description: Text("Log a workout to see progress here.")) }
        }
    }
}

struct ExerciseHistoryView: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    let exerciseID: Int
    @State private var metric = Metric.e1rm

    enum Metric: String, CaseIterable, Identifiable {
        case e1rm = "Est. 1RM", top = "Top weight", volume = "Volume"
        var id: String { rawValue }
    }

    var body: some View {
        let ex = store.state.exercise(exerciseID)
        let points = store.state.exerciseHistory(exerciseID)
        let bw = ex?.isBodyweight ?? false
        List {
            Section {
                if points.isEmpty {
                    Text("No logged sets yet.").foregroundStyle(.secondary)
                } else {
                    if !bw {
                        Picker("Metric", selection: $metric) { ForEach(Metric.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    }
                    Chart(points) { p in
                        let v = value(p, bw ? .volume : metric)
                        LineMark(x: .value("Date", LocalDate.parse(p.date) ?? .now, unit: .day), y: .value(metric.rawValue, v))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", LocalDate.parse(p.date) ?? .now, unit: .day), y: .value(metric.rawValue, v))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 220)
                }
            }
            Section("Sessions") {
                ForEach(points.reversed()) { p in
                    HStack {
                        Text(LocalDate.display(p.date, format: "EEE MMM d yyyy"))
                        Spacer()
                        VStack(alignment: .trailing) {
                            if !bw { Text("Top \(unit.format(p.maxWeight)) · e1RM \(unit.format(p.e1rm))").font(.caption) }
                            Text("\(p.setsLogged) sets · \(unit.volume(p.volume)) \(unit.rawValue) vol").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(ex?.name ?? "History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ p: AppState.HistoryPoint, _ m: Metric) -> Double {
        switch m {
        case .e1rm: unit.fromKg(p.e1rm ?? 0)
        case .top: unit.fromKg(p.maxWeight)
        case .volume: unit.fromKg(p.volume)
        }
    }
}

struct StatsView: View {
    @Environment(StateStore.self) private var store
    @AppStorage("unit") private var unit = WeightUnit.kg
    @State private var allTime = false

    var body: some View {
        let planID = allTime ? nil : store.state.activePlan?.id
        let s = store.state.stats(plan: planID, today: store.today)
        List {
            Section {
                Picker("Scope", selection: $allTime) { Text("Active plan").tag(false); Text("All time").tag(true) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    card("\(s.totalWorkouts)", "workouts")
                    card("\(unit.volume(s.totalVolume)) \(unit.rawValue)", "total volume")
                    card("\(s.setsLogged)", "sets logged")
                    card(String(format: "%.1f", s.avgPerWeek), "workouts / week")
                }
                .padding(.vertical, 4)
            }
            if !s.weeklyVolume.isEmpty {
                Section("Weekly volume") {
                    Chart(s.weeklyVolume) { w in
                        BarMark(x: .value("Week", LocalDate.parse(w.key) ?? .now, unit: .weekOfYear), y: .value("Volume", unit.fromKg(w.volume)))
                            .foregroundStyle(Color.accentColor.gradient)
                    }
                    .frame(height: 180)
                }
            }
            if !s.muscleVolume.isEmpty {
                Section("Volume by muscle") {
                    Chart(s.muscleVolume) { m in
                        BarMark(x: .value("Volume", unit.fromKg(m.volume)), y: .value("Muscle", m.key.capitalizedFirst))
                            .foregroundStyle(by: .value("Muscle", m.key))
                    }
                    .chartLegend(.hidden)
                    .frame(height: CGFloat(s.muscleVolume.count) * 28 + 20)
                }
            }
            if let w = s.progressWeeks, !s.muscleProgress.isEmpty {
                Section {
                    ForEach(s.muscleProgress) { m in
                        HStack {
                            Text(m.muscleGroup.capitalizedFirst)
                            Spacer()
                            if let t = m.trend {
                                Text("\(t > 0 ? "▲" : t < 0 ? "▼" : "=") \(abs(t))%").monospacedDigit()
                                    .foregroundStyle(t > 0 ? .green : t < 0 ? .red : .secondary)
                            } else { Text("—").foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Muscle progress") } footer: {
                    Text("Week of \(LocalDate.display(w.first)) vs week of \(LocalDate.display(w.last)).")
                }
            }
            if !s.personalBests.isEmpty {
                Section("Personal bests") {
                    ForEach(s.personalBests) { b in
                        NavigationLink(value: b.exercise.id) {
                            LabeledContent(b.exercise.name, value: "\(unit.format(b.weight)) × \(b.reps)")
                        }
                    }
                }
            }
            if !s.bodyweightBests.isEmpty {
                Section("Bodyweight bests") {
                    ForEach(s.bodyweightBests) { b in
                        NavigationLink(value: b.exercise.id) { LabeledContent(b.exercise.name, value: "\(b.reps) reps") }
                    }
                }
            }
        }
    }

    private func card(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.title3.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }
}
