import Darwin
import Foundation
#if canImport(TelemetryCore)
import TelemetryCore
#endif

/// Aggregate link-layer counters supplied by the OS, without packet contents or app attribution.
struct InterfaceTrafficReading: Identifiable, Sendable {
    let id: String
    let name: String
    let rxBytes: UInt64
    let txBytes: UInt64
    let rxRate: Double
    let txRate: Double
    let rxPackets: UInt64
    let txPackets: UInt64
    let rxPacketRate: Double
    let txPacketRate: Double
}

/// `getifaddrs` exposes legacy UInt32 counters. These reset on reboot or interface restart and
/// wrap at 4 GiB. Widening them does not turn them into lifetime UInt64 counters. Rates use
/// successive samples, recognize a wrap near the boundary, and rebaseline ambiguous drops.
/// Apple reference: https://developer.apple.com/forums/thread/750938
final class InterfaceTraffic {
    /// Supplying NWPath.availableInterfaces names limits aggregation to the route interfaces.
    var interfaceNames: Set<String>?
    static let explanation = "Aggregate interface counters. iOS does not identify which app sent each byte. Counters are 32-bit, wrap at 4 GiB, and reset on restart; ambiguous drops start a new baseline."

    private struct Snapshot {
        let time: Double
        let rxBytes: UInt32
        let txBytes: UInt32
        let rxPackets: UInt32
        let txPackets: UInt32
    }
    private var previous: [String: Snapshot] = [:]

    init() {}

    func sample(now: Double) -> [InterfaceTrafficReading] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }
        var current: [String: Snapshot] = [:]
        var results: [InterfaceTrafficReading] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let address = entry.pointee
            guard let namePointer = address.ifa_name,
                  let socketAddress = address.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let data = address.ifa_data,
                  address.ifa_flags & UInt32(IFF_UP) != 0,
                  address.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  address.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: namePointer)
            guard current[name] == nil else { continue }
            if let interfaceNames, !interfaceNames.contains(name) { continue }
            // Apple peer-to-peer aliases are separate from the app's infrastructure data path.
            // Virtual interfaces can duplicate bytes already counted by their physical transport.
            guard !["awdl", "llw", "p2p", "utun", "ipsec", "bridge"].contains(where: name.hasPrefix) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            guard counters.ifi_type == UInt8(IFT_ETHER) || counters.ifi_type == UInt8(IFT_CELLULAR) else { continue }
            let snapshot = Snapshot(time: now, rxBytes: counters.ifi_ibytes, txBytes: counters.ifi_obytes,
                                    rxPackets: counters.ifi_ipackets, txPackets: counters.ifi_opackets)
            current[name] = snapshot
            let prior = previous[name]
            // A reset in another counter disambiguates an apparent byte-counter wrap.
            let resetDetected = prior.map {
                TrafficMath.needsBaseline(previous: [$0.rxBytes, $0.txBytes, $0.rxPackets, $0.txPackets],
                                          current: [snapshot.rxBytes, snapshot.txBytes, snapshot.rxPackets, snapshot.txPackets])
            } ?? false
            let dt = resetDetected ? 0 : (prior.map { now - $0.time } ?? 0)
            results.append(InterfaceTrafficReading(
                id: name, name: name,
                rxBytes: UInt64(snapshot.rxBytes), txBytes: UInt64(snapshot.txBytes),
                rxRate: prior.map { Self.rate(before: $0.rxBytes, after: snapshot.rxBytes, elapsed: dt) } ?? 0,
                txRate: prior.map { Self.rate(before: $0.txBytes, after: snapshot.txBytes, elapsed: dt) } ?? 0,
                rxPackets: UInt64(snapshot.rxPackets), txPackets: UInt64(snapshot.txPackets),
                rxPacketRate: prior.map { Self.rate(before: $0.rxPackets, after: snapshot.rxPackets, elapsed: dt) } ?? 0,
                txPacketRate: prior.map { Self.rate(before: $0.txPackets, after: snapshot.txPackets, elapsed: dt) } ?? 0))
        }
        previous = current
        return results.sorted { $0.name < $1.name }
    }

    /// Conservative wrap handling; a long pause can hide multiple wraps, so it has no rate.
    static func rate(before: UInt32, after: UInt32, elapsed: Double) -> Double {
        TrafficMath.rate(previous: before, current: after, elapsed: elapsed)
    }

    func reset() { previous.removeAll() }
}
