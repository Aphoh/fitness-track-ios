// Port of FitnessTrack shared/recap.js (MIT, (c) 2026 Giuliano Maciocci).
// Week-on-week per-lift verdict for the post-workout recap.

import Foundation

public enum LiftVerdict: String, Sendable, CaseIterable {
    case up, held, down, eased, new
}

public struct LiftAggregate: Sendable, Equatable {
    public var topW: Double
    public var vol: Double
    public var reps: Int
    public init(topW: Double, vol: Double, reps: Int) { self.topW = topW; self.vol = vol; self.reps = reps }
}

public struct VerdictSummary: Equatable, Sendable {
    public var up = 0, held = 0, down = 0, eased = 0, new = 0
    public var comparable: Int { up + held + down + eased }
    public var total: Int { comparable + new }
}

public enum Recap {
    public static func liftVerdict(_ this: LiftAggregate, prev: LiftAggregate?, isBodyweight: Bool = false) -> LiftVerdict {
        guard let prev else { return .new }
        if isBodyweight {
            if this.reps > prev.reps { return .up }
            if this.reps < prev.reps { return .down }
            return .held
        }
        let dW = this.topW - prev.topW
        if dW > 0.05 { return .up }
        if dW < -0.05 { return .eased }
        if this.vol > prev.vol * 1.01 { return .up }
        if this.vol < prev.vol * 0.99 { return .down }
        return .held
    }

    public static func capVerdictToTargets(_ v: LiftVerdict, missedEveryTarget: Bool) -> LiftVerdict {
        v == .up && missedEveryTarget ? .held : v
    }

    public static func floorVerdictToTargets(_ v: LiftVerdict, metEveryTarget: Bool) -> LiftVerdict {
        v == .down && metEveryTarget ? .held : v
    }

    public static func summarize(_ verdicts: [LiftVerdict]) -> VerdictSummary {
        var c = VerdictSummary()
        for v in verdicts {
            switch v {
            case .up: c.up += 1
            case .held: c.held += 1
            case .down: c.down += 1
            case .eased: c.eased += 1
            case .new: c.new += 1
            }
        }
        return c
    }
}
