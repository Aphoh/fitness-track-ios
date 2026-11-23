// Ports of FitnessTrack's server integration tests (server/test/sessions.test.js,
// deload.test.js, dataTransfer.test.js) plus set-count versioning, bodyweight
// set-adding, plan cycling and the state file, run against the in-memory engine.
import Foundation
import Testing
@testable import FitnessTrack

private let T0 = "2026-06-01"   // a Monday

private func fresh() -> AppState {
    var s = AppState.seeded(today: T0)
    s.plans.removeAll(); s.schedule.removeAll(); s.setTargets.removeAll(); s.setCounts.removeAll()
    return s
}

private func ex(_ s: AppState, _ name: String) -> Int { s.exercise(named: name)!.id }

@discardableResult
private func makePlan(_ s: inout AppState, days: [Int] = [0], _ exercises: [(String, Int, Int)]) throws -> Int {
    let pid = try s.createPlan(name: "Test plan", days: days, today: T0)
    for (name, day, sets) in exercises { try s.addToSchedule(plan: pid, dow: day, exercise: ex(s, name), setCount: sets) }
    try s.activatePlan(pid, today: T0)
    return pid
}

private func slot(_ s: inout AppState, _ pid: Int, week: Int, dow: Int) throws -> Int {
    try #require(try s.openSlot(plan: pid, week: week, dow: dow).sessionID)
}

private func logAll(_ s: inout AppState, _ sid: Int, _ exID: Int, _ sets: [(reps: Int, weight: Double)], today: String = T0) throws {
    for (i, x) in sets.enumerated() {
        try s.logSet(session: sid, exercise: exID, setNum: i + 1, repsDone: x.reps, weightUsed: x.weight, today: today)
    }
}

private func targets(_ s: AppState, _ pid: Int, _ exID: Int) -> [SetTarget] {
    s.setTargets.filter { $0.planID == pid && $0.exerciseID == exID }.sorted { $0.setNum < $1.setNum }
}

struct SessionLifecycleTests {
    @Test func coreLoopCompletesSessionAndWritesNextTargets() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 2)])
        let bench = ex(s, "Bench Press")
        let info = try s.openSlot(plan: pid, week: 1, dow: 0)
        #expect(info.isCurrent)
        let sid = try #require(info.sessionID)

        try s.logSet(session: sid, exercise: bench, setNum: 1, repsDone: 8, weightUsed: 60, today: T0)
        #expect(s.session(sid)?.checkedIn == false, "not complete after 1 of 2 sets")
        #expect(s.session(sid)?.date == T0, "date stamped on first log")

        try s.logSet(session: sid, exercise: bench, setNum: 2, repsDone: 8, weightUsed: 60, today: T0)
        #expect(s.session(sid)?.checkedIn == true)

        let next = targets(s, pid, bench)
        #expect(next.count == 2)
        // Bench range 6–8: logged 8 = repMax → weight bump, reps reset to floor.
        #expect(next[0].weight == 62.5)
        #expect(next[0].reps == 6)
        #expect(next[0].validFrom == LocalDate.addDays(T0, 1))

        let cal = s.calendar(plan: pid, today: T0)
        #expect(cal[0].days[0].isCurrent == false)
        #expect(cal[1].days[0].isCurrent == true)
    }

    @Test func unloggingReopensSessionAndRemovesNextTargets() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Squat", 0, 1)])
        let sq = ex(s, "Squat")
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, sq, [(5, 100)])
        #expect(s.session(sid)?.checkedIn == true)

        try s.unlogSet(session: sid, exercise: sq, setNum: 1, today: T0)
        #expect(s.session(sid)?.checkedIn == false)
        #expect(s.session(sid)?.date != nil, "a once-finalized session keeps its date even when emptied")
        #expect(s.setTargets.filter { $0.planID == pid }.isEmpty)
    }

    @Test func unlockingLeavesOtherSessionsTargetsIntact() throws {
        var s = fresh()
        let pid = try makePlan(&s, days: [0, 1], [("Bench Press", 0, 1), ("Barbell Curl", 1, 1)])
        let bench = ex(s, "Bench Press"), curl = ex(s, "Barbell Curl")
        let s0 = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, s0, bench, [(7, 60)])
        let s1 = try slot(&s, pid, week: 1, dow: 1)
        try logAll(&s, s1, curl, [(10, 30)])
        #expect(targets(s, pid, curl).count == 1)

        try s.unlockSession(s0, today: T0)
        #expect(targets(s, pid, bench).isEmpty, "unlocked session's own targets are removed")
        #expect(targets(s, pid, curl).count == 1, "other session's targets survive")
    }

    @Test func planSummaryAgreesWithCalendarForUnlockedSession() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Deadlift", 0, 1)])
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, ex(s, "Deadlift"), [(5, 120)])
        try s.unlockSession(sid, today: T0)
        #expect(s.calendar(plan: pid, today: T0)[0].days[0].isCurrent, "calendar: unlocked slot is current again")
        #expect(s.summary(of: s.plan(pid)!).completedDays == 0, "plan list must not count the unlocked session as done")
    }

    @Test func skipMarksWholeDayDone() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 3)])
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try s.skipSession(sid, today: T0)
        #expect(s.session(sid)?.checkedIn == true)
        #expect(s.loggedSets(session: sid).filter(\.skipped).count == 3)
    }

    @Test func recapAndHistoryForCompletedSession() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 1)])
        let bench = ex(s, "Bench Press")
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, bench, [(7, 60)])
        #expect(s.recap(session: sid, today: T0)?.lifts.count == 1)
        let hist = s.exerciseHistory(bench)
        #expect(hist.count == 1)
        #expect(hist[0].maxWeight == 60)
        #expect(hist[0].e1rm == E1RM.estimate(weight: 60, reps: 7))
        #expect(hist[0].e1rm == 74)
    }

    @Test func laterSlotsAreLockedUntilEarlierOnesAreDone() throws {
        var s = fresh()
        let pid = try makePlan(&s, days: [0, 2], [("Bench Press", 0, 1), ("Squat", 2, 1)])
        #expect(try s.openSlot(plan: pid, week: 1, dow: 2).isLocked)
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, ex(s, "Bench Press"), [(7, 60)])
        let next = try s.openSlot(plan: pid, week: 1, dow: 2)
        #expect(!next.isLocked && next.isCurrent)
    }
}

