import AVFoundation
import XCTest
@testable import TelemetryIO

/// Regression coverage for driver intents and real AVAudioEngine callbacks.
/// Immediate stop cases cancel pending driver Tasks before yielding MainActor.
/// AudioSessionCoordinatorTests separately hold activation in flight to verify late completion.
final class AudioActivationLifecycleTests: XCTestCase {
    @MainActor
    func testDroppingPendingOutputDriverReleasesItsAudioOwnership() async {
        let baseline = AudioSessionCoordinator.shared.ownerCount
        var feedback: IOFeedback? = IOFeedback()
        weak let observed = feedback
        feedback?.tone(frequency: 440, gain: 0.04)
        XCTAssertEqual(AudioSessionCoordinator.shared.ownerCount, baseline + 1)
        feedback = nil
        let released = await waitUntil { observed == nil && AudioSessionCoordinator.shared.ownerCount == baseline }
        XCTAssertTrue(released, "A disappearing output owner must not orphan a pending audio-session reservation.")
    }

    @MainActor
    func testDroppingPendingInputDriverReleasesItsAudioOwnership() async throws {
        try requireMicrophonePermission()
        let baseline = AudioSessionCoordinator.shared.ownerCount
        var hub: TelemetryHub? = TelemetryHub()
        weak let observed = hub
        hub?.start()
        hub?.enable("microphone")
        XCTAssertEqual(AudioSessionCoordinator.shared.ownerCount, baseline + 1)
        hub = nil
        let released = await waitUntil { observed == nil && AudioSessionCoordinator.shared.ownerCount == baseline }
        XCTAssertTrue(released, "A disappearing capture owner must not keep the shared session reserved.")
    }

    @MainActor
    func testToneStoppedWhileActivationIsPendingCannotStartOrRenderLater() async {
        let feedback = IOFeedback()
        defer { feedback.stopTone() }
        feedback.tone(frequency: 440, gain: 0.04)
        XCTAssertTrue(feedback.isToneStarting)
        XCTAssertFalse(feedback.isToneRunning)
        feedback.stopTone()
        XCTAssertFalse(feedback.isToneStarting)
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(feedback.isToneStarting)
        XCTAssertFalse(feedback.isToneRunning)
        XCTAssertEqual(feedback.renderedFrameCount, 0, "A cancelled activation must not create an audio render callback later.")
        XCTAssertNil(feedback.error)
    }

    @MainActor
    func testRapidToneStopAndReenableStartsOnlyTheCurrentIntent() async {
        let feedback = IOFeedback()
        defer { feedback.stopTone() }
        for _ in 0..<8 {
            feedback.tone(frequency: 220, gain: 0.04)
            XCTAssertTrue(feedback.isToneStarting)
            feedback.stopTone()
        }
        feedback.tone(frequency: 660, gain: 0.04)
        let rendered = await waitUntil { feedback.isToneRunning && feedback.renderedFrameCount > 2048 && feedback.renderedPeak > 0.03 }
        XCTAssertTrue(rendered, feedback.error ?? "The latest output intent must survive earlier cancelled activations.")
        XCTAssertFalse(feedback.isToneStarting)
        XCTAssertNil(feedback.error)
        let first = feedback.audioRenderSnapshot
        try? await Task.sleep(for: .milliseconds(200))
        let last = feedback.audioRenderSnapshot
        if last.frames > first.frames, last.crossings >= first.crossings {
            let frames = last.frames - first.frames
            let measuredFrequency = Double(last.crossings - first.crossings) * last.rate / (2 * Double(frames))
            XCTAssertEqual(measuredFrequency, 660, accuracy: 12, "Actual rendered samples must reflect the current tone intent.")
        } else {
            XCTFail("The current engine must keep rendering after asynchronous activation settles.")
        }
        feedback.stopTone()
        let stoppedFrames = feedback.renderedFrameCount
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(feedback.isToneRunning)
        XCTAssertEqual(feedback.renderedFrameCount, stoppedFrames)
    }

    @MainActor
    func testMicrophoneDisabledWhileActivationIsPendingCannotPublishLater() async throws {
        try requireMicrophonePermission()
        let hub = TelemetryHub()
        hub.start()
        defer { hub.stop() }
        hub.enable("microphone")
        XCTAssertTrue(hub.microphoneStarting)
        XCTAssertFalse(hub.microphoneActive)
        hub.disable("microphone")
        XCTAssertFalse(hub.microphoneStarting)
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(hub.microphoneStarting)
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertEqual(hub.reading("mic.rms").status, .off)
        XCTAssertNil(hub.reading("mic.rms").value)
        XCTAssertTrue(hub.reading("mic.rms").samples.isEmpty)
        XCTAssertTrue(hub.waveform.isEmpty)
        XCTAssertTrue(hub.spectrum.isEmpty)
    }

