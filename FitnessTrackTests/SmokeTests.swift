import Testing
@testable import FitnessTrack
@Test func smoke() { #expect(Progression.roundToHalf(1.26) == 1.5) }
