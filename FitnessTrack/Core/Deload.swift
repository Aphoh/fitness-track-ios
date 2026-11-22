// Port of FitnessTrack shared/deload.js (MIT, (c) 2026 Giuliano Maciocci).
// Suggest a lighter week when at least half of the judgeable lifts are "slow".

import Foundation

public struct LiftTempo: Sendable {
    public var name: String
    public var tempo: Tempo
    public var known: Bool
    public init(name: String, tempo: Tempo, known: Bool = true) { self.name = name; self.tempo = tempo; self.known = known }
}

public struct DeloadAdvice: Equatable, Sendable {
    public var suggest: Bool
    public var slow: Int
    public var judged: Int
    public var slowLifts: [String]
}

public enum Deload {
    public static let minLifts = 3
    public static let slowShare = 0.5

    public static func advice(_ lifts: [LiftTempo]) -> DeloadAdvice {
        let judged = lifts.filter(\.known)
        let slow = judged.filter { $0.tempo == .slow }
        let suggest = judged.count >= minLifts && Double(slow.count) / Double(judged.count) >= slowShare
        return DeloadAdvice(suggest: suggest, slow: slow.count, judged: judged.count, slowLifts: slow.map(\.name))
    }
}
