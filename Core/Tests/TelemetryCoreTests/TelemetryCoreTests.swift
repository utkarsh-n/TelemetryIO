import Testing
@testable import TelemetryCore

@Test func catalogIsCoherent() {
    #expect(Set(SignalCatalog.all.map(\.id)).count == SignalCatalog.all.count)
    #expect(SignalCatalog.all.allSatisfy { $0.range.upperBound > $0.range.lowerBound && !$0.source.isEmpty && !$0.explanation.isEmpty })
}
@Test func normalizationClampsAndRejectsNonFinite() {
    let d = SignalCatalog.definition("gyro.x")!
    #expect(d.normalized(-8) == 0); #expect(d.normalized(8) == 1); #expect(d.normalized(0) == 0.5)
    #expect(d.normalized(100) == 1); #expect(d.normalized(.nan) == 0)
}
@Test func historyBoundAndStaleTransition() {
    var r = SignalReading(definition: SignalCatalog.definition("pressure")!)
    for i in 0..<1000 { r.append(Double(i), at: Double(i), status: .live, capacity: 10) }
    #expect(r.samples.count == 10); #expect(r.samples.first?.time == 990)
    r.append(.nan, at: 1001, status: .live); #expect(r.value == 999)
    r.markStale(now: 1003); #expect(r.status == .stale)
}
@Test func demoNeverBecomesStaleLive() {
    var r = SignalReading(definition: SignalCatalog.definition("pressure")!)
    r.append(100, at: 0, status: .demo); r.markStale(now: 100); #expect(r.status == .demo)
}
@Test func mappingDepthAndInversion() {
    let d = SignalCatalog.definition("touch.x")!
    #expect(ModulationMath.mapped(100, definition: d, depth: 0.7, inverted: false) == 0.7)
    #expect(ModulationMath.mapped(100, definition: d, depth: 0.7, inverted: true) == 0)
    #expect(ModulationMath.mapped(0, definition: d, depth: 2, inverted: true) == 1)
    #expect(ModulationMath.mapped(50, definition: d, depth: .nan, inverted: false) == 0)
}
@Test func smoothingIsFrameRateIndependent() {
    let once = ModulationMath.smooth(previous: 0, input: 1, smoothing: 0.7, dt: 1)
    var many = 0.0
    for _ in 0..<20 { many = ModulationMath.smooth(previous: many, input: 1, smoothing: 0.7, dt: 0.05) }
    #expect(abs(once - many) < 1e-12)
    #expect(ModulationMath.smooth(previous: 0.5, input: .nan, smoothing: 1, dt: 1) == 0.5)
    #expect(ModulationMath.smooth(previous: 0.5, input: 1, smoothing: 1, dt: -1) == 0.5)
}
