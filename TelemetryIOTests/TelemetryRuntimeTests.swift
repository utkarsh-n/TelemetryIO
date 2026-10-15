import AVFoundation
import CoreLocation
import Observation
import Synchronization
import XCTest
@testable import TelemetryIO

/// Runs inside the simulator app host. These tests verify actual app state, touch input,
/// capture output and audio rendering; generated sensor values are asserted only as DEMO.
final class TelemetryRuntimeTests: XCTestCase {
    @MainActor
    func testRepeatedStatusDoesNotInvalidateReadingsOrLoseCapturedHistory() {
        let hub = TelemetryHub()
        hub.publish("touch.x", value: 25, detail: "Recorded touch")
        hub.status("touch.x", .stale, detail: "Capture paused.")
        let samples = hub.reading("touch.x").samples
        let capture = hub.csv()
        let changed = ObservationChangeFlag()
        withObservationTracking {
            _ = hub.reading("touch.x")
        } onChange: {
            changed.markChanged()
        }

        for _ in 0..<20 { hub.status("touch.x", .stale, detail: "Capture paused.") }
        XCTAssertFalse(changed.value, "Unchanged statuses must not invalidate the shared readings dictionary.")
        XCTAssertEqual(hub.reading("touch.x").value, 25)
        XCTAssertEqual(hub.reading("touch.x").samples, samples)
        XCTAssertEqual(hub.csv(), capture)

        hub.status("touch.x", .off, detail: "Source stopped.")
        XCTAssertTrue(changed.value, "A real status transition must remain observable.")
        XCTAssertNil(hub.reading("touch.x").value)
        XCTAssertEqual(hub.reading("touch.x").samples, samples)
        XCTAssertEqual(hub.csv(), capture)
    }

    @MainActor
    func testNewHubHasNoEnabledOrInventedSensorReadings() {
        let hub = TelemetryHub()
        XCTAssertFalse(hub.isRunning)
        XCTAssertFalse(hub.isDemo)
        XCTAssertTrue(hub.enabled.isEmpty)
        XCTAssertEqual(Set(hub.readings.keys), Set(SignalCatalog.all.map(\.id)))
        for definition in SignalCatalog.all {
            let reading = hub.reading(definition.id)
            XCTAssertNil(reading.value, definition.id)
            XCTAssertTrue(reading.samples.isEmpty, definition.id)
            XCTAssertNotEqual(reading.status, .live, definition.id)
            #if targetEnvironment(simulator)
            if ["motion", "barometer", "steps", "bluetooth", "camera", "proximity", "nfc", "peer"].contains(definition.permission ?? "") {
                XCTAssertEqual(reading.status, .unavailable, definition.id)
            } else if definition.permission != nil { XCTAssertEqual(reading.status, .permission, definition.id) }
            #else
            if definition.permission == "peer" { XCTAssertEqual(reading.status, .waiting, definition.id) }
            else if definition.permission != nil { XCTAssertEqual(reading.status, .permission, definition.id) }
            #endif
        }
    }

    @MainActor
    func testEnableThenDisableWhileStoppedClearsEveryPendingSource() {
        let hub = TelemetryHub()
        let permissions = Set(SignalCatalog.all.compactMap(\.permission))
        for permission in permissions {
            hub.enable(permission)
            XCTAssertTrue(hub.enabled.contains(permission), permission)
            for definition in SignalCatalog.all where definition.permission == permission {
                XCTAssertEqual(hub.reading(definition.id).status, .waiting, definition.id)
            }
            hub.disable(permission)
            XCTAssertFalse(hub.enabled.contains(permission), permission)
            for definition in SignalCatalog.all where definition.permission == permission {
                XCTAssertEqual(hub.reading(definition.id).status, .off, definition.id)
                XCTAssertNil(hub.reading(definition.id).value, definition.id)
            }
        }
        hub.start()
        defer { hub.stop() }
        XCTAssertTrue(hub.enabled.isEmpty)
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertFalse(hub.nearbyProbe.running)
    }

