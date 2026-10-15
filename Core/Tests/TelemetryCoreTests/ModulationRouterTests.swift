import Foundation
import Testing
@testable import TelemetryCore

private func routingReading(_ id: String = "touch.x", value: Double?, status: SignalStatus = .live) -> SignalReading {
    var reading = SignalReading(definition: SignalCatalog.definition(id)!)
    reading.value = value; reading.status = status
    return reading
}

@Test func routeRejectsUnavailableStaleAndNonfiniteSources() {
    let patch = ModulationPatch(sourceID: "touch.x", target: .field, depth: 1, inverted: true)
    for status in [SignalStatus.off, .permission, .unavailable, .restricted, .waiting, .stale] {
        var router = ModulationRouter()
        let result = router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 0, status: status)], dt: 0.05)
        #expect(result.values[.field] == 0)
        #expect(!result.readyTargets.contains(.field))
    }
    for input in [Double.nan, .infinity, -.infinity] {
        var router = ModulationRouter()
        let result = router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: input)], dt: 0.05)
        #expect(result.values[.field] == 0)
        #expect(result.readyTargets.isEmpty)
    }
    var router = ModulationRouter()
    #expect(router.evaluate(patches: [patch], readings: [:], dt: 0.05).values[.field] == 0)
}

@Test func demoInputsAreRoutableAndAggregationSaturates() {
    var router = ModulationRouter()
    let patches = [ModulationPatch(sourceID: "touch.x", target: .field, depth: 0.7), ModulationPatch(sourceID: "touch.y", target: .field, depth: 0.7)]
    let result = router.evaluate(patches: patches, readings: ["touch.x": routingReading(value: 100, status: .demo), "touch.y": routingReading("touch.y", value: 100)], dt: 0.05)
    #expect(result.values[.field] == 1)
    #expect(result.readyTargets == [.field])
}

@Test func disabledRemovedAndDisappearingSourcesCannotRetainFilterMemory() {
    var router = ModulationRouter()
    var patch = ModulationPatch(sourceID: "touch.x", target: .field, depth: 1, smoothing: 1)
    #expect(router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 100)], dt: 0.05).values[.field] == 1)
    patch.enabled = false
    #expect(router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 100)], dt: 0.05).values[.field] == nil)
    patch.enabled = true
    #expect(router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 0)], dt: 0.05).values[.field] == 0)
    _ = router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 100)], dt: 1)
    #expect(router.evaluate(patches: [patch], readings: [:], dt: 0.05).values[.field] == 0)
    #expect(router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 0)], dt: 0.05).values[.field] == 0)
    _ = router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 100)], dt: 1)
    #expect(router.evaluate(patches: [], readings: [:], dt: 0.05).values.isEmpty)
    #expect(router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 0)], dt: 0.05).values[.field] == 0)
}

@Test func routeIdentitySourceAndTargetChangesResetTheirFilter() {
    var router = ModulationRouter()
    var patch = ModulationPatch(sourceID: "touch.x", target: .field, depth: 1, smoothing: 1)
    _ = router.evaluate(patches: [patch], readings: ["touch.x": routingReading(value: 100)], dt: 0.05)
    patch.sourceID = "touch.y"
    #expect(router.evaluate(patches: [patch], readings: ["touch.y": routingReading("touch.y", value: 0)], dt: 0.05).values[.field] == 0)
    _ = router.evaluate(patches: [patch], readings: ["touch.y": routingReading("touch.y", value: 100)], dt: 1)
    patch.target = .orbit
    let result = router.evaluate(patches: [patch], readings: ["touch.y": routingReading("touch.y", value: 0)], dt: 0.05)
    #expect(result.values[.field] == nil)
    #expect(result.values[.orbit] == 0)
}

@Test func routingSmoothingUsesElapsedTimeAcrossUnevenTicks() {
    let patch = ModulationPatch(sourceID: "touch.x", target: .field, depth: 1, smoothing: 0.7)
    var steady = ModulationRouter(), delayed = ModulationRouter()
    let zero = ["touch.x": routingReading(value: 0)]
    let one = ["touch.x": routingReading(value: 100)]
    _ = steady.evaluate(patches: [patch], readings: zero, dt: 0)
    _ = delayed.evaluate(patches: [patch], readings: zero, dt: 0)
    var result: RoutingResult?
    for _ in 0..<20 { result = steady.evaluate(patches: [patch], readings: one, dt: 0.05) }
    let delayedResult = delayed.evaluate(patches: [patch], readings: one, dt: 1)
    #expect(abs(result!.values[.field]! - delayedResult.values[.field]!) < 1e-12)
    let held = delayed.evaluate(patches: [patch], readings: zero, dt: .nan)
    #expect(held.values[.field] == delayedResult.values[.field])
    delayed.reset()
    #expect(delayed.evaluate(patches: [patch], readings: zero, dt: 0.05).values[.field] == 0)
}

@Test func audioNeedsRoutesAndNeverFallsBackWhenConfiguredSourceDisappears() {
    var router = ModulationRouter()
    let pitch = ModulationPatch(sourceID: "touch.x", target: .pitch, depth: 1)
    let level = ModulationPatch(sourceID: "touch.y", target: .amplitude, depth: 1)
    #expect(router.evaluate(patches: [], readings: [:], dt: 0.05).tone == nil)
    let pitchOnly = router.evaluate(patches: [pitch], readings: ["touch.x": routingReading(value: 100)], dt: 0.05)
    #expect(pitchOnly.tone == ToneCommand(frequency: 1600, gain: 0.03))
    let both = router.evaluate(patches: [pitch, level], readings: ["touch.x": routingReading(value: 100), "touch.y": routingReading("touch.y", value: 100)], dt: 0.05)
    #expect(both.tone == ToneCommand(frequency: 1600, gain: 0.25))
    let lostLevel = router.evaluate(patches: [pitch, level], readings: ["touch.x": routingReading(value: 100)], dt: 0.05)
    #expect(lostLevel.values[.amplitude] == 0)
    #expect(lostLevel.tone == nil)
    #expect(router.evaluate(patches: [pitch, level], readings: ["touch.y": routingReading("touch.y", value: 100)], dt: 0.05).tone == nil)
    #expect(router.evaluate(patches: [level], readings: ["touch.y": routingReading("touch.y", value: 100, status: .stale)], dt: 0.05).tone == nil)
}

@Test func persistedPatchesAreBoundedUniqueAndFinite() {
    var depth = ModulationPatch(sourceID: "touch.x", target: .field, depth: .nan, smoothing: .infinity)
    var duplicateID = ModulationPatch(sourceID: "touch.y", target: .orbit)
    duplicateID.id = depth.id
    let duplicateRoute = ModulationPatch(sourceID: "touch.x", target: .field)
    let invalid = ModulationPatch(sourceID: "obsolete.sensor", target: .field)
    depth.enabled = false
    let result = ModulationRouter.sanitized([depth, duplicateID, duplicateRoute, invalid])
    #expect(result.count == 1)
    #expect(result[0].depth == 0 && result[0].smoothing == 0)
    #expect(!result[0].enabled)
    let many = SignalCatalog.all.prefix(25).map { ModulationPatch(sourceID: $0.id, target: .field, depth: 2, smoothing: -1) }
    #expect(ModulationRouter.sanitized(many).count == 16)
    #expect(ModulationRouter.sanitized(many).allSatisfy { $0.depth == 1 && $0.smoothing == 0 })
    #expect(ModulationRouter.sanitized(many, limit: 0).isEmpty)
}
