import Foundation

/// Independent periodic phases avoid jumps when a speed changes or one ring crosses a full turn.
public struct OrbitalMotion: Equatable, Sendable {
    public private(set) var ringPhases = Array(repeating: 0.0, count: 8)
    public private(set) var tiltPhase = 0.0
    public init() {}

    public mutating func advance(orbit: Double, dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        let drive = orbit.isFinite ? min(1, max(0, orbit)) : 0.2
        let speed = 0.06 + drive * 0.4
        for ring in ringPhases.indices {
            ringPhases[ring] = Self.wrapped(ringPhases[ring] + dt * speed * (1 + Double(ring) * 0.13))
        }
        tiltPhase = Self.wrapped(tiltPhase + dt * speed * 0.2)
    }

    private static func wrapped(_ angle: Double) -> Double {
        let remainder = angle.truncatingRemainder(dividingBy: 2 * .pi)
        return remainder < 0 ? remainder + 2 * .pi : remainder
    }
}
