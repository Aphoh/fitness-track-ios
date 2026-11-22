// Plans, schedule, calendar, exercises and equipment — port of FitnessTrack
// server/routes/plans.js, schedule.js and exercises.js (MIT, (c) 2026 Giuliano Maciocci).

import Foundation

extension AppState {
    static let baselineDate = "1970-01-01"

    // MARK: Bootstrap

    /// Fresh state: the exercise library, the default equipment list and the sample plan.
    static func seeded(today: String) -> AppState {
        var s = AppState()
        for d in Seed.exercises {
            s.exercises.append(Exercise(id: s.newID(), name: d.name, muscleGroup: d.muscleGroup, equipment: d.equipment,
                                        defaultIncrement: d.increment, repMin: d.repMin, repMax: d.repMax))
        }
        s.equipment = Array(Set(Seed.exercises.map(\.equipment))).sorted()
        let pid = s.newID()
        s.plans.append(Plan(id: pid, name: Seed.samplePlanName, isActive: false, createdAt: today, weekCount: 4, days: Seed.samplePlanDays))
        var pos: [Int: Int] = [:]
        for slot in Seed.sampleSlots {
            guard let ex = s.exercises.first(where: { $0.name == slot.name }) else { continue }
            let p = pos[slot.day, default: 0]; pos[slot.day] = p + 1
            s.schedule.append(ScheduleSlot(id: s.newID(), planID: pid, dayOfWeek: slot.day, exerciseID: ex.id, setCount: slot.sets, position: p))
            s.recordSetCount(plan: pid, dow: slot.day, exercise: ex.id, count: slot.sets, validFrom: baselineDate)
            if let w = slot.weight {
                for i in 1...slot.sets {
                    s.setTargets.append(SetTarget(id: s.newID(), planID: pid, exerciseID: ex.id, setNum: i, weight: w, reps: slot.reps, validFrom: today))
                }
            }
        }
        return s
    }

    func exercise(named name: String) -> Exercise? { exercises.first { $0.name == name } }

    // MARK: Plans

    struct PlanSummary: Equatable { var exerciseCount: Int; var completedDays: Int; var totalDays: Int }

    func summary(of p: Plan) -> PlanSummary {
        PlanSummary(exerciseCount: schedule.filter { $0.planID == p.id }.count,
                    completedDays: sessions.filter { $0.planID == p.id && $0.weekNum <= p.weekCount && $0.checkedIn && !$0.unlocked }.count,
                    totalDays: p.days.count * p.weekCount)
    }

    /// Active first, then newest.
    var plansSorted: [Plan] {
        plans.sorted { a, b in a.isActive != b.isActive ? a.isActive : (a.createdAt, a.id) > (b.createdAt, b.id) }
    }

    @discardableResult
    mutating func createPlan(name: String, days: [Int], today: String) throws -> Int {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 100 else { throw EngineError.invalid("Name is required") }
        guard days.allSatisfy({ (0...6).contains($0) }) else { throw EngineError.invalid("Invalid days") }
        let id = newID()
        plans.append(Plan(id: id, name: n, createdAt: today, days: Array(Set(days)).sorted()))
        return id
    }