struct DeloadEngineTests {
    let lifts = ["Dumbbell Fly", "Meadows Row", "Dumbbell Row"]   // all 8–12 reps

    private func week(_ s: inout AppState, _ pid: Int, _ w: Int, _ date: String, reps: Int) throws {
        let sid = try slot(&s, pid, week: w, dow: 0)
        for name in lifts { try logAll(&s, sid, ex(s, name), [(reps, 50), (reps, 50)], today: date) }
    }

    @Test func noSuggestionWithoutHistory() throws {
        var s = fresh()
        try makePlan(&s, lifts.map { ($0, 0, 2) })
        let r = s.deloadAdviceForActivePlan(today: T0)
        #expect(!r.suggest && r.judged == 0)
    }

    @Test func twoStraightShortfallsSuggestDeload() throws {
        var s = fresh()
        let pid = try makePlan(&s, lifts.map { ($0, 0, 2) })
        let t = "2026-06-20"
        try week(&s, pid, 1, LocalDate.addDays(t, -6), reps: 10)  // targets → 50×11
        try week(&s, pid, 2, LocalDate.addDays(t, -4), reps: 9)   // short of 11 → hold at 9
        #expect(!s.deloadAdviceForActivePlan(today: t).suggest, "one shortfall is not a trend")
        try week(&s, pid, 3, LocalDate.addDays(t, -2), reps: 8)   // short of 9 again
        let r = s.deloadAdviceForActivePlan(today: t)
        #expect(r.suggest && r.slow == 3 && r.judged == 3)
        #expect(r.slowLifts.sorted() == lifts.sorted())
    }

    @Test func beatingTargetsNoSuggestion() throws {
        var s = fresh()
        let pid = try makePlan(&s, lifts.map { ($0, 0, 2) })
        let t = "2026-06-20"
        try week(&s, pid, 1, LocalDate.addDays(t, -6), reps: 9)
        try week(&s, pid, 2, LocalDate.addDays(t, -4), reps: 10)
        try week(&s, pid, 3, LocalDate.addDays(t, -2), reps: 11)
        let r = s.deloadAdviceForActivePlan(today: t)
        #expect(!r.suggest && r.judged == 3)
    }
}

