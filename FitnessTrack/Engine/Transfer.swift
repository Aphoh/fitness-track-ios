// Portable JSON export / restore — compatible with FitnessTrack's web export
// (server/dataTransfer.js, format "fitnesstrack-export" v1; MIT, (c) 2026
// Giuliano Maciocci). Rows reference exercises by name and plans by `ref`.

import Foundation

struct FTExport: Codable, Equatable {
    static let format = "fitnesstrack-export"
    static let version = 1

    struct ExerciseDef: Codable, Equatable {
        var name: String; var muscle_group: String; var equipment: String
        var default_increment: Double?; var rep_min: Int?; var rep_max: Int?; var is_custom: Int?
    }
    struct Setting: Codable, Equatable {
        var exercise: String; var rep_min: Int?; var rep_max: Int?; var default_increment: Double?
        var pause_weight: Int?; var pause_cap_kg: Double?; var optimal_sets: Int?
    }
    struct Slot: Codable, Equatable { var exercise: String; var day_of_week: Int; var set_count: Int; var position: Int? }
    struct Count: Codable, Equatable { var exercise: String; var day_of_week: Int; var set_count: Int; var valid_from: String }
    struct TargetRow: Codable, Equatable {
        var exercise: String; var set_num: Int; var weight: Double?; var reps: Int; var valid_from: String; var is_suggestion: Int?
    }
    struct PlanRow: Codable, Equatable {
        var ref: Int; var name: String; var is_active: Int?; var started_at: String?; var created_at: String?
        var week_count: Int?; var days: [Int]; var schedule: [Slot]; var set_counts: [Count]; var set_targets: [TargetRow]
    }
    struct SetRow: Codable, Equatable {
        var exercise: String; var set_num: Int; var reps_done: Int?; var skipped: Int?; var weight_used: Double?
    }
    struct SessionRow: Codable, Equatable {
        var plan_ref: Int?; var date: String?; var week_num: Int; var session_dow: Int
        var checked_in: Int?; var unlocked: Int?; var sets: [SetRow]
    }

    var format: String
    var version: Int
    var app_version: String?
    var exported_at: String?
    var exercises: [ExerciseDef]
    var exercise_settings: [Setting]
    var equipment: [String]
    var plans: [PlanRow]
    var sessions: [SessionRow]

    func validate() throws {
        guard format == Self.format else { throw EngineError.invalid("Not a FitnessTrack export file") }
        guard version == Self.version else { throw EngineError.invalid("Unsupported export version \(version)") }
        let known = Set(exercises.map(\.name)), refs = Set(plans.map(\.ref))
        func need(_ n: String) throws { if !known.contains(n) { throw EngineError.invalid("Export references unknown exercise \"\(n)\"") } }
        for p in plans {
            for r in p.schedule { try need(r.exercise) }
            for r in p.set_counts { try need(r.exercise) }
            for r in p.set_targets { try need(r.exercise) }
        }
        for s in sessions {
            if let r = s.plan_ref, !refs.contains(r) { throw EngineError.invalid("Session references an unknown plan") }
            for l in s.sets { try need(l.exercise) }
        }
        for s in exercise_settings { try need(s.exercise) }
    }
}

extension AppState {
    func exportFT(appVersion: String? = nil, now: Date = Date()) -> FTExport {
        var referenced = Set<Int>()
        func name(_ id: Int) -> String { referenced.insert(id); return exercise(id)?.name ?? "" }
        let outPlans = plans.sorted { $0.id < $1.id }.map { p in
            FTExport.PlanRow(
                ref: p.id, name: p.name, is_active: p.isActive ? 1 : 0, started_at: p.startedAt, created_at: p.createdAt,
                week_count: p.weekCount, days: p.days,
                schedule: slots(plan: p.id).map { .init(exercise: name($0.exerciseID), day_of_week: $0.dayOfWeek, set_count: $0.setCount, position: $0.position) },
                set_counts: setCounts.filter { $0.planID == p.id }.sorted { $0.id < $1.id }
                    .map { .init(exercise: name($0.exerciseID), day_of_week: $0.dayOfWeek, set_count: $0.setCount, valid_from: $0.validFrom) },
                set_targets: setTargets.filter { $0.planID == p.id }.sorted { $0.id < $1.id }
                    .map { .init(exercise: name($0.exerciseID), set_num: $0.setNum, weight: $0.weight, reps: $0.reps, valid_from: $0.validFrom, is_suggestion: 0) })
        }
        let planIDs = Set(plans.map(\.id))
        let outSessions = sessions.sorted { $0.id < $1.id }.map { s in
            FTExport.SessionRow(
                plan_ref: s.planID.flatMap { planIDs.contains($0) ? $0 : nil }, date: s.date, week_num: s.weekNum, session_dow: s.sessionDow,
                checked_in: s.checkedIn ? 1 : 0, unlocked: s.unlocked ? 1 : 0,
                sets: loggedSets(session: s.id).sorted { $0.id < $1.id }
                    .map { .init(exercise: name($0.exerciseID), set_num: $0.setNum, reps_done: $0.repsDone, skipped: $0.skipped ? 1 : 0, weight_used: $0.weightUsed) })
        }
        let settings = exercises.filter(\.hasPersonalSettings).map { e in
            FTExport.Setting(exercise: name(e.id), rep_min: e.repMinOverride, rep_max: e.repMaxOverride, default_increment: e.incrementOverride,
                             pause_weight: e.pauseWeight ? 1 : 0, pause_cap_kg: e.pauseCapKg, optimal_sets: e.optimalSets)
        }
        // Every custom exercise travels too, even if unreferenced.
        for e in exercises where e.isCustom { referenced.insert(e.id) }
        let defs = referenced.compactMap { exercise($0) }.sorted { $0.name < $1.name }.map {
            FTExport.ExerciseDef(name: $0.name, muscle_group: $0.muscleGroup, equipment: $0.equipment,
                                 default_increment: $0.defaultIncrement, rep_min: $0.repMin, rep_max: $0.repMax, is_custom: $0.isCustom ? 1 : 0)
        }
        return FTExport(format: FTExport.format, version: FTExport.version, app_version: appVersion,
                        exported_at: ISO8601DateFormatter().string(from: now), exercises: defs, exercise_settings: settings,
                        equipment: equipment.sorted(), plans: outPlans, sessions: outSessions)
    }

