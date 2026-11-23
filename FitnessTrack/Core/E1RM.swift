// Port of FitnessTrack shared/e1rm.js (MIT, (c) 2026 Giuliano Maciocci).
// Estimated one-rep max (Epley): weight × (1 + reps / 30); a single is its own 1RM.

import Foundation

public enum E1RM {
    public static func estimate(weight: Double?, reps: Int?) -> Double? {
        guard let w = weight, w > 0, let r = reps, r >= 1 else { return nil }
        if r == 1 { return w }
        return Progression.jsRound(w * (1 + Double(r) / 30) * 10) / 10
    }
}
