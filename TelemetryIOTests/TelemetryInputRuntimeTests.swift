import AVFoundation
import XCTest
@testable import TelemetryIO

final class TelemetryInputRuntimeTests: XCTestCase {
    @MainActor
    func testMicrophoneCapturesRealBuffersAlongsideSynthAndReleasesOnDisable() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant microphone access to the dedicated simulator app before running this input test.")
        }
        let hub = TelemetryHub()
        let feedback = IOFeedback()
        hub.start()
        defer { feedback.stopTone(); hub.stop() }
        hub.enable("microphone")
        let captured = await waitUntil { hub.reading("mic.rms").status == .live && !hub.waveform.isEmpty }
        XCTAssertTrue(captured, hub.reading("mic.rms").detail)
        XCTAssertTrue(hub.microphoneActive)
        XCTAssertTrue(try XCTUnwrap(hub.reading("mic.rms").value).isFinite)
        XCTAssertTrue(try XCTUnwrap(hub.reading("mic.peak").value).isFinite)
        XCTAssertGreaterThan(try XCTUnwrap(hub.reading("audio.sampleRate").value), 0)
        XCTAssertEqual(hub.spectrum.count, 48)
        XCTAssertTrue(hub.spectrum.allSatisfy { $0.isFinite && (0...1).contains($0) })

        feedback.tone(frequency: 440, gain: 0.04, recording: hub.microphoneActive)
        let rendered = await waitUntil { feedback.renderedFrameCount > 2048 && feedback.renderedPeak > 0.03 }
        XCTAssertTrue(rendered, feedback.error ?? "Synth did not render alongside the microphone.")
        XCTAssertNil(feedback.error)
        XCTAssertTrue(hub.microphoneActive)

        hub.disable("microphone")
        let samples = hub.reading("mic.rms").samples.count
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertTrue(hub.waveform.isEmpty)
        XCTAssertTrue(hub.spectrum.isEmpty)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(hub.reading("mic.rms").status, .off)
        XCTAssertNil(hub.reading("mic.rms").value)
        XCTAssertEqual(hub.reading("mic.rms").samples.count, samples, "Late microphone buffers must not revive a disabled source.")

        hub.enable("microphone")
        let resumed = await waitUntil { hub.reading("mic.rms").status == .live && hub.reading("mic.rms").samples.count > samples }
        XCTAssertTrue(resumed, hub.reading("mic.rms").detail)
        feedback.tone(frequency: 660, gain: 0.04, recording: true)
        let resumedOutput = await waitUntil { feedback.isToneRunning && feedback.renderedFrameCount > 2048 }
        XCTAssertTrue(resumedOutput, feedback.error ?? "Synth did not resume after microphone re-enable.")
        hub.stop()
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertTrue(hub.waveform.isEmpty)
        XCTAssertTrue(hub.spectrum.isEmpty)
    }

    @MainActor
    func testPassiveDeviceAndNetworkAPIsUpdateAndStop() async throws {
        let hub = TelemetryHub()
        hub.start()
        defer { hub.stop() }
        let ids = ["device.thermal", "device.lowPower", "audio.volume", "network.reachable", "network.wifi", "network.expensive", "network.constrained"]
        let updated = await waitUntil { ids.allSatisfy { hub.reading($0).status == .live } }
        XCTAssertTrue(updated)
        for id in ids {
            XCTAssertTrue(try XCTUnwrap(hub.reading(id).value, id).isFinite, id)
            XCTAssertFalse(hub.reading(id).samples.isEmpty, id)
        }
        hub.stop()
        let counts = ids.map { hub.reading($0).samples.count }
        try? await Task.sleep(for: .milliseconds(250))
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(hub.reading(id).status, .stale, id)
            XCTAssertEqual(hub.reading(id).samples.count, counts[index], id)
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
