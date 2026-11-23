// Differential tests: every call the upstream FitnessTrack unit tests make to
// the pure progression functions, plus a seeded fuzz corpus, recorded from the
// original JavaScript (tools/record-fixtures.mjs) and replayed against the port.
import Foundation
import Testing
@testable import FitnessTrack

private final class BundleToken {}

typealias JSON = [String: Any]

func fixture(_ name: String) throws -> [(args: [Any], result: Any)] {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"), "missing fixture \(name)")
    let arr = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [JSON])
    return arr.map { ($0["args"] as? [Any] ?? [], $0["result"] as Any) }
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue) }
private func int(_ v: Any?) -> Int? { (v as? NSNumber).map(\.intValue) }
private func truthy(_ v: Any?) -> Bool {
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.doubleValue != 0 }
    return false
}

private func options(_ v: Any?) -> ProgressionOptions {
    let o = v as? JSON ?? [:]
    return ProgressionOptions(repMin: int(o["repMin"]) ?? 8, repMax: int(o["repMax"]) ?? 12, increment: num(o["increment"]) ?? 2.5,
                              equipment: o["equipment"] as? String ?? "barbell", pauseWeight: truthy(o["pauseWeight"]),
                              weightCapKg: num(o["weightCapKg"]), tempo: Tempo(rawValue: o["tempo"] as? String ?? "normal") ?? .normal)
}

private func target(_ v: Any?) -> Target? {
    guard let t = v as? JSON else { return nil }
    return Target(weight: num(t["weight"]), reps: int(t["reps"]) ?? 0)
}

struct AlgorithmFixtureTests {
    @Test func nextExerciseTargetsMatchesJS() throws {
        let calls = try fixture("nextExerciseTargets")
        #expect(calls.count > 1000)
        for (i, c) in calls.enumerated() {
            let sets = (c.args[0] as? [JSON] ?? []).map { s -> SetData in
                let lg = s["logged"] as? JSON
                return SetData(setNum: int(s["set_num"]) ?? 0, target: target(s["target"]) ?? Target(weight: nil, reps: 0),
                               logged: lg.map { LoggedPerformance(weightUsed: num($0["weight_used"]), repsDone: int($0["reps_done"]), skipped: truthy($0["skipped"])) },
                               priorFloorMiss: truthy(s["priorFloorMiss"]))
            }
            let got = Progression.nextExerciseTargets(sets, options(c.args.count > 1 ? c.args[1] : nil))
            let want = (c.result as? [JSON] ?? []).map { NextTarget(setNum: int($0["set_num"]) ?? 0, weight: num($0["weight"]), reps: int($0["reps"]) ?? 0) }
            #expect(got == want, "call #\(i): \(c.args)")
            if got != want { return }
        }
    }

    @Test func weightAdjustedTargetMatchesJS() throws {
        for (i, c) in try fixture("weightAdjustedTarget").enumerated() {
            let o = c.args.count > 2 ? c.args[2] as? JSON ?? [:] : [:]
            let got = Progression.weightAdjustedTarget(target(c.args[0]), actualWeight: num(c.args.count > 1 ? c.args[1] : nil),
                                                       repMin: int(o["repMin"]) ?? 8, repMax: int(o["repMax"]) ?? 12)
            let r = c.result as? JSON ?? [:]
            #expect(got == .init(inBand: truthy(r["inBand"]), reps: int(r["reps"])), "call #\(i): \(c.args)")
        }
    }

    @Test func setPerformanceMatchesJS() throws {
        for c in try fixture("setPerformance") {
            let got = Progression.setPerformance(targetReps: int(c.args[0]) ?? 0, actualReps: int(c.args[1]))
            #expect(got?.rawValue == c.result as? String)
        }
    }

