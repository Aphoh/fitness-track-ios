// Port of FitnessTrack client/src/progressionHint.js (MIT, (c) 2026 Giuliano Maciocci).
// Progressive-overload hint for an in-progress exercise card.

import Foundation

public enum WeightUnit: String, Codable, Sendable, CaseIterable {
    case kg, lbs
    public static let lbsPerKg = 2.2046
    public func fromKg(_ kg: Double) -> Double { self == .lbs ? kg * Self.lbsPerKg : kg }
    public func toKg(_ v: Double) -> Double { self == .lbs ? v / Self.lbsPerKg : v }
}

public struct HintSet: Sendable {
    public var weight: Double?
    public var reps: Int
    public var prevWeight: Double?
    public var prevReps: Int?
    public init(weight: Double?, reps: Int, prevWeight: Double?, prevReps: Int?) {
        self.weight = weight; self.reps = reps; self.prevWeight = prevWeight; self.prevReps = prevReps
    }
}

public enum HintTone: String, Sendable { case success, danger, caution, muted }

public struct ProgressionHintResult: Equatable, Sendable {
    public var text: String
    public var tone: HintTone
}

public enum ProgressionHint {
    public static func compute(sets: [HintSet], repMin: Int, repMax: Int, exerciseComplete: Bool,
                               isBodyweight: Bool, unit: WeightUnit) -> ProgressionHintResult? {
        if exerciseComplete { return nil }
        let matched = isBodyweight
            ? sets.filter { $0.prevReps != nil }
            : sets.filter { $0.prevWeight != nil && $0.prevReps != nil }
        if matched.isEmpty { return nil }

        func fmtR(_ r: Int) -> String { "\(r > 0 ? "+" : "−")\(abs(r)) rep\(abs(r) != 1 ? "s" : "")" }
        func clamp(_ r: Int) -> Int { max(repMin, min(repMax, r)) }

        if isBodyweight {
            var curReps = 0, prevReps = 0
            for s in matched { curReps += clamp(s.reps); prevReps += s.prevReps ?? 0 }
            for s in sets where s.prevReps == nil { curReps += clamp(s.reps) }
            let d = curReps - prevReps
            if d == 0 { return nil }
            return ProgressionHintResult(text: "\(d > 0 ? "▲" : "▼") \(fmtR(d))", tone: d > 0 ? .success : .danger)
        }

        func toDisp(_ kg: Double?) -> Double { unit.fromKg(kg ?? 0) }
        var curVol = 0.0, prevVol = 0.0, curReps = 0, prevReps = 0
        var mainSet = matched[0]
        var maxAbs = abs(toDisp(matched[0].weight) - toDisp(matched[0].prevWeight))
        for s in matched {
            let tr = clamp(s.reps)
            curVol += toDisp(s.weight) * Double(tr)
            prevVol += toDisp(s.prevWeight) * Double(s.prevReps ?? 0)
            curReps += tr
            prevReps += s.prevReps ?? 0
            let change = abs(toDisp(s.weight) - toDisp(s.prevWeight))
            if change > maxAbs { maxAbs = change; mainSet = s }
        }
        for s in sets where !(s.prevWeight != nil && s.prevReps != nil) {
            guard let w = s.weight, w > 0 else { continue }
            let tr = clamp(s.reps)
            curVol += toDisp(w) * Double(tr)
            curReps += tr
        }
        let volDelta = curVol - prevVol
        let pct = prevVol > 0 ? volDelta / prevVol * 100 : 0
        let repsDelta = curReps - prevReps
        let wDelta = toDisp(mainSet.weight) - toDisp(mainSet.prevWeight)
        let hasW = abs(wDelta) >= 0.05
        let hasReps = repsDelta != 0
        if abs(volDelta) <= 0.01 && !hasW && !hasReps { return nil }

        func fmtW(_ w: Double) -> String {
            let a = abs(w)
            let num = a < 1 ? String(format: "%.1f", a)
                : (a.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", a) : String(format: "%.1f", a))
            return "\(w > 0 ? "+" : "−")\(num) \(unit.rawValue)"
        }
        let weightUp = hasW && wDelta > 0
        let weightDown = hasW && wDelta < 0
        let arrow = weightUp ? "▲" : weightDown ? "▼" : volDelta > 0.01 ? "▲" : volDelta < -0.01 ? "▼" : "→"
        let tone: HintTone = weightUp ? .success : weightDown ? .caution
            : volDelta > 0.01 ? .success : volDelta < -0.01 ? .danger : .muted
        var parts: [String] = []
        if !weightUp {
            let sign = volDelta > 0 ? "+" : volDelta < 0 ? "−" : ""
            parts.append("(\(sign)\(Int(abs(Progression.jsRound(pct))))%)")
        }
        if hasW { parts.append(fmtW(wDelta)) }
        if hasReps { parts.append(fmtR(repsDelta)) }
        return ProgressionHintResult(text: "\(arrow) \(parts.joined(separator: " "))", tone: tone)
    }
}