    @MainActor
    func testRapidMicrophoneDisableAndReenableCapturesOnlyTheCurrentGeneration() async throws {
        try requireMicrophonePermission()
        let hub = TelemetryHub()
        hub.start()
        defer { hub.stop() }
        for _ in 0..<8 { hub.enable("microphone"); hub.disable("microphone") }
        hub.enable("microphone")
        let captured = await waitUntil { hub.microphoneActive && hub.reading("mic.rms").status == .live && !hub.waveform.isEmpty }
        XCTAssertTrue(captured, hub.reading("mic.rms").detail)
        XCTAssertFalse(hub.microphoneStarting)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        hub.stop()
        let samples = hub.reading("mic.rms").samples.count
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertFalse(hub.microphoneStarting)
        XCTAssertEqual(hub.reading("mic.rms").samples.count, samples)
        XCTAssertNotEqual(hub.reading("mic.rms").status, .live)
    }

    @MainActor
    func testConcurrentMicrophoneAndToneIntentsDoNotStopEachOther() async throws {
        try requireMicrophonePermission()
        let hub = TelemetryHub()
        let feedback = IOFeedback()
        hub.start()
        defer { feedback.stopTone(); hub.stop() }
        hub.enable("microphone")
        // The pending input lease must win even before microphoneActive becomes true.
        feedback.tone(frequency: 440, gain: 0.04, recording: hub.microphoneActive)
        let both = await waitUntil {
            feedback.tone(frequency: 440, gain: 0.04, recording: hub.microphoneActive)
            return hub.microphoneActive && hub.reading("mic.rms").status == .live && feedback.isToneRunning && feedback.renderedFrameCount > 2048
        }
        XCTAssertTrue(both, feedback.error ?? hub.reading("mic.rms").detail)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        feedback.stopTone()
        let microphoneSamples = hub.reading("mic.rms").samples.count
        let inputContinued = await waitUntil { hub.microphoneActive && hub.reading("mic.rms").samples.count > microphoneSamples }
        XCTAssertTrue(inputContinued, "Releasing the output lease must not deactivate the microphone session.")
        feedback.tone(frequency: 880, gain: 0.04, recording: hub.microphoneActive)
        let restarted = await waitUntil { feedback.isToneRunning && feedback.renderedFrameCount > 2048 }
        XCTAssertTrue(restarted, feedback.error ?? "The output must restart alongside the remaining input owner.")
        hub.disable("microphone")
        let framesAfterInputStopped = feedback.renderedFrameCount
        let outputContinued = await waitUntil {
            // Matches InstrumentModel's command refresh and permits an OS route-format rebuild.
            feedback.tone(frequency: 880, gain: 0.04, recording: false)
            return feedback.isToneRunning && feedback.renderedFrameCount > framesAfterInputStopped + 2048
        }
        XCTAssertTrue(outputContinued, feedback.error ?? "Releasing input must not strand the output intent.")
        XCTAssertFalse(hub.microphoneActive)
        XCTAssertEqual(hub.reading("mic.rms").status, .off)
    }

    @MainActor
    func testPauseDuringInputAndOutputActivationCancelsBothSessions() async throws {
        try requireMicrophonePermission()
        let key = "telemetry.patches.v1"
        let saved = UserDefaults.standard.object(forKey: key)
        let model = InstrumentModel()
        defer {
            model.stop()
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        model.patches = [
            ModulationPatch(sourceID: "touch.x", target: .pitch, depth: 1, smoothing: 0),
            ModulationPatch(sourceID: "touch.y", target: .amplitude, depth: 1, inverted: true, smoothing: 0)
        ]
        model.start()
        model.touch(CGPoint(x: 50, y: 0), size: CGSize(width: 100, height: 100))
        model.hub.enable("microphone")
        XCTAssertTrue(model.hub.microphoneStarting)
        model.soundEnabled = true
        XCTAssertFalse(model.toneRunning, "The pending session should not synchronously build an engine on MainActor.")
        model.togglePause()
        XCTAssertTrue(model.paused)
        XCTAssertFalse(model.hub.isRunning)
        XCTAssertFalse(model.hub.microphoneStarting)
        XCTAssertTrue(model.outputs.isEmpty)
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(model.toneRunning)
        XCTAssertFalse(model.hub.microphoneActive)
        XCTAssertTrue(model.hub.waveform.isEmpty)
        XCTAssertTrue(model.hub.spectrum.isEmpty)
        for id in ["output.pitch", "output.level", "output.haptic"] {
            XCTAssertEqual(model.hub.reading(id).status, .off, id)
            XCTAssertNil(model.hub.reading(id).value, id)
        }
    }

    @MainActor
    private func requireMicrophonePermission() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant microphone access to the dedicated simulator app before running activation lifecycle tests.")
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
