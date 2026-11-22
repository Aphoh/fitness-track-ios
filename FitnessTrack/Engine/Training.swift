// Session logging and progression — port of FitnessTrack server/routes/sessions.js,
// server/setCounts.js and the GET /today view from server/routes/schedule.js
// (MIT, (c) 2026 Giuliano Maciocci).

import Foundation

enum EngineError: LocalizedError, Equatable {
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let m), .invalid(let m): return m
        }
    }
}

/// Date-or-id ordering key for "most recent session first" (s.date DESC, s.id DESC).
private func newerFirst(_ a: WorkoutSession, _ b: WorkoutSession) -> Bool {
    let da = a.date ?? "", db = b.date ?? ""
    return da != db ? da > db : a.id > b.id
}

/// `(s.date < date OR (s.date = date AND s.id < id))` with s.date non-null.
private func isBefore(_ s: WorkoutSession, date: String, id: Int) -> Bool {
    guard let d = s.date else { return false }
    return d < date || (d == date && s.id < id)
}

extension AppState {
    // MARK: Lookups

    func exercise(_ id: Int) -> Exercise? { exercises.first { $0.id == id } }
    func plan(_ id: Int?) -> Plan? { id.flatMap { pid in plans.first { $0.id == pid } } }
    var activePlan: Plan? { plans.first { $0.isActive } }
    func session(_ id: Int) -> WorkoutSession? { sessions.first { $0.id == id } }
    func sessionIndex(_ id: Int) -> Int? { sessions.firstIndex { $0.id == id } }

    func session(plan planID: Int, week: Int, dow: Int) -> WorkoutSession? {
        sessions.first { $0.planID == planID && $0.weekNum == week && $0.sessionDow == dow }
    }

