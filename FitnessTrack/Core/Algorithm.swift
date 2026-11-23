// Port of FitnessTrack shared/algorithm.js — dynamic double progression.
// Copyright (c) 2026 Giuliano Maciocci (original JS), MIT License.
//
//   actual_reps >= repMax              → weight bump: weight + increment, reps → repMin
//   target_reps <= actual_reps < repMax → rep progress: reps → min(repMax, actual + step)
//   repMin <= actual_reps < target_reps → hold: same weight, reps → logged reps
//   actual_reps < repMin                → ease off only on the 2nd straight sub-floor session
//   skipped / not logged                → unchanged
//
// A descending-weight clamp keeps the profile coherent: no set is prescribed
// heavier than the set before it. See the original README for the full rules.

import Foundation

public enum Tempo: String, Codable, Sendable, CaseIterable {
    case fast, normal, slow
}

public enum SetPerformance: String, Sendable {
    case up, met, down
}

public struct Target: Equatable, Sendable {
    public var weight: Double?
    public var reps: Int
    public init(weight: Double?, reps: Int) { self.weight = weight; self.reps = reps }
}

public struct LoggedPerformance: Equatable, Sendable {
    public var weightUsed: Double?
    public var repsDone: Int?
    public var skipped: Bool
    public init(weightUsed: Double?, repsDone: Int?, skipped: Bool = false) {
        self.weightUsed = weightUsed; self.repsDone = repsDone; self.skipped = skipped
    }
}

public struct SetData: Sendable {
    public var setNum: Int
    public var target: Target
    public var logged: LoggedPerformance?
    public var priorFloorMiss: Bool
    public init(setNum: Int, target: Target, logged: LoggedPerformance?, priorFloorMiss: Bool = false) {
        self.setNum = setNum; self.target = target; self.logged = logged; self.priorFloorMiss = priorFloorMiss
    }
}

public struct NextTarget: Equatable, Sendable {
    public var setNum: Int
    public var weight: Double?
    public var reps: Int
}

public struct ProgressionOptions: Sendable {
    public var repMin = 8
    public var repMax = 12
    public var increment = 2.5
    public var equipment = "barbell"
    public var pauseWeight = false
    public var weightCapKg: Double? = nil
    public var tempo: Tempo = .normal
    public init(repMin: Int = 8, repMax: Int = 12, increment: Double = 2.5, equipment: String = "barbell",
                pauseWeight: Bool = false, weightCapKg: Double? = nil, tempo: Tempo = .normal) {
        self.repMin = repMin; self.repMax = repMax; self.increment = increment; self.equipment = equipment
        self.pauseWeight = pauseWeight; self.weightCapKg = weightCapKg; self.tempo = tempo
    }
}

public enum Progression {
    public static let weightBand = 0.15

    /// JS Math.round semantics (round half up toward +∞).
    @inlinable public static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// Increment = default × tempo factor, capped at max(10% of weight, 1.25 kg).
    public static func effectiveIncrement(weight: Double, defaultIncrement: Double, factor: Double = 1) -> Double {
        min(defaultIncrement * factor, max(weight * 0.10, 1.25))
    }

    public static func roundToHalf(_ v: Double) -> Double { jsRound(v * 2) / 2 }

    public struct Adjusted: Equatable, Sendable {
        public var inBand: Bool
        public var reps: Int?
    }

    /// Weight-deviation rep re-targeting (±15% band). Units of target and actual must match.
    public static func weightAdjustedTarget(_ target: Target?, actualWeight: Double?, repMin: Int = 8, repMax: Int = 12) -> Adjusted {
        guard let target, let tw = target.weight, tw > 0, let aw = actualWeight, aw > 0 else {
            return Adjusted(inBand: true, reps: target?.reps ?? repMin)
        }
        let deviation = abs(aw - tw) / tw
        if deviation > weightBand { return Adjusted(inBand: false, reps: nil) }
        let adjusted = Int(jsRound(Double(target.reps) * tw / aw))
        return Adjusted(inBand: true, reps: max(repMin, min(repMax, adjusted)))
    }

