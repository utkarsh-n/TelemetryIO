import Foundation
import Testing
@testable import TelemetryCore

private func positiveAngleDelta(_ from: Double, _ to: Double) -> Double {
    let difference = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    return difference < 0 ? difference + 2 * .pi : difference
}

@Test func changingOrbitChangesOnlyFutureAngularVelocity() {
    var motion = OrbitalMotion()
    motion.advance(orbit: 0, dt: 100)
    let before = motion
    motion.advance(orbit: 1, dt: 0.05)
    for ring in motion.ringPhases.indices {
        let expected = 0.05 * 0.46 * (1 + Double(ring) * 0.13)
        #expect(abs(positiveAngleDelta(before.ringPhases[ring], motion.ringPhases[ring]) - expected) < 1e-12)
    }
    #expect(abs(positiveAngleDelta(before.tiltPhase, motion.tiltPhase) - 0.05 * 0.46 * 0.2) < 1e-12)
}

@Test func eachOrbitalComponentWrapsIndependentlyWithoutPositionJumps() {
    var motion = OrbitalMotion()
    motion.advance(orbit: 1, dt: 6.27 / 0.46)
    let before = motion
    motion.advance(orbit: 1, dt: 0.1)
    #expect(motion.ringPhases[0] < 0.1)
    for ring in motion.ringPhases.indices {
        #expect(abs(positiveAngleDelta(before.ringPhases[ring], motion.ringPhases[ring]) - 0.1 * 0.46 * (1 + Double(ring) * 0.13)) < 1e-12)
    }
    #expect(abs(motion.tiltPhase - before.tiltPhase - 0.1 * 0.46 * 0.2) < 1e-12)
    #expect(motion.ringPhases.allSatisfy { (0..<(2 * .pi)).contains($0) })
}

@Test func orbitalPhaseUsesElapsedTimeAndHasNoTwoHundredSecondReset() {
    var split = OrbitalMotion(), whole = OrbitalMotion()
    split.advance(orbit: 0.2, dt: 199.95)
    split.advance(orbit: 0.2, dt: 0.1)
    whole.advance(orbit: 0.2, dt: 200.05)
    for ring in split.ringPhases.indices { #expect(abs(split.ringPhases[ring] - whole.ringPhases[ring]) < 1e-12) }
    #expect(abs(split.tiltPhase - whole.tiltPhase) < 1e-12)
    // At 200 s the previous absolute-time animation reset almost to zero.
    #expect(split.ringPhases[0] > 2)
}

@Test func pausedOrInvalidElapsedTimeCannotAdvanceOrbitalPhase() {
    var motion = OrbitalMotion()
    motion.advance(orbit: 0.5, dt: 7)
    let before = motion
    for interval in [0.0, -1, Double.nan, .infinity] { motion.advance(orbit: 1, dt: interval); #expect(motion == before) }
    motion.advance(orbit: .nan, dt: 0.05)
    #expect(motion.ringPhases.allSatisfy { $0.isFinite && (0..<(2 * .pi)).contains($0) })
    #expect(motion.tiltPhase.isFinite)
}