    func scheduleRows(plan planID: Int?, dow: Int) -> [ScheduleSlot] {
        guard let planID else { return [] }
        return schedule.filter { $0.planID == planID && $0.dayOfWeek == dow }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    func loggedSets(session sessionID: Int) -> [LoggedSet] { loggedSets.filter { $0.sessionID == sessionID } }

    func loggedSets(session sessionID: Int, exercise exID: Int) -> [LoggedSet] {
        loggedSets.filter { $0.sessionID == sessionID && $0.exerciseID == exID }
    }

    /// Latest target for a set valid as of `date` (any date when nil).
    func targetAsOf(exercise exID: Int, setNum: Int, plan planID: Int?, date: String?, excludingSession: Int? = nil) -> SetTarget? {
        var best: SetTarget?
        for t in setTargets where t.exerciseID == exID && t.setNum == setNum && t.planID == planID {
            if let excludingSession, t.sessionID == excludingSession { continue }
            if let date, t.validFrom > date { continue }
            if let b = best, (b.validFrom, b.id) > (t.validFrom, t.id) { continue }
            best = t
        }
        return best
    }

    // MARK: Set counts (server/setCounts.js)

    private func latestSetCount(plan planID: Int?, dow: Int, exercise exID: Int, asOf date: String?) -> SetCount? {
        var best: SetCount?
        for c in setCounts where c.planID == planID && c.dayOfWeek == dow && c.exerciseID == exID {
            if let date, c.validFrom > date { continue }
            if let b = best, (b.validFrom, b.id) > (c.validFrom, c.id) { continue }
            best = c
        }
        return best
    }

    /// Effective set count as of `date` (latest row when nil); `fallback` covers rows with no history.
    func effectiveSetCount(plan planID: Int?, dow: Int, exercise exID: Int, date: String?, fallback: Int) -> Int {
        latestSetCount(plan: planID, dow: dow, exercise: exID, asOf: date)?.setCount ?? fallback
    }

    mutating func recordSetCount(plan planID: Int?, dow: Int, exercise exID: Int, count: Int, validFrom: String) {
        setCounts.removeAll { $0.planID == planID && $0.dayOfWeek == dow && $0.exerciseID == exID && $0.validFrom == validFrom }
        setCounts.append(SetCount(id: newID(), planID: planID, dayOfWeek: dow, exerciseID: exID, setCount: count, validFrom: validFrom))
        resyncScheduleSetCount(plan: planID, dow: dow, exercise: exID)
    }

    mutating func clearSetCountAt(plan planID: Int?, dow: Int, exercise exID: Int, validFrom: String) {
        setCounts.removeAll { $0.planID == planID && $0.dayOfWeek == dow && $0.exerciseID == exID && $0.validFrom == validFrom }
        resyncScheduleSetCount(plan: planID, dow: dow, exercise: exID)
    }

    mutating func resyncScheduleSetCount(plan planID: Int?, dow: Int, exercise exID: Int) {
        guard let row = latestSetCount(plan: planID, dow: dow, exercise: exID, asOf: nil) else { return }
        for i in schedule.indices where schedule[i].planID == planID && schedule[i].dayOfWeek == dow && schedule[i].exerciseID == exID {
            schedule[i].setCount = row.setCount
        }
    }

    // MARK: History-derived progression signals

    /// Volume ratio (logged / target) for one exercise in one past session.
    func sessionVolumeRatio(session s: WorkoutSession, exercise exID: Int) -> Double? {
        let logged = loggedSets.filter {
            $0.sessionID == s.id && $0.exerciseID == exID && !$0.skipped && $0.repsDone != nil && $0.weightUsed != nil
        }
        if logged.isEmpty { return nil }
        var actual = 0.0, target = 0.0
        for l in logged {
            actual += l.weightUsed! * Double(l.repsDone!)
            if let t = targetAsOf(exercise: exID, setNum: l.setNum, plan: s.planID, date: s.date ?? ""), let w = t.weight, w > 0 {
                target += w * Double(t.reps)
            }
        }
        return target > 0 ? actual / target : nil
    }

    /// Adaptive tempo from the two most recent sessions of this exercise before
    /// (`sessDate`, `sessID`). `known` is false when there's not enough history.
    func exerciseTempoInfo(plan planID: Int?, exercise exID: Int, sessionID: Int, sessionDate: String, repsOnly: Bool) -> (tempo: Tempo, known: Bool) {
        if repsOnly { return (.normal, false) }
        let withLogs = Set(loggedSets.filter { $0.exerciseID == exID }.map(\.sessionID))
        let prior = sessions
            .filter { withLogs.contains($0.id) && $0.planID == planID && isBefore($0, date: sessionDate, id: sessionID) }
            .sorted(by: newerFirst)
            .prefix(2)
        let ratios = prior.compactMap { sessionVolumeRatio(session: $0, exercise: exID) }
        if ratios.count < 2 { return (.normal, false) }
        if ratios.allSatisfy({ $0 > 1.02 }) { return (.fast, true) }
        if ratios.allSatisfy({ $0 < 0.98 }) { return (.slow, true) }
        return (.normal, true)
    }

    /// Most recent logged reps for a set from a session strictly before this one.
    func priorSetReps(exercise exID: Int, setNum: Int, plan planID: Int?, date: String, sessionID: Int) -> Int? {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var best: (WorkoutSession, Int)?
        for l in loggedSets where l.exerciseID == exID && l.setNum == setNum && !l.skipped && l.repsDone != nil {
            guard let s = byID[l.sessionID], s.planID == planID, isBefore(s, date: date, id: sessionID) else { continue }
            if let b = best, !newerFirst(s, b.0) { continue }
            best = (s, l.repsDone!)
        }
        return best?.1
    }

    // MARK: Double-progression recompute

    /// Re-derive one exercise's next-session targets from this session's performance.
    mutating func recomputeExercise(sessionID: Int, exercise exID: Int, today: String) {
        guard let session = session(sessionID),
              let slot = scheduleRows(plan: session.planID, dow: session.sessionDow).first(where: { $0.exerciseID == exID }),
              let ex = exercise(exID) else { return }
        let planID = session.planID
        let capped = ex.pauseWeight && ex.pauseCapKg != nil
        let repsOnly = ex.isBodyweight || (ex.pauseWeight && ex.pauseCapKg == nil)
        let weightCap = capped ? ex.pauseCapKg : nil
        let repMin = ex.effRepMin, repMax = ex.effRepMax

        let sessionDate = session.date ?? today
        let nextDay = LocalDate.addDays(sessionDate, 1)
        let tempo = exerciseTempoInfo(plan: planID, exercise: exID, sessionID: session.id, sessionDate: sessionDate, repsOnly: repsOnly).tempo
        let setCount = effectiveSetCount(plan: planID, dow: session.sessionDow, exercise: exID, date: sessionDate, fallback: slot.setCount)

        var loggedBySet: [Int: LoggedSet] = [:]
        for l in loggedSets(session: session.id, exercise: exID) { loggedBySet[l.setNum] = l }

        // Expected targets BEFORE clearing (bounded by nextDay so a same-day
        // earlier session's output can inform this one), ignoring this
        // session's own earlier output so re-logging is idempotent.
        var expected: [Int: SetTarget] = [:]
        if setCount >= 1 {
            for i in 1...setCount { expected[i] = targetAsOf(exercise: exID, setNum: i, plan: planID, date: nextDay, excludingSession: session.id) }
        }

        setTargets.removeAll { $0.exerciseID == exID && $0.planID == planID && $0.validFrom == nextDay }
        clearSetCountAt(plan: planID, dow: session.sessionDow, exercise: exID, validFrom: nextDay)

        guard setCount >= 1 else { return }
        for i in 1...setCount {
            guard let l = loggedBySet[i], l.skipped || l.repsDone != nil else { return }
        }

        var setData: [SetData] = []
        for i in 1...setCount {
            let exp = expected[i]
            let prior = priorSetReps(exercise: exID, setNum: i, plan: planID, date: sessionDate, sessionID: session.id)
            let l = loggedBySet[i]!
            setData.append(SetData(
                setNum: i,
                target: exp.map { Target(weight: $0.weight, reps: $0.reps) } ?? Target(weight: nil, reps: repMin),
                logged: LoggedPerformance(weightUsed: l.weightUsed, repsDone: l.repsDone, skipped: l.skipped),
                priorFloorMiss: prior.map { $0 < repMin } ?? false))
        }

        let next = Progression.nextExerciseTargets(setData, ProgressionOptions(
            repMin: repMin, repMax: repMax, increment: ex.increment, equipment: ex.equipment,
            pauseWeight: repsOnly, weightCapKg: weightCap, tempo: tempo))
        for t in next {
            setTargets.append(SetTarget(id: newID(), planID: planID, exerciseID: exID, setNum: t.setNum,
                                        weight: t.weight, reps: t.reps, validFrom: nextDay, sessionID: session.id))
        }

        // Set-addition escape hatch when no more weight can be added.
        if (repsOnly || capped) && setCount < ex.effOptimalSets {
            let allStuck = setData.indices.allSatisfy { i in
                let lg = setData[i].logged!
                let atCeiling = lg.skipped || (lg.repsDone.map { $0 >= repMax } ?? false)
                let atCap = !capped || lg.skipped || (next[i].weight.map { $0 >= weightCap! - 0.001 } ?? false)
                return atCeiling && atCap
            }
            if allStuck {
                recordSetCount(plan: planID, dow: session.sessionDow, exercise: exID, count: setCount + 1, validFrom: nextDay)
                setTargets.append(SetTarget(id: newID(), planID: planID, exerciseID: exID, setNum: setCount + 1,
                                            weight: next.last?.weight, reps: repMin, validFrom: nextDay, sessionID: session.id))
            }
        }
    }

    func expectedSetTotal(session s: WorkoutSession, today: String) -> Int {
        let date = s.date ?? today
        return scheduleRows(plan: s.planID, dow: s.sessionDow).reduce(0) {
            $0 + effectiveSetCount(plan: s.planID, dow: s.sessionDow, exercise: $1.exerciseID, date: date, fallback: $1.setCount)
        }
    }

    func liveSetCount(session sessionID: Int) -> Int { loggedSets.filter { $0.sessionID == sessionID && $0.isLive }.count }

    /// Logged/skipped sets that count toward the day's schedule: sets of an
    /// exercise since removed from the day, or beyond its count, don't.
    func completedSetTotal(session s: WorkoutSession, today: String) -> Int {
        let date = s.date ?? today
        return scheduleRows(plan: s.planID, dow: s.sessionDow).reduce(0) { total, row in
            let count = effectiveSetCount(plan: s.planID, dow: s.sessionDow, exercise: row.exerciseID, date: date, fallback: row.setCount)
            return total + loggedSets.filter { $0.sessionID == s.id && $0.exerciseID == row.exerciseID && $0.isLive && $0.setNum <= count }.count
        }
    }

    /// Mark the session complete when the whole day's schedule is logged/skipped.
    mutating func updateCompletion(sessionID: Int, today: String) {
        guard let idx = sessionIndex(sessionID) else { return }
        let expected = expectedSetTotal(session: sessions[idx], today: today)
        if expected > 0 && completedSetTotal(session: sessions[idx], today: today) >= expected {
            sessions[idx].checkedIn = true
            sessions[idx].unlocked = false
        } else {
            sessions[idx].checkedIn = false
        }
    }

    // MARK: Slots

    /// First (week, day) in sequence that isn't done, scanning up to `maxWeek`.
    func currentSlot(plan p: Plan, maxWeek: Int? = nil) -> (week: Int, dow: Int)? {
        let days = p.days
        guard !days.isEmpty else { return nil }
        let scan = maxWeek ?? p.weekCount
        guard scan >= 1 else { return nil }
        for w in 1...scan {
            for d in days where !slotDone(session(plan: p.id, week: w, dow: d)) { return (w, d) }
        }
        return nil
    }

    struct SlotInfo: Equatable { var sessionID: Int?; var isCurrent: Bool; var isLocked: Bool }

    /// GET /sessions/slot — finds the session for (plan, week, day), creating a
    /// blank (undated) one when the slot isn't locked.
    mutating func openSlot(plan planID: Int, week: Int, dow: Int) throws -> SlotInfo {
        guard let p = plan(planID) else { throw EngineError.notFound("Plan not found") }
        let days = p.days
        guard let dayIdx = days.firstIndex(of: dow) else { throw EngineError.invalid("Day not in plan") }
        let cur = currentSlot(plan: p, maxWeek: max(p.weekCount, week) + 1)
        let reqIdx = (week - 1) * days.count + dayIdx
        let curIdx = cur.map { ($0.week - 1) * days.count + days.firstIndex(of: $0.dow)! } ?? Int.max
        let isCurrent = cur?.week == week && cur?.dow == dow
        let isLocked = reqIdx > curIdx
        var s = session(plan: planID, week: week, dow: dow)
        if s == nil && !isLocked {
            let new = WorkoutSession(id: newID(), planID: planID, date: nil, weekNum: week, sessionDow: dow)
            sessions.append(new)
            s = new
        }
        return SlotInfo(sessionID: s?.id, isCurrent: isCurrent, isLocked: isLocked)
    }

    // MARK: Set logging

    mutating func logSet(session sessionID: Int, exercise exID: Int, setNum: Int, repsDone: Int?, skipped: Bool = false,
                         weightUsed: Double?, today: String) throws {
        guard let sIdx = sessionIndex(sessionID) else { throw EngineError.notFound("Session not found") }
        let s = sessions[sIdx]
        guard scheduleRows(plan: s.planID, dow: s.sessionDow).contains(where: { $0.exerciseID == exID }) else {
            throw EngineError.invalid("Exercise is not scheduled for this session")
        }
        if let i = loggedSets.firstIndex(where: { $0.sessionID == sessionID && $0.exerciseID == exID && $0.setNum == setNum }) {
            loggedSets[i].repsDone = repsDone
            loggedSets[i].skipped = skipped
            loggedSets[i].weightUsed = weightUsed
        } else {
            loggedSets.append(LoggedSet(id: newID(), sessionID: sessionID, exerciseID: exID, setNum: setNum,
                                        repsDone: repsDone, skipped: skipped, weightUsed: weightUsed))
        }
        if s.date == nil && !s.checkedIn && !s.unlocked { sessions[sIdx].date = today }
        recomputeExercise(sessionID: sessionID, exercise: exID, today: today)
        updateCompletion(sessionID: sessionID, today: today)
    }

    mutating func unlogSet(session sessionID: Int, exercise exID: Int, setNum: Int, today: String) throws {
        guard let sIdx = sessionIndex(sessionID) else { throw EngineError.notFound("Session not found") }
        loggedSets.removeAll { $0.sessionID == sessionID && $0.exerciseID == exID && $0.setNum == setNum }
        let s = sessions[sIdx]
        if liveSetCount(session: sessionID) == 0 && !s.checkedIn && !s.unlocked { sessions[sIdx].date = nil }
        recomputeExercise(sessionID: sessionID, exercise: exID, today: today)
        updateCompletion(sessionID: sessionID, today: today)
    }

    /// Skip the whole session: every scheduled set not yet logged is marked skipped.
    mutating func skipSession(_ sessionID: Int, today: String) throws {
        guard let sIdx = sessionIndex(sessionID) else { throw EngineError.notFound("Session not found") }
        let s = sessions[sIdx]
        if let planID = s.planID {
            for slot in scheduleRows(plan: planID, dow: s.sessionDow) {
                let n = effectiveSetCount(plan: planID, dow: s.sessionDow, exercise: slot.exerciseID, date: s.date, fallback: slot.setCount)
                guard n >= 1 else { continue }
                for i in 1...n where !loggedSets.contains(where: { $0.sessionID == sessionID && $0.exerciseID == slot.exerciseID && $0.setNum == i }) {
                    loggedSets.append(LoggedSet(id: newID(), sessionID: sessionID, exerciseID: slot.exerciseID, setNum: i,
                                                repsDone: nil, skipped: true, weightUsed: nil))
                }
            }
        }
        if sessions[sIdx].date == nil { sessions[sIdx].date = today }
        sessions[sIdx].checkedIn = true
        sessions[sIdx].unlocked = false
    }

    /// Re-open a completed session: drops the next-day targets it wrote.
    mutating func unlockSession(_ sessionID: Int, today: String) throws {
        guard let sIdx = sessionIndex(sessionID) else { throw EngineError.notFound("Session not found") }
        let s = sessions[sIdx]
        let expected = expectedSetTotal(session: s, today: today)
        let isDone = s.checkedIn || (expected > 0 && completedSetTotal(session: s, today: today) >= expected)
        guard isDone else { throw EngineError.invalid("Session is not completed") }
        if let date = s.date {
            let nextDay = LocalDate.addDays(date, 1)
            for r in scheduleRows(plan: s.planID, dow: s.sessionDow) {
                setTargets.removeAll { $0.validFrom == nextDay && $0.planID == s.planID && $0.exerciseID == r.exerciseID }
                clearSetCountAt(plan: s.planID, dow: s.sessionDow, exercise: r.exerciseID, validFrom: nextDay)
            }
        }
        sessions[sIdx].checkedIn = false
        sessions[sIdx].unlocked = true
    }

    // MARK: Workout view (GET /schedule/today)

    struct CardSet: Equatable, Identifiable {
        var setNum: Int
        var weight: Double?
        var reps: Int
        var prevWeight: Double?
        var prevReps: Int?
        var logged: LoggedSet?
        var id: Int { setNum }
    }

    struct ExerciseCard: Equatable, Identifiable {
        var slot: ScheduleSlot
        var exercise: Exercise
        var sets: [CardSet]
        var id: Int { slot.id }
        var repMin: Int { exercise.effRepMin }
        var repMax: Int { exercise.effRepMax }
        var isComplete: Bool { sets.allSatisfy { $0.logged?.isLive == true } }
    }

    /// Per-set targets, previous performance and logs for one day of the active plan.
    func workoutView(plan planID: Int, dow: Int, week: Int?) -> [ExerciseCard] {
        guard let p = plan(planID), p.days.contains(dow) else { return [] }
        let viewing = week.flatMap { session(plan: planID, week: $0, dow: dow) }
        let viewingDate = viewing?.date
        let viewingID = viewing?.id
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let logs = viewing.map { loggedSets(session: $0.id) } ?? []

        func prev(exercise exID: Int, setNum: Int) -> LoggedSet? {
            var best: (WorkoutSession, LoggedSet)?
            for l in loggedSets where l.exerciseID == exID && l.setNum == setNum && !l.skipped && l.repsDone != nil && l.weightUsed != nil {
                guard let s = byID[l.sessionID], s.planID == planID, s.checkedIn else { continue }
                if let vd = viewingDate, !isBefore(s, date: vd, id: viewingID ?? 0) { continue }
                if let b = best, !newerFirst(s, b.0) { continue }
                best = (s, l)
            }
            return best?.1
        }

        return scheduleRows(plan: planID, dow: dow).compactMap { slot in
            guard let ex = exercise(slot.exerciseID) else { return nil }
            let n = effectiveSetCount(plan: planID, dow: dow, exercise: ex.id, date: viewingDate, fallback: slot.setCount)
            let sets: [CardSet] = n < 1 ? [] : (1...n).map { i in
                let t = targetAsOf(exercise: ex.id, setNum: i, plan: planID, date: viewingDate)
                let pv = t != nil ? prev(exercise: ex.id, setNum: i) : nil
                return CardSet(setNum: i,
                               weight: (t?.weight ?? 0) > 0 ? t!.weight : nil,
                               reps: t?.reps ?? ex.effRepMin,
                               prevWeight: pv?.weightUsed, prevReps: pv?.repsDone,
                               logged: logs.first { $0.exerciseID == ex.id && $0.setNum == i })
            }
            var s = slot; s.setCount = n
            return ExerciseCard(slot: s, exercise: ex, sets: sets)
        }
    }
}
