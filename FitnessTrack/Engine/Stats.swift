// Stats, exercise history, post-workout recap and deload advice — port of
// FitnessTrack server/routes/stats.js and the history/recap routes of
// server/routes/sessions.js (MIT, (c) 2026 Giuliano Maciocci).

import Foundation

extension AppState {
    /// A logged, non-skipped set with both weight and reps (the stats-eligible rows).
    private func workingSets(plan planID: Int?) -> [(LoggedSet, WorkoutSession)] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return loggedSets.compactMap { l in
            guard !l.skipped, l.repsDone != nil, l.weightUsed != nil, let s = byID[l.sessionID] else { return nil }
            if let planID, s.planID != planID { return nil }
            return (l, s)
        }
    }

    // MARK: Exercise history (GET /sessions/history)

    struct HistoryPoint: Equatable, Identifiable {
        var date: String
        var volume: Double
        var maxWeight: Double
        var e1rm: Double?
        var setsLogged: Int
        var id: String { date }
    }

    func exerciseHistory(_ exID: Int) -> [HistoryPoint] {
        var byDate: [String: [LoggedSet]] = [:]
        for (l, s) in workingSets(plan: nil) where l.exerciseID == exID {
            guard let d = s.date else { continue }
            byDate[d, default: []].append(l)
        }
        return byDate.keys.sorted().map { d in
            let rows = byDate[d]!
            return HistoryPoint(date: d,
                                volume: rows.reduce(0) { $0 + $1.weightUsed! * Double($1.repsDone!) },
                                maxWeight: rows.map { $0.weightUsed! }.max() ?? 0,
                                e1rm: rows.compactMap { E1RM.estimate(weight: $0.weightUsed, reps: $0.repsDone) }.max(),
                                setsLogged: rows.count)
        }
    }

    /// Exercises with any logged history, grouped order.
    var exercisesWithHistory: [Exercise] {
        let ids = Set(loggedSets.map(\.exerciseID))
        return exercises.filter { ids.contains($0.id) }.sorted { ($0.muscleGroup, $0.name) < ($1.muscleGroup, $1.name) }
    }

    // MARK: Deload (GET /stats/deload)

    func deloadAdviceForActivePlan(today: String) -> DeloadAdvice {
        guard let p = activePlan else { return Deload.advice([]) }
        let asOf = LocalDate.addDays(today, 1)
        var seen = Set<Int>()
        var lifts: [LiftTempo] = []
        for slot in schedule where slot.planID == p.id && !seen.contains(slot.exerciseID) {
            seen.insert(slot.exerciseID)
            guard let e = exercise(slot.exerciseID) else { continue }
            let repsOnly = e.isBodyweight || (e.pauseWeight && e.pauseCapKg == nil)
            let info = exerciseTempoInfo(plan: p.id, exercise: e.id, sessionID: 0, sessionDate: asOf, repsOnly: repsOnly)
            lifts.append(LiftTempo(name: e.name, tempo: info.tempo, known: info.known))
        }
        return Deload.advice(lifts)
    }

    // MARK: Recap (GET /sessions/:id/recap)

    struct RecapLift: Equatable, Identifiable {
        var exercise: Exercise
        var verdict: LiftVerdict
        var tempo: Tempo
        var pr: Bool
        var thisTopWeight: Double, thisTopReps: Int, thisVolume: Double
        var prevTopWeight: Double?, prevTopReps: Int?, prevVolume: Double?
        var id: Int { exercise.id }
    }

    struct WorkoutRecap: Equatable {
        enum Comparison: String { case lastWeek, earlier, baseline }
        var comparison: Comparison
        var comparedWeek: Int?
        var counts: VerdictSummary
        var volumeThis: Double
        var volumePrev: Double
        var volumeDeltaPct: Double?
        var repsAdded: Int
        var lifts: [RecapLift]
    }

    func recap(session sessionID: Int, today: String) -> WorkoutRecap? {
        guard let session = session(sessionID) else { return nil }
        let planID = session.planID, dow = session.sessionDow
        var prev = sessions.first { $0.planID == planID && $0.sessionDow == dow && $0.weekNum == session.weekNum - 1 && $0.checkedIn }
        var comparison = WorkoutRecap.Comparison.lastWeek
        if prev == nil {
            prev = sessions.filter { $0.planID == planID && $0.sessionDow == dow && $0.weekNum < session.weekNum && $0.checkedIn && $0.date != nil }
                .max { ($0.weekNum, $0.id) < ($1.weekNum, $1.id) }
            comparison = prev == nil ? .baseline : .earlier
        }

        func agg(_ sid: Int, _ exID: Int) -> (topW: Double, topReps: Int, vol: Double, reps: Int)? {
            let rows = loggedSets.filter { $0.sessionID == sid && $0.exerciseID == exID && !$0.skipped && $0.repsDone != nil }
            if rows.isEmpty { return nil }
            var vol = 0.0, reps = 0, topW = 0.0, topReps = 0
            for s in rows {
                let w = s.weightUsed ?? 0, r = s.repsDone!
                vol += w * Double(r); reps += r
                if w > topW || (w == topW && r > topReps) { topW = w; topReps = r }
            }
            return (topW, topReps, vol, reps)
        }
        func targetOutcome(_ exID: Int, _ repMin: Int, _ repMax: Int) -> (allMissed: Bool, allMet: Bool) {
            let rows = loggedSets.filter { $0.sessionID == sessionID && $0.exerciseID == exID && !$0.skipped && $0.repsDone != nil }
            if rows.isEmpty { return (false, false) }
            var allMissed = true, allMet = true
            for s in rows {
                guard let t = targetAsOf(exercise: exID, setNum: s.setNum, plan: planID, date: session.date) else { return (false, false) }
                let adj = Progression.weightAdjustedTarget(Target(weight: t.weight, reps: t.reps), actualWeight: s.weightUsed, repMin: repMin, repMax: repMax)
                guard adj.inBand, let r = adj.reps else { return (false, false) }
                if Progression.setPerformance(targetReps: r, actualReps: s.repsDone) == .down { allMet = false } else { allMissed = false }
            }
            return (allMissed, allMet)
        }

        var lifts: [RecapLift] = []
        var thisVol = 0.0, prevVol = 0.0, repsAdded = 0
        for sc in scheduleRows(plan: planID, dow: dow) {
            guard let ex = exercise(sc.exerciseID), let t = agg(sessionID, ex.id) else { continue }
            let repsOnly = ex.isBodyweight
            let p = prev.flatMap { agg($0.id, ex.id) }
            let raw = Recap.liftVerdict(LiftAggregate(topW: t.topW, vol: t.vol, reps: t.reps),
                                        prev: p.map { LiftAggregate(topW: $0.topW, vol: $0.vol, reps: $0.reps) }, isBodyweight: repsOnly)
            var verdict = raw
            if raw == .up || raw == .down {
                let o = targetOutcome(ex.id, ex.effRepMin, ex.effRepMax)
                verdict = Recap.floorVerdictToTargets(Recap.capVerdictToTargets(raw, missedEveryTarget: o.allMissed), metEveryTarget: o.allMet)
            }
            let tempo = exerciseTempoInfo(plan: planID, exercise: ex.id, sessionID: sessionID, sessionDate: session.date ?? today, repsOnly: repsOnly).tempo
            let others = loggedSets.filter { $0.exerciseID == ex.id && !$0.skipped && $0.sessionID != sessionID }
            let pr: Bool = repsOnly
                ? (others.compactMap(\.repsDone).max().map { t.topReps > $0 } ?? false)
                : (others.compactMap(\.weightUsed).max().map { t.topW > $0 } ?? false)
            thisVol += t.vol
            if let p { prevVol += p.vol; repsAdded += t.reps - p.reps }
            lifts.append(RecapLift(exercise: ex, verdict: verdict, tempo: tempo, pr: pr,
                                   thisTopWeight: t.topW, thisTopReps: t.topReps, thisVolume: t.vol.rounded(),
                                   prevTopWeight: p?.topW, prevTopReps: p?.topReps, prevVolume: p.map { $0.vol.rounded() }))
        }
        let delta = comparison != .baseline && prevVol > 0 ? Progression.jsRound((thisVol - prevVol) / prevVol * 1000) / 10 : nil
        return WorkoutRecap(comparison: comparison, comparedWeek: prev?.weekNum, counts: Recap.summarize(lifts.map(\.verdict)),
                            volumeThis: thisVol.rounded(), volumePrev: prevVol.rounded(), volumeDeltaPct: delta,
                            repsAdded: repsAdded, lifts: lifts)
    }

    // MARK: Stats overview (GET /stats)

    struct StatsOverview: Equatable {
        struct Volume: Equatable, Identifiable { var key: String; var volume: Double; var id: String { key } }
        struct MuscleProgress: Equatable, Identifiable {
            var muscleGroup: String; var firstVol: Double?; var lastVol: Double?; var trend: Int?
            var id: String { muscleGroup }
        }
        struct Best: Equatable, Identifiable {
            var exercise: Exercise; var weight: Double?; var reps: Int
            var id: Int { exercise.id }
        }
        struct Top: Equatable, Identifiable {
            var exercise: Exercise; var sessionCount: Int; var setCount: Int
            var id: Int { exercise.id }
        }
        var totalWorkouts = 0
        var totalVolume = 0.0
        var setsLogged = 0
        var firstDate: String?
        var lastDate: String?
        var avgPerWeek = 0.0
        var weeklyVolume: [Volume] = []
        var sessionVolume: [Volume] = []
        var muscleVolume: [Volume] = []
        var progressWeeks: (first: String, last: String)?
        var muscleProgress: [MuscleProgress] = []
        var personalBests: [Best] = []
        var bodyweightBests: [Best] = []
        var topExercises: [Top] = []

        static func == (a: Self, b: Self) -> Bool {
            a.totalWorkouts == b.totalWorkouts && a.totalVolume == b.totalVolume && a.weeklyVolume == b.weeklyVolume
                && a.personalBests == b.personalBests && a.muscleProgress == b.muscleProgress
        }
    }

    /// `planID` nil = all plans ("all time"), else that plan only.
    func stats(plan planID: Int?, today: String) -> StatsOverview {
        var o = StatsOverview()
        let rows = workingSets(plan: planID)
        let exByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        o.totalWorkouts = Set(rows.map(\.1.id)).count
        o.totalVolume = rows.reduce(0) { $0 + $1.0.weightUsed! * Double($1.0.repsDone!) }
        o.setsLogged = rows.count
        let dates = rows.compactMap(\.1.date)
        o.firstDate = dates.min(); o.lastDate = dates.max()

        func vol(_ l: LoggedSet) -> Double { l.weightUsed! * Double(l.repsDone!) }
        var weekly: [String: Double] = [:], perDate: [String: Double] = [:], muscle: [String: Double] = [:]
        var muscleWeek: [String: [String: Double]] = [:]
        for (l, s) in rows {
            guard let d = s.date else { continue }
            let wk = LocalDate.weekStart(d)
            weekly[wk, default: 0] += vol(l)
            perDate[d, default: 0] += vol(l)
            if let mg = exByID[l.exerciseID]?.muscleGroup {
                muscle[mg, default: 0] += vol(l)
                muscleWeek[mg, default: [:]][wk, default: 0] += vol(l)
            }
        }
        if o.totalWorkouts > 0 && !weekly.isEmpty {
            o.avgPerWeek = (Double(o.totalWorkouts) / Double(weekly.count) * 10).rounded() / 10
        }
        o.weeklyVolume = weekly.keys.sorted().map { .init(key: $0, volume: weekly[$0]!) }
        o.sessionVolume = perDate.keys.sorted().map { .init(key: $0, volume: perDate[$0]!) }
        o.muscleVolume = muscle.map { .init(key: $0.key, volume: $0.value) }.sorted { $0.volume > $1.volume }

        let cur = LocalDate.weekStart(today)
        var sessByWeek: [String: WeekSessions] = [:]
        for s in sessions where s.date != nil && (planID == nil || s.planID == planID) {
            let wk = LocalDate.weekStart(s.date!)
            var w = sessByWeek[wk] ?? WeekSessions(total: 0, done: 0)
            w.total += 1; if s.checkedIn { w.done += 1 }
            sessByWeek[wk] = w
        }
        let sel = StatsWeeks.selectProgressWeeks(weekly.keys.sorted(), cur: cur, sessByWeek: sessByWeek)
        if let f = sel.firstWeek, let l = sel.lastWeek {
            o.progressWeeks = (f, l)
            o.muscleProgress = muscleWeek.map { mg, weeks in
                let fv = weeks[f], lv = weeks[l]
                var trend: Int?
                if let fv, let lv, fv > 0, lv != 0 { trend = Int(Progression.jsRound((lv - fv) / fv * 100)) }
                return .init(muscleGroup: mg, firstVol: fv, lastVol: lv, trend: trend)
            }.sorted { ($0.lastVol ?? 0) > ($1.lastVol ?? 0) }
        }

        var bestW: [Int: (Double, Int)] = [:]
        var sessCount: [Int: Set<Int>] = [:], setCount: [Int: Int] = [:]
        for (l, s) in rows {
            sessCount[l.exerciseID, default: []].insert(s.id)
            setCount[l.exerciseID, default: 0] += 1
            guard let e = exByID[l.exerciseID], !e.isBodyweight else { continue }
            let w = l.weightUsed!, r = l.repsDone!
            if let b = bestW[l.exerciseID], (b.0, b.1) >= (w, r) { continue }
            bestW[l.exerciseID] = (w, r)
        }
        o.personalBests = bestW.compactMap { id, b in exByID[id].map { .init(exercise: $0, weight: b.0, reps: b.1) } }
            .sorted { ($0.weight ?? 0, $1.exercise.name) > ($1.weight ?? 0, $0.exercise.name) }.prefix(20).map { $0 }

        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var bestReps: [Int: Int] = [:]
        for l in loggedSets where !l.skipped && l.repsDone != nil {
            guard let e = exByID[l.exerciseID], e.isBodyweight, let s = byID[l.sessionID] else { continue }
            if let planID, s.planID != planID { continue }
            bestReps[l.exerciseID] = max(bestReps[l.exerciseID] ?? 0, l.repsDone!)
        }
        o.bodyweightBests = bestReps.compactMap { id, r in exByID[id].map { .init(exercise: $0, weight: nil, reps: r) } }
            .sorted { ($0.reps, $1.exercise.name) > ($1.reps, $0.exercise.name) }.prefix(20).map { $0 }
        o.topExercises = sessCount.compactMap { id, ss in exByID[id].map { .init(exercise: $0, sessionCount: ss.count, setCount: setCount[id] ?? 0) } }
            .sorted { ($0.sessionCount, $1.exercise.name) > ($1.sessionCount, $0.exercise.name) }.prefix(10).map { $0 }
        return o
    }
}