    @Test func progressionHintMatchesJS() throws {
        let tones = ["var(--success)": HintTone.success, "#f0a030": .caution, "var(--danger)": .danger, "var(--muted)": .muted]
        for (i, c) in try fixture("computeProgressionHint").enumerated() {
            let a = c.args[0] as? JSON ?? [:]
            let sets = (a["sets"] as? [JSON] ?? []).map {
                HintSet(weight: num($0["weight"]), reps: int($0["reps"]) ?? 0, prevWeight: num($0["prev_weight"]), prevReps: int($0["prev_reps"]))
            }
            let got = ProgressionHint.compute(sets: sets, repMin: int(a["repMin"]) ?? 8, repMax: int(a["repMax"]) ?? 12,
                                              exerciseComplete: truthy(a["exerciseComplete"]), isBodyweight: truthy(a["isBodyweight"]),
                                              unit: WeightUnit(rawValue: a["unit"] as? String ?? "kg") ?? .kg)
            let want = (c.result as? JSON).map { ProgressionHintResult(text: $0["text"] as? String ?? "", tone: tones[$0["color"] as? String ?? ""] ?? .muted) }
            #expect(got == want, "call #\(i): \(a)")
        }
    }

    @Test func deloadMatchesJS() throws {
        for c in try fixture("deloadAdvice") {
            let lifts = (c.args[0] as? [JSON] ?? []).map {
                LiftTempo(name: $0["name"] as? String ?? "", tempo: Tempo(rawValue: $0["tempo"] as? String ?? "") ?? .normal, known: truthy($0["known"]))
            }
            let r = c.result as? JSON ?? [:]
            #expect(Deload.advice(lifts) == DeloadAdvice(suggest: truthy(r["suggest"]), slow: int(r["slow"]) ?? -1,
                                                          judged: int(r["judged"]) ?? -1, slowLifts: r["slow_lifts"] as? [String] ?? []))
        }
    }

    @Test func e1rmMatchesJS() throws {
        for c in try fixture("estimateOneRepMax") {
            #expect(E1RM.estimate(weight: num(c.args[0]), reps: int(c.args[1])) == num(c.result), "\(c.args)")
        }
    }

    @Test func recapMatchesJS() throws {
        func agg(_ v: Any?) -> LiftAggregate? {
            (v as? JSON).map { LiftAggregate(topW: num($0["topW"]) ?? 0, vol: num($0["vol"]) ?? 0, reps: int($0["reps"]) ?? 0) }
        }
        for c in try fixture("liftVerdict") {
            let o = c.args.count > 2 ? c.args[2] as? JSON ?? [:] : [:]
            #expect(Recap.liftVerdict(agg(c.args[0])!, prev: agg(c.args[1]), isBodyweight: truthy(o["isBodyweight"])).rawValue == c.result as? String, "\(c.args)")
        }
        for c in try fixture("capVerdictToTargets") {
            #expect(Recap.capVerdictToTargets(LiftVerdict(rawValue: c.args[0] as! String)!, missedEveryTarget: truthy(c.args[1])).rawValue == c.result as? String)
        }
        for c in try fixture("floorVerdictToTargets") {
            #expect(Recap.floorVerdictToTargets(LiftVerdict(rawValue: c.args[0] as! String)!, metEveryTarget: truthy(c.args[1])).rawValue == c.result as? String)
        }
        for c in try fixture("summarizeVerdicts") {
            let s = Recap.summarize((c.args[0] as? [String] ?? []).compactMap(LiftVerdict.init(rawValue:)))
            let r = c.result as? JSON ?? [:]
            #expect([s.up, s.held, s.down, s.eased, s.new, s.comparable, s.total] ==
                    ["up", "held", "down", "eased", "new", "comparable", "total"].map { int(r[$0]) ?? -1 })
        }
    }

    @Test func statsWeeksMatchesJS() throws {
        for c in try fixture("selectProgressWeeks") {
            let m = (c.args[2] as? [String: JSON] ?? [:]).mapValues { WeekSessions(total: int($0["total"]) ?? 0, done: int($0["done"]) ?? 0) }
            let got = StatsWeeks.selectProgressWeeks(c.args[0] as? [String] ?? [], cur: c.args[1] as? String ?? "", sessByWeek: m)
            let r = c.result as? JSON ?? [:]
            #expect(got.firstWeek == r["firstWeek"] as? String && got.lastWeek == r["lastWeek"] as? String, "\(c.args)")
        }
    }
}