    mutating func updatePlan(_ id: Int, name: String? = nil, weekCount: Int? = nil) throws {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { throw EngineError.notFound("Plan not found") }
        if let name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, n.count <= 100 else { throw EngineError.invalid("Name is required") }
            plans[i].name = n
        }
        if let weekCount {
            guard (1...52).contains(weekCount) else { throw EngineError.invalid("Weeks must be 1–52") }
            plans[i].weekCount = weekCount
        }
    }

    mutating func setPlanDays(_ id: Int, days: [Int]) throws {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { throw EngineError.notFound("Plan not found") }
        guard days.allSatisfy({ (0...6).contains($0) }) else { throw EngineError.invalid("Invalid days") }
        plans[i].days = Array(Set(days)).sorted()
    }

    /// Deleting a plan keeps its sessions (history) but detaches them.
    mutating func deletePlan(_ id: Int) {
        setTargets.removeAll { $0.planID == id }
        for i in sessions.indices where sessions[i].planID == id { sessions[i].planID = nil }
        schedule.removeAll { $0.planID == id }
        setCounts.removeAll { $0.planID == id }
        plans.removeAll { $0.id == id }
    }

    mutating func activatePlan(_ id: Int, today: String) throws {
        guard plans.contains(where: { $0.id == id }) else { throw EngineError.notFound("Plan not found") }
        for i in plans.indices {
            plans[i].isActive = plans[i].id == id
            if plans[i].id == id && plans[i].startedAt == nil { plans[i].startedAt = today }
        }
    }

    /// Plan cycling: copy days + schedule; seed targets from a week's logged
    /// performance (`seedWeek`) or the source's current targets.
    @discardableResult
    mutating func clonePlan(_ id: Int, seedWeek: Int?, today: String) throws -> Int {
        guard let src = plan(id) else { throw EngineError.notFound("Plan not found") }
        let newPlanID = newID()
        plans.append(Plan(id: newPlanID, name: "\(src.name) (copy)", createdAt: today, weekCount: src.weekCount, days: src.days))
        let srcSlots = schedule.filter { $0.planID == src.id }
        for s in srcSlots {
            schedule.append(ScheduleSlot(id: newID(), planID: newPlanID, dayOfWeek: s.dayOfWeek, exerciseID: s.exerciseID, setCount: s.setCount, position: s.position))
            recordSetCount(plan: newPlanID, dow: s.dayOfWeek, exercise: s.exerciseID, count: s.setCount, validFrom: Self.baselineDate)
        }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var pending: [SetTarget] = []
        for slot in srcSlots where slot.setCount >= 1 {
            for setNum in 1...slot.setCount {
                var seed: (Double?, Int)?
                if let seedWeek {
                    let logged = loggedSets.filter { l in
                        guard l.exerciseID == slot.exerciseID, l.setNum == setNum, !l.skipped, l.repsDone != nil,
                              let s = byID[l.sessionID] else { return false }
                        return s.planID == src.id && s.weekNum == seedWeek
                    }.max { $0.id < $1.id }
                    if let l = logged { seed = (l.weightUsed, l.repsDone!) }
                    else if let t = targetAsOf(exercise: slot.exerciseID, setNum: setNum, plan: src.id, date: nil) { seed = (t.weight, t.reps) }
                } else if let t = targetAsOf(exercise: slot.exerciseID, setNum: setNum, plan: src.id, date: today) {
                    seed = (t.weight, t.reps)
                }
                if let seed, !pending.contains(where: { $0.exerciseID == slot.exerciseID && $0.setNum == setNum }) {
                    pending.append(SetTarget(id: newID(), planID: newPlanID, exerciseID: slot.exerciseID, setNum: setNum,
                                             weight: seed.0, reps: seed.1, validFrom: today))
                }
            }
        }
        setTargets += pending
        return newPlanID
    }

    // MARK: Schedule editing

    func slots(plan planID: Int) -> [ScheduleSlot] {
        schedule.filter { $0.planID == planID }.sorted { ($0.dayOfWeek, $0.position, $0.id) < ($1.dayOfWeek, $1.position, $1.id) }
    }

    @discardableResult
    mutating func addToSchedule(plan planID: Int, dow: Int, exercise exID: Int, setCount: Int = 3) throws -> Int {
        guard plan(planID) != nil else { throw EngineError.notFound("Plan not found") }
        guard exercise(exID) != nil else { throw EngineError.notFound("Exercise not found") }
        guard (0...6).contains(dow) else { throw EngineError.invalid("Invalid day") }
        guard (1...20).contains(setCount) else { throw EngineError.invalid("Sets must be 1–20") }
        guard !scheduleRows(plan: planID, dow: dow).contains(where: { $0.exerciseID == exID }) else {
            throw EngineError.invalid("\(exercise(exID)!.name) is already on this day")
        }
        let pos = (scheduleRows(plan: planID, dow: dow).map(\.position).max() ?? -1) + 1
        let id = newID()
        schedule.append(ScheduleSlot(id: id, planID: planID, dayOfWeek: dow, exerciseID: exID, setCount: setCount, position: pos))
        recordSetCount(plan: planID, dow: dow, exercise: exID, count: setCount, validFrom: Self.baselineDate)
        return id
    }

    /// Manual set-count change: recorded from today forward only.
    mutating func setSlotSetCount(_ slotID: Int, count: Int, today: String) throws {
        guard let s = schedule.first(where: { $0.id == slotID }) else { throw EngineError.notFound("Not found") }
        guard (1...20).contains(count) else { throw EngineError.invalid("Sets must be 1–20") }
        if let i = schedule.firstIndex(where: { $0.id == slotID }) { schedule[i].setCount = count }
        recordSetCount(plan: s.planID, dow: s.dayOfWeek, exercise: s.exerciseID, count: count, validFrom: today)
    }

    /// Reorder one day's exercises to the given slot order.
    mutating func reorderDay(plan planID: Int, dow: Int, slotIDs: [Int]) {
        for (pos, id) in slotIDs.enumerated() {
            if let i = schedule.firstIndex(where: { $0.id == id && $0.planID == planID && $0.dayOfWeek == dow }) { schedule[i].position = pos }
        }
    }

    mutating func removeFromSchedule(_ slotID: Int) {
        guard let s = schedule.first(where: { $0.id == slotID }) else { return }
        schedule.removeAll { $0.id == slotID }
        setCounts.removeAll { $0.planID == s.planID && $0.dayOfWeek == s.dayOfWeek && $0.exerciseID == s.exerciseID }
    }

    // MARK: Calendar

    struct CalendarDay: Equatable, Identifiable {
        var dayOfWeek: Int
        var date: String?
        var isCurrent: Bool
        var isLocked: Bool
        var scheduledCount: Int
        var session: WorkoutSession?
        var loggedExerciseCount: Int
        var id: Int { dayOfWeek }
        var isDone: Bool { slotDone(session) }
    }

    struct CalendarWeek: Equatable, Identifiable {
        var weekNum: Int
        var startDate: String?
        var endDate: String?
        var days: [CalendarDay]
        var id: Int { weekNum }
    }

    func calendar(plan planID: Int, today: String) -> [CalendarWeek] {
        guard let p = plan(planID), !p.days.isEmpty else { return [] }
        let days = p.days
        let planSessions = sessions.filter { $0.planID == planID }
        let cur = currentSlot(plan: p)
        let curIdx = cur.map { ($0.week - 1) * days.count + days.firstIndex(of: $0.dow)! } ?? Int.max
        var scheduled: [Int: Int] = [:]
        for d in days { scheduled[d] = Set(schedule.filter { $0.planID == planID && $0.dayOfWeek == d }.map(\.exerciseID)).count }
        guard p.weekCount >= 1 else { return [] }
        return (1...p.weekCount).map { w in
            let dated = planSessions.filter { $0.weekNum == w }.compactMap(\.date)
            let cells: [CalendarDay] = days.enumerated().map { idx, d in
                let s = planSessions.first { $0.weekNum == w && $0.sessionDow == d }
                let isCurrent = cur?.week == w && cur?.dow == d
                let logged = s.map { sess in
                    Set(loggedSets.filter { $0.sessionID == sess.id && !$0.skipped && $0.repsDone != nil && $0.weightUsed != nil }.map(\.exerciseID)).count
                } ?? 0
                return CalendarDay(dayOfWeek: d, date: s?.date ?? (isCurrent ? today : nil), isCurrent: isCurrent,
                                   isLocked: (w - 1) * days.count + idx > curIdx, scheduledCount: scheduled[d] ?? 0,
                                   session: s, loggedExerciseCount: logged)
            }
            return CalendarWeek(weekNum: w, startDate: dated.min(), endDate: dated.max(), days: cells)
        }
    }

    // MARK: Exercises & equipment

    func exercises(muscleGroup: String? = nil, ownedEquipmentOnly: Bool = false, customOnly: Bool = false) -> [Exercise] {
        exercises.filter { e in
            (muscleGroup == nil || e.muscleGroup == muscleGroup) &&
            (!ownedEquipmentOnly || equipment.contains(e.equipment)) &&
            (!customOnly || e.isCustom)
        }.sorted { ($0.muscleGroup, $0.name) < ($1.muscleGroup, $1.name) }
    }

    @discardableResult
    mutating func createCustomExercise(name: String, muscleGroup: String, equipment eq: String, increment: Double = 2.5,
                                       repMin: Int = 8, repMax: Int = 12) throws -> Int {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 80, !muscleGroup.isEmpty, !eq.isEmpty else { throw EngineError.invalid("Name, muscle group and equipment are required") }
        guard repMin >= 1, repMax > repMin, repMax <= 100 else { throw EngineError.invalid("Rep max must be greater than rep min (≥ 1)") }
        guard increment > 0, increment <= 50 else { throw EngineError.invalid("Invalid increment") }
        guard exercise(named: n) == nil else { throw EngineError.invalid("An exercise with that name already exists") }
        let id = newID()
        exercises.append(Exercise(id: id, name: n, muscleGroup: muscleGroup, equipment: eq, defaultIncrement: increment,
                                  repMin: repMin, repMax: repMax, isCustom: true))
        return id
    }

    /// Edit an exercise. Library exercises keep their identity; changes to rep
    /// range/increment land in the personal overrides (user_exercise_settings).
    mutating func updateExercise(_ id: Int, name: String? = nil, muscleGroup: String? = nil, equipment eq: String? = nil,
                                 increment: Double? = nil, repMin: Int? = nil, repMax: Int? = nil, optimalSets: Int? = nil) throws {
        guard let i = exercises.firstIndex(where: { $0.id == id }) else { throw EngineError.notFound("Exercise not found") }
        var e = exercises[i]
        if let name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw EngineError.invalid("Name is required") }
            if n != e.name {
                guard e.isCustom else { throw EngineError.invalid("Library exercises can't be renamed") }
                guard exercise(named: n) == nil else { throw EngineError.invalid("An exercise with that name already exists") }
                e.name = n
            }
        }
        if let muscleGroup, muscleGroup != e.muscleGroup {
            guard e.isCustom else { throw EngineError.invalid("Library exercises can't be re-categorised") }
            e.muscleGroup = muscleGroup
        }
        if let eq, eq != e.equipment {
            guard e.isCustom else { throw EngineError.invalid("Library exercises can't be re-categorised") }
            e.equipment = eq
        }
        let newMin = repMin ?? e.effRepMin, newMax = repMax ?? e.effRepMax
        guard newMin >= 1, newMax > newMin, newMax <= 100 else { throw EngineError.invalid("Rep max must be greater than rep min (≥ 1)") }
        if let repMin { e.repMinOverride = repMin }
        if let repMax { e.repMaxOverride = repMax }
        if let increment {
            guard increment > 0, increment <= 50 else { throw EngineError.invalid("Invalid increment") }
            e.incrementOverride = increment
        }
        if let optimalSets {
            guard (1...20).contains(optimalSets) else { throw EngineError.invalid("Sets must be 1–20") }
            e.optimalSets = optimalSets
        }
        exercises[i] = e
    }

    /// Pause weight increases. The cap is the heaviest current target in the
    /// plan; turning it on drops any already-written future targets.
    mutating func setPauseWeight(_ id: Int, paused: Bool, plan planID: Int?, today: String) {
        guard let i = exercises.firstIndex(where: { $0.id == id }) else { return }
        if paused {
            var cap: Double?
            if let planID {
                let maxSet = max(schedule.filter { $0.planID == planID && $0.exerciseID == id }.map(\.setCount).max() ?? 0, 1)
                cap = (1...maxSet).compactMap { targetAsOf(exercise: id, setNum: $0, plan: planID, date: today)?.weight }.filter { $0 > 0 }.max()
                setTargets.removeAll { $0.exerciseID == id && $0.planID == planID && $0.validFrom > today }
            }
            exercises[i].pauseWeight = true
            exercises[i].pauseCapKg = exercises[i].isBodyweight ? nil : cap
        } else {
            exercises[i].pauseWeight = false
            exercises[i].pauseCapKg = nil
        }
    }

    mutating func deleteCustomExercise(_ id: Int) throws {
        guard let e = exercise(id), e.isCustom else { throw EngineError.notFound("Not found") }
        guard !loggedSets.contains(where: { $0.exerciseID == id }) else {
            throw EngineError.invalid("This exercise has logged history, so it can't be deleted. Remove it from your plans instead.")
        }
        for s in schedule where s.exerciseID == id { removeFromSchedule(s.id) }
        setTargets.removeAll { $0.exerciseID == id }
        exercises.removeAll { $0.id == id }
    }

    mutating func setEquipment(_ name: String, owned: Bool) {
        equipment.removeAll { $0 == name }
        if owned { equipment.append(name); equipment.sort() }
    }

    var allEquipmentKinds: [String] {
        Array(Set(exercises.map(\.equipment) + equipment)).sorted()
    }

    var muscleGroups: [String] {
        let order = ["chest", "back", "shoulders", "biceps", "triceps", "legs", "core"]
        let all = Set(exercises.map(\.muscleGroup))
        return order.filter(all.contains) + all.subtracting(order).sorted()
    }

    /// POST /stats/reset — wipe training history (plans and exercises stay).
    mutating func resetHistory() {
        setTargets.removeAll()
        sessions.removeAll()
        loggedSets.removeAll()
    }
}