struct SetCountAndProgressionTests {
    @Test func manualSetCountChangeOnlyAppliesForward() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 2)])
        let bench = ex(s, "Bench Press")
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, bench, [(7, 60), (7, 60)])
        let slotID = s.slots(plan: pid)[0].id
        try s.setSlotSetCount(slotID, count: 3, today: "2026-06-03")
        #expect(s.effectiveSetCount(plan: pid, dow: 0, exercise: bench, date: T0, fallback: 0) == 2, "completed session keeps its count")
        #expect(s.effectiveSetCount(plan: pid, dow: 0, exercise: bench, date: "2026-06-08", fallback: 0) == 3)
        #expect(s.session(sid)?.checkedIn == true)
        #expect(s.workoutView(plan: pid, dow: 0, week: 2)[0].sets.count == 3)
    }

    @Test func reloggingTheSamePerformanceKeepsTheSameTargets() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Barbell Curl", 0, 1)])
        let curl = ex(s, "Barbell Curl")
        let rows = targets(s, pid, curl)
        #expect(rows.isEmpty)
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, curl, [(10, 30)])
        let first = targets(s, pid, curl).map { [$0.weight, Double($0.reps)] }
        for _ in 0..<3 {
            try s.logSet(session: sid, exercise: curl, setNum: 1, repsDone: 10, weightUsed: 30, today: T0)
            #expect(targets(s, pid, curl).map { [$0.weight, Double($0.reps)] } == first)
        }
    }

    @Test func removedExerciseLogsDontCompleteTheDay() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 2), ("Squat", 0, 2)])
        let bench = ex(s, "Bench Press"), squat = ex(s, "Squat")
        try s.addToSchedule(plan: pid, dow: 0, exercise: ex(s, "Deadlift"), setCount: 1)
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, bench, [(7, 60), (7, 60)])
        s.removeFromSchedule(s.slots(plan: pid).first { $0.exerciseID == bench }!.id)
        try s.logSet(session: sid, exercise: squat, setNum: 1, repsDone: 8, weightUsed: 80, today: T0)
        #expect(s.session(sid)?.checkedIn == false, "Squat set 2 and Deadlift are still missing")
    }

    @Test func sameExerciseCanOnlyBeAddedOncePerDay() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 2)])
        #expect(throws: EngineError.self) { try s.addToSchedule(plan: pid, dow: 0, exercise: ex(s, "Bench Press")) }
    }

    @Test func seededSamplePlanHasBaselineSetCounts() throws {
        let s = AppState.seeded(today: T0)
        let pid = try #require(s.plans.first?.id)
        for slot in s.slots(plan: pid) {
            #expect(s.setCounts.contains { $0.planID == pid && $0.dayOfWeek == slot.dayOfWeek && $0.exerciseID == slot.exerciseID && $0.validFrom == AppState.baselineDate })
        }
    }

    @Test func bodyweightAddsASetWhenEverySetHitsCeiling() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Pull-up", 0, 2)])   // 5–12
        let pull = ex(s, "Pull-up")
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, pull, [(12, 0), (12, 0)])
        #expect(s.effectiveSetCount(plan: pid, dow: 0, exercise: pull, date: "2026-06-08", fallback: 0) == 3)
        #expect(s.effectiveSetCount(plan: pid, dow: 0, exercise: pull, date: T0, fallback: 0) == 2)
        #expect(targets(s, pid, pull).map(\.reps) == [12, 12, 5], "the added set starts at the rep floor")
    }

    @Test func pausedWeightIsCappedAndHoldsAtCeiling() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Barbell Curl", 0, 1)])
        let curl = ex(s, "Barbell Curl")
        let w1 = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, w1, curl, [(10, 30)])
        s.setPauseWeight(curl, paused: true, plan: pid, today: "2026-06-02")
        #expect(s.exercise(curl)?.pauseCapKg == 30)
        let w2 = try slot(&s, pid, week: 2, dow: 0)
        try logAll(&s, w2, curl, [(12, 30)], today: "2026-06-08")
        let t = try #require(s.targetAsOf(exercise: curl, setNum: 1, plan: pid, date: "2026-06-15"))
        #expect(t.weight == 30 && t.reps == 12, "pinned at the cap holds at repMax")
    }

    @Test func cloningSeedsTargetsFromChosenWeek() throws {
        var s = fresh()
        let pid = try makePlan(&s, [("Bench Press", 0, 2)])
        let bench = ex(s, "Bench Press")
        let sid = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, sid, bench, [(7, 80), (6, 77.5)])
        let copy = try s.clonePlan(pid, seedWeek: 1, today: "2026-06-05")
        #expect(s.slots(plan: copy).map(\.exerciseID) == [bench])
        #expect(targets(s, copy, bench).map(\.weight) == [80, 77.5])
        #expect(targets(s, copy, bench).map(\.reps) == [7, 6])
        #expect(s.plan(copy)?.days == [0])
    }
}

