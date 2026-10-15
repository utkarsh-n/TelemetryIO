import Foundation

public struct ToneCommand: Equatable, Sendable {
    public let frequency: Double
    public let gain: Double
}

public struct RoutingResult: Sendable {
    public let values: [PatchTarget: Double]
    public let readyTargets: Set<PatchTarget>
    public var configuredTargets: Set<PatchTarget> { Set(values.keys) }

    /// A configured but missing audio input cannot fall back to an audible reference tone.
    /// A pitch-only route uses a quiet reference level; a level-only route uses a fixed pitch.
    public var tone: ToneCommand? {
        let audioTargets = configuredTargets.intersection([.pitch, .amplitude])
        guard !audioTargets.isEmpty, audioTargets.isSubset(of: readyTargets) else { return nil }
        let pitch = min(1, max(0, values[.pitch] ?? 0.45))
        let amplitude = min(1, max(0, values[.amplitude] ?? 0.12))
        return ToneCommand(frequency: 80 * pow(20, pitch), gain: amplitude * 0.25)
    }
}

/// Stateful filtering separated from sensor and output hardware for deterministic routing tests.
public struct ModulationRouter: Sendable {
    private struct RouteState: Sendable {
        let sourceID: String
        let target: PatchTarget
        let value: Double
    }
    private var states: [UUID: RouteState] = [:]

    public init() {}
    public mutating func reset() { states.removeAll() }

    public mutating func evaluate(patches: [ModulationPatch], readings: [String: SignalReading], dt: Double) -> RoutingResult {
        let enabledIDs = Set(patches.filter(\.enabled).map(\.id))
        states = states.filter { enabledIDs.contains($0.key) }
        var values: [PatchTarget: Double] = [:]
        var readyTargets: Set<PatchTarget> = []
        var visited: Set<UUID> = []

        for patch in patches where patch.enabled {
            guard visited.insert(patch.id).inserted else { continue }
            // Keep a zero for an enabled destination even when its input disappears.
            // The field and audio must not mistake unavailable input for an absent route.
            if values[patch.target] == nil { values[patch.target] = 0 }
            guard let reading = readings[patch.sourceID], reading.definition.id == patch.sourceID,
                  reading.status == .live || reading.status == .demo,
                  let input = reading.value, input.isFinite else {
                states.removeValue(forKey: patch.id)
                continue
            }
            let raw = ModulationMath.mapped(input, definition: reading.definition, depth: patch.depth, inverted: patch.inverted)
            let old = states[patch.id]
            let previous = old?.sourceID == patch.sourceID && old?.target == patch.target ? old?.value : nil
            let filtered = previous.map { ModulationMath.smooth(previous: $0, input: raw, smoothing: patch.smoothing, dt: dt) } ?? raw
            states[patch.id] = RouteState(sourceID: patch.sourceID, target: patch.target, value: filtered)
            values[patch.target] = min(1, max(0, (values[patch.target] ?? 0) + filtered))
            readyTargets.insert(patch.target)
        }
        return RoutingResult(values: values, readyTargets: readyTargets)
    }

    /// Reject obsolete sources and duplicate identities/routes, and bound persisted controls.
    public static func sanitized(_ patches: [ModulationPatch], limit: Int = 16) -> [ModulationPatch] {
        var result: [ModulationPatch] = []
        var identities: Set<UUID> = []
        var routes: Set<String> = []
        for var patch in patches {
            guard result.count < max(0, limit), SignalCatalog.definition(patch.sourceID) != nil,
                  !identities.contains(patch.id), !routes.contains("\(patch.sourceID)|\(patch.target.rawValue)") else { continue }
            identities.insert(patch.id); routes.insert("\(patch.sourceID)|\(patch.target.rawValue)")
            patch.depth = patch.depth.isFinite ? min(1, max(0, patch.depth)) : 0
            patch.smoothing = patch.smoothing.isFinite ? min(1, max(0, patch.smoothing)) : 0
            result.append(patch)
        }
        return result
    }
}
