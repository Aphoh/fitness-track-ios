import Foundation

/// Simulated training history (launch argument `-demoData`), produced by
/// driving the real engine — used for screenshots and previews.
enum DemoData {
    static func make(today: String) -> AppState {
        let weekStart = LocalDate.weekStart(today)
        let start = LocalDate.addDays(weekStart, -14)
        var s = AppState.seeded(today: start)
        guard let plan = s.plans.first else { return s }
        try? s.activatePlan(plan.id, today: start)
        s.equipment = ["barbell", "bodyweight", "cable", "dumbbell"]
        var rng: UInt64 = 42
        func noise() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return [0, 1, 1, 2, -1, 0, 1, 3][Int((rng >> 33) % 8)]
        }
        let defaults: [String: Double] = ["dumbbell": 12, "barbell": 40, "cable": 25, "machine": 35]
        outer: for w in 1...plan.weekCount {
            for d in plan.days {
                let date = LocalDate.addDays(start, (w - 1) * 7 + d)
                if date > today { break outer }
                guard let info = try? s.openSlot(plan: plan.id, week: w, dow: d), let sid = info.sessionID else { continue }
                let cards = s.workoutView(plan: plan.id, dow: d, week: w)
                for (ci, card) in cards.enumerated() {
                    if date == today && ci >= 1 { break }
                    for set in card.sets {
                        let weight = card.exercise.isBodyweight ? 0 : (set.weight ?? defaults[card.exercise.equipment] ?? 20)
                        let reps = max(card.repMin - 1, min(card.repMax + 1, set.reps + noise()))
                        try? s.logSet(session: sid, exercise: card.exercise.id, setNum: set.setNum, repsDone: reps,
                                      weightUsed: weight, today: date)
                    }
                }
            }
        }
        return s
    }
}