struct TransferTests {
    private func buildHistory(_ s: inout AppState) throws -> Int {
        let custom = try s.createCustomExercise(name: "Cable Thing", muscleGroup: "back", equipment: "cable")
        let pid = try makePlan(&s, days: [0, 3], [("Bench Press", 0, 2), ("Pull-up", 3, 2)])
        try s.addToSchedule(plan: pid, dow: 3, exercise: custom, setCount: 1)
        try s.updateExercise(ex(s, "Bench Press"), increment: 2, repMin: 5, repMax: 7)
        s.setEquipment("machine", owned: false)
        let s1 = try slot(&s, pid, week: 1, dow: 0)
        try logAll(&s, s1, ex(s, "Bench Press"), [(7, 60), (6, 60)])
        let s2 = try slot(&s, pid, week: 1, dow: 3)
        try logAll(&s, s2, ex(s, "Pull-up"), [(8, 0), (7, 0)])
        try s.logSet(session: s2, exercise: custom, setNum: 1, repsDone: nil, skipped: true, weightUsed: nil, today: T0)
        return pid
    }

    private func normalise(_ x: FTExport) -> FTExport {
        var y = x
        let refs = Dictionary(uniqueKeysWithValues: x.plans.enumerated().map { ($1.ref, $0) })
        y.plans = x.plans.map { var p = $0; p.ref = 0; return p }
        y.sessions = x.sessions.map { var s = $0; s.plan_ref = s.plan_ref.flatMap { refs[$0] }; return s }
        y.exported_at = nil
        return y
    }

    @Test func exportRestoreRoundTripsExactly() throws {
        var a = fresh()
        let pid = try buildHistory(&a)
        let exp = a.exportFT()
        #expect(exp.format == "fitnesstrack-export")
        #expect(exp.sessions.count == 2)
        #expect(exp.sessions.flatMap(\.sets).count == 5)

        // Through JSON, as a file would.
        let data = try JSONEncoder().encode(exp)
        let decoded = try JSONDecoder().decode(FTExport.self, from: data)
        var b = fresh()
        let counts = try b.importFT(decoded, today: T0)
        #expect(counts.sets == 5)
        #expect(counts.createdExercises == 1)
        #expect(normalise(b.exportFT()) == normalise(exp))
        // Progress position survives: week 1 done → week 2 current.
        let newPID = b.activePlan!.id
        #expect(b.calendar(plan: newPID, today: T0)[1].days[0].isCurrent)
        _ = pid

        // Restoring again over existing data reuses the custom exercise.
        let again = try b.importFT(decoded, today: T0)
        #expect(again.createdExercises == 0)
        #expect(normalise(b.exportFT()) == normalise(exp))
    }

    @Test func malformedExportsAreRejectedWithoutTouchingData() throws {
        var a = fresh()
        _ = try buildHistory(&a)
        let before = a
        let good = a.exportFT()
        var badFormat = good; badFormat.format = "nope"
        var badVersion = good; badVersion.version = 99
        var badRef = good; badRef.sessions[0].sets[0].exercise = "No Such Exercise"
        var badPlan = good; badPlan.sessions[0].plan_ref = 9999
        var badDay = good; badDay.plans[0].days = [7]
        var badDow = good; badDow.sessions[0].session_dow = -1
        for bad in [badFormat, badVersion, badRef, badPlan, badDay, badDow] {
            #expect(throws: EngineError.self) { try a.importFT(bad, today: T0) }
            #expect(a == before)
        }
    }

    @Test func webExportFileIsAccepted() throws {
        // Shape produced by FitnessTrack's server/dataTransfer.js.
        let json = """
        {"format":"fitnesstrack-export","version":1,"app_version":"1.0.0","exported_at":"2026-06-01T10:00:00.000Z",
         "user":{"username":"g"},
         "exercises":[{"name":"Bench Press","muscle_group":"chest","equipment":"barbell","default_increment":2.5,"rep_min":6,"rep_max":8,"is_custom":0}],
         "exercise_settings":[],"equipment":["barbell"],
         "plans":[{"ref":7,"name":"PPL","is_active":1,"started_at":"2026-06-01","created_at":"2026-06-01 09:00:00","week_count":4,"days":[0],
                   "schedule":[{"exercise":"Bench Press","day_of_week":0,"set_count":1,"position":0}],
                   "set_counts":[{"exercise":"Bench Press","day_of_week":0,"set_count":1,"valid_from":"1970-01-01"}],
                   "set_targets":[{"exercise":"Bench Press","set_num":1,"weight":62.5,"reps":6,"valid_from":"2026-06-02","is_suggestion":0}]}],
         "sessions":[{"plan_ref":7,"date":"2026-06-01","week_num":1,"session_dow":0,"checked_in":1,"unlocked":0,
                      "sets":[{"exercise":"Bench Press","set_num":1,"reps_done":8,"skipped":0,"weight_used":60}]}]}
        """
        let ft = try JSONDecoder().decode(FTExport.self, from: Data(json.utf8))
        var s = fresh()
        try s.importFT(ft, today: T0)
        let pid = try #require(s.activePlan?.id)
        #expect(s.targetAsOf(exercise: ex(s, "Bench Press"), setNum: 1, plan: pid, date: "2026-06-08")?.weight == 62.5)
        #expect(s.calendar(plan: pid, today: T0)[1].days[0].isCurrent)
    }
}