    @MainActor
    func testSimulatorHardwareOnlySourcesStayUnavailableWithoutSamples() async throws {
        #if targetEnvironment(simulator)
        let hub = TelemetryHub()
        hub.start()
        defer { hub.stop() }
        // Location and microphone have simulator APIs and are intentionally excluded.
        let unavailable = ["motion", "barometer", "steps", "bluetooth", "camera", "proximity", "nfc", "peer"]
        for permission in unavailable { hub.enable(permission) }
        await settle()
        for definition in SignalCatalog.all where unavailable.contains(definition.permission ?? "") {
            let reading = hub.reading(definition.id)
            XCTAssertEqual(reading.status, .unavailable, definition.id)
            XCTAssertNil(reading.value, definition.id)
            XCTAssertTrue(reading.samples.isEmpty, definition.id)
            XCTAssertFalse(reading.detail.isEmpty, definition.id)
        }
        XCTAssertTrue(hub.bleDevices.isEmpty)
        XCTAssertTrue(hub.waveform.isEmpty)
        XCTAssertTrue(hub.spectrum.isEmpty)
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertFalse(hub.nearbyProbe.running)
        for permission in unavailable { hub.disable(permission) }
        for definition in SignalCatalog.all where unavailable.contains(definition.permission ?? "") {
            XCTAssertEqual(hub.reading(definition.id).status, .off, definition.id)
        }
        #else
        throw XCTSkip("Hardware availability assertions require the iPhone simulator.")
        #endif
    }

    @MainActor
    func testLiveTouchIsClampedAndCannotPublishAfterStop() async {
        let hub = TelemetryHub()
        hub.start()
        hub.recordTouch(x: -10, y: 150)
        XCTAssertEqual(hub.reading("touch.x").value, 0)
        XCTAssertEqual(hub.reading("touch.y").value, 100)
        XCTAssertEqual(hub.reading("touch.x").status, .live)
        hub.stop()
        let sampleCount = hub.reading("touch.x").samples.count
        let elapsed = hub.elapsed
        hub.recordTouch(x: 50, y: 50)
        await settle()
        XCTAssertFalse(hub.isRunning)
        XCTAssertEqual(hub.elapsed, elapsed)
        XCTAssertEqual(hub.reading("touch.x").samples.count, sampleCount)
        XCTAssertEqual(hub.reading("touch.x").status, .stale)
        XCTAssertEqual(hub.reading("touch.x").value, 0)
    }

    @MainActor
    func testDemoAndLiveTransitionsClearTracesAndPreserveProvenance() async {
        let hub = TelemetryHub()
        hub.setDemo(true)
        hub.start()
        defer { hub.stop() }
        await settle()
        let generated = SignalCatalog.all.filter { $0.group != .output && $0.group != .interaction }
        for definition in generated {
            XCTAssertEqual(hub.reading(definition.id).status, .demo, definition.id)
            XCTAssertNotNil(hub.reading(definition.id).value, definition.id)
            XCTAssertFalse(hub.reading(definition.id).samples.isEmpty, definition.id)
        }
        XCTAssertFalse(hub.waveform.isEmpty)
        XCTAssertFalse(hub.spectrum.isEmpty)
        XCTAssertFalse(hub.microphoneActive)
        let csv = hub.csv()
        XCTAssertTrue(csv.contains("\"DEMO\""))
        XCTAssertFalse(csv.contains("\"LIVE\""))
        hub.setDemo(false)
        XCTAssertTrue(hub.isRunning)
        XCTAssertFalse(hub.isDemo)
        XCTAssertTrue(hub.waveform.isEmpty)
        XCTAssertTrue(hub.spectrum.isEmpty)
        XCTAssertTrue(hub.bleDevices.isEmpty)
        for definition in SignalCatalog.all where definition.permission != nil {
            XCTAssertNotEqual(hub.reading(definition.id).status, .demo, definition.id)
            XCTAssertNil(hub.reading(definition.id).value, definition.id)
            XCTAssertTrue(hub.reading(definition.id).samples.isEmpty, definition.id)
        }
    }

