import Foundation

// The whole app state lives in one Codable value persisted as a single JSON
// file (see StateStore). Tables mirror FitnessTrack's SQLite schema; rows
// reference each other by Int id, assigned from `nextID` like SQLite's
// autoincrement (so "higher id = created later" ordering still holds).
// `user_exercise_settings` folds into Exercise because the app is single-user.

struct Exercise: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var muscleGroup: String
    var equipment: String
    var defaultIncrement: Double = 2.5
    var repMin: Int = 8
    var repMax: Int = 12
    var isCustom: Bool = false
    // Personal overrides (user_exercise_settings)
    var incrementOverride: Double? = nil
    var repMinOverride: Int? = nil
    var repMaxOverride: Int? = nil
    var pauseWeight: Bool = false
    var pauseCapKg: Double? = nil
    var optimalSets: Int? = nil

    var increment: Double { incrementOverride ?? defaultIncrement }
    var effRepMin: Int { repMinOverride ?? repMin }
    var effRepMax: Int { repMaxOverride ?? repMax }
    var effOptimalSets: Int { optimalSets ?? 6 }
    var isBodyweight: Bool { equipment == "bodyweight" }
    var hasPersonalSettings: Bool {
        incrementOverride != nil || repMinOverride != nil || repMaxOverride != nil || pauseWeight || optimalSets != nil
    }
}

struct Plan: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var isActive: Bool = false
    var startedAt: String? = nil
    var createdAt: String
    var weekCount: Int = 4
    /// 0 = Monday … 6 = Sunday, ascending, unique.
    var days: [Int] = []
}

struct ScheduleSlot: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var planID: Int
    var dayOfWeek: Int
    var exerciseID: Int
    /// Live mirror of the latest SetCount row.
    var setCount: Int
    var position: Int
}

/// Date-versioned, append-only set count per (plan, day, exercise).
struct SetCount: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var planID: Int?
    var dayOfWeek: Int
    var exerciseID: Int
    var setCount: Int
    var validFrom: String
}

/// Append-only per-set target written by the progression algorithm.
struct SetTarget: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var planID: Int?
    var exerciseID: Int
    var setNum: Int
    var weight: Double?
    var reps: Int
    var validFrom: String
    /// The session whose performance produced this target (nil for seeds, edits, imports).
    var sessionID: Int? = nil
}

/// A workout session — identified by position (plan, week, day), not date.
struct WorkoutSession: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var planID: Int?
    var date: String?
    var weekNum: Int
    var sessionDow: Int
    var checkedIn: Bool = false
    var unlocked: Bool = false
}

struct LoggedSet: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var sessionID: Int
    var exerciseID: Int
    var setNum: Int
    var repsDone: Int?
    var skipped: Bool = false
    var weightUsed: Double?

    /// Logged or skipped — counts toward completion.
    var isLive: Bool { skipped || repsDone != nil }
}

/// shared/slotDone.js — `s && !s.unlocked && s.checked_in === 1`.
func slotDone(_ s: WorkoutSession?) -> Bool {
    guard let s else { return false }
    return !s.unlocked && s.checkedIn
}

struct AppState: Codable, Sendable, Equatable {
    static let format = "fitnesstrack-ios-state"
    static let currentVersion = 1

    var format = AppState.format
    var version = AppState.currentVersion
    var nextID = 1
    var exercises: [Exercise] = []
    var equipment: [String] = []
    var plans: [Plan] = []
    var schedule: [ScheduleSlot] = []
    var setCounts: [SetCount] = []
    var setTargets: [SetTarget] = []
    var sessions: [WorkoutSession] = []
    var loggedSets: [LoggedSet] = []

    mutating func newID() -> Int { defer { nextID += 1 }; return nextID }
}