    var hasTrainingData: Bool { !sessions.isEmpty || !plans.isEmpty }

    struct ImportCounts: Equatable { var plans: Int; var sessions: Int; var sets: Int; var createdExercises: Int }

    /// Replace training data (plans, sessions, settings, equipment) with the export's.
    @discardableResult
    mutating func importFT(_ data: FTExport, today: String) throws -> ImportCounts {
        try data.validate()
        plans.removeAll(); schedule.removeAll(); setCounts.removeAll(); setTargets.removeAll()
        sessions.removeAll(); loggedSets.removeAll(); equipment.removeAll()
        for i in exercises.indices {
            exercises[i].incrementOverride = nil; exercises[i].repMinOverride = nil; exercises[i].repMaxOverride = nil
            exercises[i].pauseWeight = false; exercises[i].pauseCapKg = nil; exercises[i].optimalSets = nil
        }
        var exID: [String: Int] = [:]
        var created = 0
        for e in data.exercises {
            if let hit = exercise(named: e.name) { exID[e.name] = hit.id; continue }
            let id = newID()
            exercises.append(Exercise(id: id, name: e.name, muscleGroup: e.muscle_group, equipment: e.equipment,
                                      defaultIncrement: e.default_increment ?? 2.5, repMin: e.rep_min ?? 8, repMax: e.rep_max ?? 12, isCustom: true))
            exID[e.name] = id
            created += 1
        }
        var planID: [Int: Int] = [:]
        var activeSeen = false
        for p in data.plans {
            let active = (p.is_active ?? 0) == 1 && !activeSeen
            if active { activeSeen = true }
            let id = newID()
            planID[p.ref] = id
            plans.append(Plan(id: id, name: p.name, isActive: active, startedAt: p.started_at,
                              createdAt: p.created_at.map { String($0.prefix(10)) } ?? today, weekCount: p.week_count ?? 4,
                              days: Array(Set(p.days)).sorted()))
            for s in p.schedule {
                schedule.append(ScheduleSlot(id: newID(), planID: id, dayOfWeek: s.day_of_week, exerciseID: exID[s.exercise]!, setCount: s.set_count, position: s.position ?? 0))
            }
            for c in p.set_counts {
                setCounts.append(SetCount(id: newID(), planID: id, dayOfWeek: c.day_of_week, exerciseID: exID[c.exercise]!, setCount: c.set_count, validFrom: c.valid_from))
            }
            for t in p.set_targets where (t.is_suggestion ?? 0) == 0 {
                setTargets.append(SetTarget(id: newID(), planID: id, exerciseID: exID[t.exercise]!, setNum: t.set_num, weight: t.weight, reps: t.reps, validFrom: t.valid_from))
            }
        }
        var setTotal = 0
        for s in data.sessions {
            let sid = newID()
            sessions.append(WorkoutSession(id: sid, planID: s.plan_ref.flatMap { planID[$0] }, date: s.date, weekNum: s.week_num,
                                           sessionDow: s.session_dow, checkedIn: (s.checked_in ?? 0) == 1, unlocked: (s.unlocked ?? 0) == 1))
            for l in s.sets {
                loggedSets.append(LoggedSet(id: newID(), sessionID: sid, exerciseID: exID[l.exercise]!, setNum: l.set_num,
                                            repsDone: l.reps_done, skipped: (l.skipped ?? 0) == 1, weightUsed: l.weight_used))
                setTotal += 1
            }
        }
        for s in data.exercise_settings {
            guard let i = exercises.firstIndex(where: { $0.id == exID[s.exercise] }) else { continue }
            exercises[i].repMinOverride = s.rep_min; exercises[i].repMaxOverride = s.rep_max
            exercises[i].incrementOverride = s.default_increment
            exercises[i].pauseWeight = (s.pause_weight ?? 0) == 1; exercises[i].pauseCapKg = s.pause_cap_kg
            exercises[i].optimalSets = s.optimal_sets
        }
        equipment = Array(Set(data.equipment)).sorted()
        return ImportCounts(plans: data.plans.count, sessions: data.sessions.count, sets: setTotal, createdExercises: created)
    }
}
