import Foundation

public enum SignalGroup: String, CaseIterable, Codable, Sendable {
    case motion = "Motion", environment = "Environment", location = "Location", audio = "Audio", radio = "Radio", device = "Device", interaction = "Interaction", output = "Output"
}

public enum SignalStatus: String, Codable, Sendable {
    case live = "LIVE", demo = "DEMO", off = "OFF", permission = "ALLOW", unavailable = "UNAVAILABLE", restricted = "RESTRICTED", waiting = "WAITING", stale = "STALE"
    public var hasData: Bool { self == .live || self == .demo || self == .stale }
}

public struct SignalDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let group: SignalGroup
    public let unit: String
    public let range: ClosedRange<Double>
    public let symbol: String
    public let explanation: String
    public let source: String
    public let permission: String?
    public let decimals: Int
    public init(_ id: String, _ name: String, _ group: SignalGroup, _ unit: String, _ range: ClosedRange<Double>, _ symbol: String, _ explanation: String, _ source: String, permission: String? = nil, decimals: Int = 2) {
        self.id = id; self.name = name; self.group = group; self.unit = unit; self.range = range; self.symbol = symbol; self.explanation = explanation; self.source = source; self.permission = permission; self.decimals = decimals
    }
    public func normalized(_ value: Double) -> Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    public func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", decimals, value)
    }
}

public struct SignalSample: Codable, Sendable, Equatable {
    public let time: Double
    public let value: Double
    public init(time: Double, value: Double) { self.time = time; self.value = value }
}

public struct SignalReading: Identifiable, Sendable {
    public let definition: SignalDefinition
    public var status: SignalStatus = .off
    public var value: Double?
    public var detail: String = ""
    public var samples: [SignalSample] = []
    public var id: String { definition.id }
    public var normalized: Double { definition.normalized(value ?? definition.range.lowerBound) }
    public init(definition: SignalDefinition) { self.definition = definition }
    public mutating func append(_ value: Double, at time: Double, status: SignalStatus, capacity: Int = 600) {
        guard value.isFinite, time.isFinite, capacity > 0 else { return }
        self.value = value; self.status = status
        samples.append(SignalSample(time: time, value: value))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
    public mutating func markStale(now: Double, after: Double = 3) {
        guard status == .live, let last = samples.last, now - last.time > after else { return }
        status = .stale
    }
}

public enum PatchTarget: String, CaseIterable, Codable, Sendable {
    case field = "Field energy", orbit = "Orbit speed", hue = "Phosphor hue", pitch = "Tone pitch", amplitude = "Tone level", haptic = "Haptic pulse"
    public var symbol: String {
        switch self { case .field: "waveform.path"; case .orbit: "rotate.3d"; case .hue: "paintpalette"; case .pitch: "waveform"; case .amplitude: "speaker.wave.2"; case .haptic: "hand.tap" }
    }
}

public struct ModulationPatch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: String
    public var target: PatchTarget
    public var depth: Double
    public var inverted: Bool
    public var smoothing: Double
    public var enabled: Bool
    public init(sourceID: String, target: PatchTarget, depth: Double = 0.7, inverted: Bool = false, smoothing: Double = 0.7, enabled: Bool = true) {
        id = UUID(); self.sourceID = sourceID; self.target = target; self.depth = depth; self.inverted = inverted; self.smoothing = smoothing; self.enabled = enabled
    }
}

public enum ModulationMath {
    public static func mapped(_ value: Double, definition: SignalDefinition, depth: Double, inverted: Bool) -> Double {
        let input = definition.normalized(value)
        let d = depth.isFinite ? min(1, max(0, depth)) : 0
        return (inverted ? 1 - input : input) * d
    }
    public static func smooth(previous: Double, input: Double, smoothing: Double, dt: Double) -> Double {
        guard input.isFinite else { return previous.isFinite ? previous : 0 }
        guard previous.isFinite else { return input }
        let tau = 0.015 + min(1, max(0, smoothing.isFinite ? smoothing : 0)) * 1.5
        let alpha = 1 - exp(-max(0, dt.isFinite ? dt : 0) / tau)
        return previous + (input - previous) * alpha
    }
}
