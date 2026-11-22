// Port of FitnessTrack server/statsWeeks.js (MIT, (c) 2026 Giuliano Maciocci).
// Comparison-week selection for the muscle-group progression stat.

import Foundation

public struct WeekSessions: Sendable { public var total: Int; public var done: Int
    public init(total: Int, done: Int) { self.total = total; self.done = done } }

public enum StatsWeeks {
    /// weeks: ascending Monday week_start strings that have logged volume.
    public static func selectProgressWeeks(_ weeks: [String], cur: String, sessByWeek: [String: WeekSessions]) -> (firstWeek: String?, lastWeek: String?) {
        let elapsed = weeks.filter { $0 < cur }
        let lastElapsed = elapsed.last
        let curSess = sessByWeek[cur]
        let fullyTrained = curSess.map { $0.total > 0 && $0.done == $0.total } ?? false
        let lastDone = lastElapsed.flatMap { sessByWeek[$0]?.done } ?? 0
        let includeCur = weeks.contains(cur) && fullyTrained && (curSess?.done ?? 0) >= lastDone
        let completed = includeCur ? elapsed + [cur] : elapsed
        return (completed.first, completed.count > 1 ? completed.last : nil)
    }
}