@MainActor
struct StateFileTests {
    @Test func stateFileRoundTripsAndDetectsExternalWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("state.json")
        var state = AppState.seeded(today: T0)
        _ = try state.createPlan(name: "Round trip", days: [1, 3], today: T0)

        let changed = Changed()
        let file = StateFile(url: url) { changed.fire() }
        defer { file.close() }
        #expect(try file.read() == nil)
        try file.write(try StateFile.encoder.encode(state))
        let back = try StateStore.decode(try #require(try file.read()))
        #expect(back == state)

        // Another writer (e.g. iCloud Drive delivering a change) via a coordinator.
        var other = state
        _ = try other.createPlan(name: "From another device", days: [0], today: T0)
        let data = try StateFile.encoder.encode(other)
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { try? data.write(to: $0, options: .atomic) }
        for _ in 0..<50 where !changed.value { try await Task.sleep(for: .milliseconds(100)) }
        #expect(changed.value)
        #expect(try StateStore.decode(try #require(try file.read())).plans.count == state.plans.count + 1)
    }

    @Test func webExportOpensAsStateFile() throws {
        var s = fresh()
        _ = try makePlan(&s, [("Bench Press", 0, 2)])
        let data = try StateFile.encoder.encode(s.exportFT())
        let opened = try StateStore.decode(data)
        #expect(opened.plans.map(\.name) == ["Test plan"])
    }
}

private final class Changed: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func fire() { lock.withLock { flag = true } }
}

@MainActor
struct StateStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("FitnessTrack.json")
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func unreadableFileIsNeverOverwritten() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("{\"not\": \"fitnesstrack\"}".utf8)
        try junk.write(to: url)
        let store = StateStore(fileURL: url, defaults: defaults())
        #expect(store.lastError != nil)
        let r = store.update { try $0.createPlan(name: "X", days: [0], today: T0) }
        #expect(throws: (any Error).self) { try r.get() }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test func openingAnInvalidFileKeepsTheCurrentOne() throws {
        let url = tempFile()
        let store = StateStore(fileURL: url, defaults: defaults())
        let other = url.deletingLastPathComponent().appendingPathComponent("other.json")
        let junk = Data("[1,2,3]".utf8)
        try junk.write(to: other)
        store.openExistingFile(other)
        #expect(store.fileURL == url)
        #expect(store.lastError != nil)
        _ = store.update { try $0.createPlan(name: "X", days: [0], today: T0) }
        #expect(try Data(contentsOf: other) == junk)
    }

    @Test func failedSaveReportsFailureAndKeepsState() throws {
        let url = tempFile()
        let store = StateStore(fileURL: url, defaults: defaults())
        let before = store.state
        // Replace the containing folder with a file so the write fails.
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try Data().write(to: url.deletingLastPathComponent())
        let r = store.update { try $0.createPlan(name: "X", days: [0], today: T0) }
        #expect(throws: (any Error).self) { try r.get() }
        #expect(store.state == before)
    }

    @Test func mutationAfterUnnoticedExternalEditKeepsIt() throws {
        let url = tempFile()
        let store = StateStore(fileURL: url, defaults: defaults())
        var external = store.state
        _ = try external.createPlan(name: "From another device", days: [0], today: T0)
        try StateFile.encoder.encode(external).write(to: url, options: .atomic)
        _ = try store.update { try $0.createPlan(name: "Local", days: [1], today: T0) }.get()
        let onDisk = try StateStore.decode(Data(contentsOf: url))
        #expect(Set(onDisk.plans.map(\.name)).isSuperset(of: ["From another device", "Local"]))
    }
}