    @MainActor
    func testTouchPatchRoutesDepthInversionAndDisableThroughTimer() async {
        await withModel { model in
            model.patches = [
                ModulationPatch(sourceID: "touch.x", target: .field, depth: 0.8, smoothing: 0),
                ModulationPatch(sourceID: "touch.y", target: .orbit, depth: 0.6, inverted: true, smoothing: 0)
            ]
            model.start()
            model.touch(CGPoint(x: 100, y: 50), size: CGSize(width: 200, height: 200))
            let routed = await waitUntil { model.outputs[.field] != nil && model.outputs[.orbit] != nil }
            XCTAssertTrue(routed)
            XCTAssertEqual(model.outputs[.field] ?? -1, 0.4, accuracy: 0.001)
            XCTAssertEqual(model.outputs[.orbit] ?? -1, 0.45, accuracy: 0.001)
            model.patches[0].enabled = false
            let disabled = await waitUntil { model.outputs[.field] == nil }
            XCTAssertTrue(disabled)
            XCTAssertEqual(model.outputs[.orbit] ?? -1, 0.45, accuracy: 0.001)
            model.removePatch(model.patches[1].id)
            let removed = await waitUntil { model.outputs.isEmpty }
            XCTAssertTrue(removed)
        }
    }

    @MainActor
    func testMissingSensorSourceCannotDriveAPatch() async {
        await withModel { model in
            model.patches = [ModulationPatch(sourceID: "mic.rms", target: .field, depth: 1, smoothing: 0)]
            model.start()
            await settle()
            XCTAssertFalse(model.hub.microphoneActive)
            XCTAssertNil(model.hub.reading("mic.rms").value)
            XCTAssertEqual(model.outputs[.field], 0)
        }
    }

    @MainActor
    func testSimulatorHapticRouteKeepsCommandVisibleButOutputUnavailable() async throws {
        #if targetEnvironment(simulator)
        await withModel { model in
            model.patches = [ModulationPatch(sourceID: "touch.x", target: .haptic, depth: 1, smoothing: 0)]
            model.start()
            model.touch(CGPoint(x: 80, y: 50), size: CGSize(width: 100, height: 100))
            model.hapticsEnabled = true
            let routed = await waitUntil { model.outputs[.haptic] != nil }
            XCTAssertTrue(routed)
            XCTAssertEqual(model.outputs[.haptic] ?? -1, 0.8, accuracy: 0.001)
            XCTAssertFalse(model.supportsHaptics)
            XCTAssertEqual(model.hub.reading("output.haptic").status, .unavailable)
            XCTAssertNil(model.hub.reading("output.haptic").value)
            model.hapticsEnabled = false
            XCTAssertEqual(model.hub.reading("output.haptic").status, .off)
        }
        #else
        throw XCTSkip("Simulator command routing does not establish physical haptic actuation.")
        #endif
    }

    @MainActor
    func testTouchTonePublishesCommandedOutputAndMuteStopsImmediately() async {
        await withModel { model in
            model.applyPreset("Touch")
            // Remove smoothing to make endpoint assertions independent of timer jitter.
            for index in model.patches.indices { model.patches[index].depth = 1; model.patches[index].smoothing = 0 }
            model.start()
            model.touch(CGPoint(x: 200, y: 0), size: CGSize(width: 200, height: 200))
            model.soundEnabled = true
            let started = await waitUntil(timeout: 5) { model.hub.reading("output.pitch").status == .live || model.outputError != nil }
            XCTAssertTrue(started)
            XCTAssertNil(model.outputError)
            XCTAssertEqual(model.hub.reading("output.pitch").status, .live)
            XCTAssertEqual(model.hub.reading("output.pitch").value ?? -1, 1600, accuracy: 0.001)
            XCTAssertEqual(model.hub.reading("output.level").value ?? -1, 25, accuracy: 0.001)
            model.soundEnabled = false
            XCTAssertFalse(model.toneRunning)
            XCTAssertEqual(model.hub.reading("output.pitch").status, .off)
            XCTAssertNil(model.hub.reading("output.pitch").value)
            XCTAssertEqual(model.hub.reading("output.level").status, .off)
            XCTAssertNil(model.hub.reading("output.level").value)
        }
    }

