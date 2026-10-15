/// Pure arithmetic for the UInt32 counters exposed by getifaddrs/if_data.
/// Values are aggregate interface counters, not per-app usage or persistent lifetime totals.
public enum TrafficMath {
    /// A drop away from the wrapping boundary is ambiguous and starts a new baseline.
    public static func delta(previous: UInt32, current: UInt32) -> UInt64? {
        if current >= previous { return UInt64(current - previous) }
        let window = UInt32.max / 4
        guard previous > UInt32.max - window, current < window else { return nil }
        return UInt64(current &- previous)
    }

    /// A long sampling gap can hide multiple wraps, so no rate is claimed across that gap.
    public static func rate(previous: UInt32, current: UInt32, elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0, elapsed <= 10,
              let difference = delta(previous: previous, current: current) else { return 0 }
        return Double(difference) / elapsed
    }

    /// A reset in a companion packet/TX/RX counter invalidates all rates for that interface.
    public static func needsBaseline(previous: [UInt32], current: [UInt32]) -> Bool {
        guard !previous.isEmpty, previous.count == current.count else { return true }
        return zip(previous, current).contains { delta(previous: $0.0, current: $0.1) == nil }
    }
}
