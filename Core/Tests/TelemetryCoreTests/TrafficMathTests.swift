import Testing
@testable import TelemetryCore

@Test func trafficRatesUseElapsedTimeAndEqualCountersMeanZero() {
    #expect(TrafficMath.rate(previous: 100, current: 500, elapsed: 2) == 200)
    #expect(TrafficMath.rate(previous: 500, current: 500, elapsed: 0.5) == 0)
}

@Test func trafficCounterWrapIncludesTheZeroBoundary() {
    #expect(TrafficMath.delta(previous: UInt32.max, current: 0) == 1)
    #expect(TrafficMath.rate(previous: UInt32.max - 10, current: 9, elapsed: 1) == 20)
}

@Test func trafficAmbiguousCounterDropsStartANewBaseline() {
    #expect(TrafficMath.delta(previous: 5_000, current: 20) == nil)
    #expect(TrafficMath.rate(previous: 5_000, current: 20, elapsed: 1) == 0)
}

@Test func trafficInvalidElapsedTimeCannotCreateInfiniteOrNegativeRates() {
    for elapsed in [0.0, -1.0, .nan, .infinity, -.infinity] {
        #expect(TrafficMath.rate(previous: 100, current: 500, elapsed: elapsed) == 0)
    }
}

@Test func trafficRatesDiscardLongGapsThatCouldHideMultipleWraps() {
    #expect(TrafficMath.rate(previous: 1, current: 10, elapsed: 11) == 0)
    #expect(TrafficMath.rate(previous: 1, current: 11, elapsed: 10) == 1)
}

@Test func trafficCompanionCounterResetDisambiguatesAnApparentByteWrap() {
    #expect(TrafficMath.needsBaseline(previous: [UInt32.max - 10, 500, 10_000], current: [9, 600, 0]))
    #expect(!TrafficMath.needsBaseline(previous: [UInt32.max - 10, 500, 10_000], current: [9, 600, 10_010]))
}

@Test func trafficDifferentOrMissingInterfaceCountersNeedANewBaseline() {
    #expect(TrafficMath.needsBaseline(previous: [], current: []))
    #expect(TrafficMath.needsBaseline(previous: [1, 2], current: [3]))
    #expect(!TrafficMath.needsBaseline(previous: [1, 2], current: [3, 4]))
}