    public static func setPerformance(targetReps: Int, actualReps: Int?) -> SetPerformance? {
        guard let a = actualReps else { return nil }
        if a > targetReps { return .up }
        if a == targetReps { return .met }
        return .down
    }

    public static func nextExerciseTargets(_ setData: [SetData], _ opts: ProgressionOptions = .init()) -> [NextTarget] {
        let repMin = opts.repMin, repMax = opts.repMax
        let equipment = opts.equipment
        let defaultIncrement = opts.increment
        let weightCap = opts.weightCapKg
        let repsOnly = equipment == "bodyweight" || opts.pauseWeight
        let repStep = opts.tempo == .fast ? 2 : 1
        let incFactor: Double = opts.tempo == .fast ? 1.5 : (opts.tempo == .slow ? 0.5 : 1)

        var overflow = 0
        var out: [NextTarget] = setData.map { s in
            let t = s.target
            guard let lg = s.logged, !lg.skipped, let actualReps = lg.repsDone else {
                return NextTarget(setNum: s.setNum, weight: t.weight, reps: t.reps)
            }

            if repsOnly {
                let weight: Double
                if equipment == "bodyweight" {
                    if let w = lg.weightUsed, w > 0 { weight = w } else { weight = t.weight ?? 0 }
                } else {
                    weight = lg.weightUsed ?? t.weight ?? 0
                }
                let effActual = actualReps + overflow
                overflow = max(0, effActual - repMax)
                let reps: Int
                if effActual >= repMax { reps = repMax }
                else if effActual >= t.reps { reps = min(repMax, effActual + repStep) }
                else { reps = max(repMin, effActual) }
                return NextTarget(setNum: s.setNum, weight: weight, reps: reps)
            }

            let baseW = lg.weightUsed ?? t.weight ?? 0
            let incr = effectiveIncrement(weight: baseW, defaultIncrement: defaultIncrement, factor: incFactor)

            if actualReps >= repMax {
                let bumped = max(roundToHalf(baseW + incr), 0.5)
                let w = weightCap.map { min(bumped, $0) } ?? bumped
                if w > baseW + 0.001 { return NextTarget(setNum: s.setNum, weight: w, reps: repMin) }
                return NextTarget(setNum: s.setNum, weight: baseW, reps: repMax)
            }
            if actualReps < repMin {
                if s.priorFloorMiss {
                    return NextTarget(setNum: s.setNum, weight: max(roundToHalf(baseW - incr), 0.5), reps: repMin)
                }
                return NextTarget(setNum: s.setNum, weight: baseW, reps: repMin)
            }
            let cmp = weightAdjustedTarget(t, actualWeight: lg.weightUsed, repMin: repMin, repMax: repMax)
            if !cmp.inBand {
                return NextTarget(setNum: s.setNum, weight: baseW, reps: min(repMax, actualReps + repStep))
            }
            if let tw = t.weight, tw > 0, baseW > 0 {
                let targetVol = tw * Double(t.reps)
                let actualVol = baseW * Double(actualReps)
                if actualVol >= targetVol - 0.01 {
                    return NextTarget(setNum: s.setNum, weight: baseW, reps: min(repMax, actualReps + repStep))
                }
                return NextTarget(setNum: s.setNum, weight: baseW, reps: max(repMin, min(repMax, actualReps)))
            }
            if actualReps >= (cmp.reps ?? repMin) {
                return NextTarget(setNum: s.setNum, weight: baseW, reps: min(repMax, actualReps + repStep))
            }
            return NextTarget(setNum: s.setNum, weight: baseW, reps: max(repMin, min(repMax, actualReps)))
        }

        if !repsOnly, out.count > 1 {
            for i in 1..<out.count {
                if let prevW = out[i - 1].weight, let curW = out[i].weight, curW > prevW + 0.001 {
                    out[i] = NextTarget(setNum: out[i].setNum, weight: prevW, reps: repMax)
                }
            }
        }
        return out
    }
}