    @MainActor
    func testPauseAndStopClearOutputsAndDoNotResumeCaptureWhileInactive() async {
        await withModel { model in
            model.patches = [ModulationPatch(sourceID: "touch.x", target: .field, depth: 1, smoothing: 0)]
            model.start()
            model.touch(CGPoint(x: 100, y: 100), size: CGSize(width: 100, height: 100))
            let routed = await waitUntil { model.outputs[.field] == 1 }
            XCTAssertTrue(routed)
            model.togglePause()
            XCTAssertTrue(model.paused)
            XCTAssertFalse(model.hub.isRunning)
            XCTAssertTrue(model.outputs.isEmpty)
            let samples = model.hub.reading("touch.x").samples.count
            model.touch(CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 100))
            await settle()
            XCTAssertEqual(model.hub.reading("touch.x").samples.count, samples)
            model.stop()
            model.togglePause()
            XCTAssertFalse(model.paused)
            XCTAssertFalse(model.hub.isRunning)
            await settle()
            XCTAssertFalse(model.hub.isRunning)
            XCTAssertTrue(model.outputs.isEmpty)
            model.start()
            XCTAssertTrue(model.hub.isRunning)
            model.stop()
            XCTAssertFalse(model.hub.isRunning)
            XCTAssertTrue(model.outputs.isEmpty)
            for id in ["output.pitch", "output.level", "output.haptic"] { XCTAssertNotEqual(model.hub.reading(id).status, .live, id) }
        }
    }

    @MainActor
    func testExportContainsLiveTouchAndDemoSensorLabels() async throws {
        try await withModel { model in
            model.start()
            model.touch(CGPoint(x: 25, y: 75), size: CGSize(width: 100, height: 100))
            model.export()
            XCTAssertNil(model.exportError)
            let liveURL = try XCTUnwrap(model.lastExport)
            let liveCSV = try String(contentsOf: liveURL, encoding: .utf8)
            XCTAssertTrue(liveCSV.hasPrefix("signal,name,unit,time_s,value,mode\n"))
            XCTAssertTrue(liveCSV.split(separator: "\n").contains { $0.hasPrefix("\"touch.x\"") && $0.contains("25.00000000") && $0.hasSuffix("\"LIVE\"") })
            model.setDemo(true)
            await settle()
            model.export()
            XCTAssertNil(model.exportError)
            let demoCSV = try String(contentsOf: XCTUnwrap(model.lastExport), encoding: .utf8)
            XCTAssertTrue(demoCSV.split(separator: "\n").contains { $0.hasPrefix("\"pressure\"") && $0.hasSuffix("\"DEMO\"") })
        }
    }

    @MainActor
    func testInjectedSimulatorLocationArrivesThroughRealCoreLocationAndStops() async throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["TELEMETRY_TEST_LOCATION"] == "1" else {
            throw XCTSkip("Enable with TELEMETRY_TEST_LOCATION=1 after granting simulator location access and injecting 37.3349,-122.0090.")
        }
        let authorization = CLLocationManager().authorizationStatus
        guard [CLAuthorizationStatus.authorizedAlways, .authorizedWhenInUse].contains(authorization) else {
            XCTFail("The simulator test setup must grant location access before launch.")
            return
        }
        let hub = TelemetryHub()
        hub.start()
        defer { hub.stop() }
        hub.enable("location")
        let received = await waitUntil(timeout: 8) { hub.reading("location.latitude").status == .live }
        XCTAssertTrue(received, hub.reading("location.latitude").detail)
        XCTAssertEqual(hub.reading("location.latitude").value ?? 0, 37.3349, accuracy: 0.00001)
        XCTAssertEqual(hub.reading("location.longitude").value ?? 0, -122.0090, accuracy: 0.00001)
        XCTAssertGreaterThanOrEqual(hub.reading("location.accuracy").value ?? -1, 0)
        XCTAssertTrue(hub.csv().split(separator: "\n").contains { $0.hasPrefix("\"location.latitude\"") && $0.hasSuffix("\"LIVE\"") })
        hub.disable("location")
        let samples = hub.reading("location.latitude").samples.count
        await settle()
        XCTAssertEqual(hub.reading("location.latitude").status, .off)
        XCTAssertNil(hub.reading("location.latitude").value)
        XCTAssertEqual(hub.reading("location.latitude").samples.count, samples, "Late location callbacks must not revive a disabled source.")
        #else
        throw XCTSkip("Injected simulator coordinates do not validate physical GNSS.")
        #endif
    }

    @MainActor
    private func withModel(_ test: (InstrumentModel) async throws -> Void) async rethrows {
        let key = "telemetry.patches.v1"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        let model = InstrumentModel()
        defer {
            model.stop()
            if let url = model.lastExport { try? FileManager.default.removeItem(at: url) }
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try await test(model)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(180))
    }
}

private final class ObservationChangeFlag: Sendable {
    private let storage = Mutex(false)
    var value: Bool { storage.withLock { $0 } }
    func markChanged() { storage.withLock { $0 = true } }
}
