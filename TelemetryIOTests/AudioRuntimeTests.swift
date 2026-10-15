import XCTest
@testable import TelemetryIO

final class AudioRuntimeTests: XCTestCase {
    func testAnalyzerFinds440And1000HertzWithinOneFFTBin() throws {
        let rate = 48_000.0
        for frequency in [440.0, 1000.0] {
            let mailbox = TelemetryMailbox<TelemetryAudioPacket>()
            let analyzer = TelemetryAudioAnalyzer(mailbox: mailbox)
            let samples = (0..<2048).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
            analyzer.consume(samples, rate: rate)
            let packet = try XCTUnwrap(mailbox.take())
            XCTAssertEqual(try XCTUnwrap(packet.frequency), frequency, accuracy: rate / 2048)
            XCTAssertEqual(packet.rms, -9.0309, accuracy: 0.1)
            XCTAssertEqual(packet.peak, -6.0206, accuracy: 0.01)
        }
    }

    func testAnalyzerDoesNotMislabelDCOffsetAsAudiblePitch() throws {
        let mailbox = TelemetryMailbox<TelemetryAudioPacket>()
        let analyzer = TelemetryAudioAnalyzer(mailbox: mailbox)
        analyzer.consume([Float](repeating: 0.25, count: 2048), rate: 48_000)
        let packet = try XCTUnwrap(mailbox.take())
        XCTAssertEqual(packet.rms, -12.0412, accuracy: 0.002)
        XCTAssertEqual(packet.peak, -12.0412, accuracy: 0.002)
        XCTAssertNil(packet.frequency, "Digital DC level is real amplitude, but is not a periodic audible tone.")
    }

    func testAnalyzerMeasuresSineLevelAndFrequencyAcrossCallbackBlocks() throws {
        let mailbox = TelemetryMailbox<TelemetryAudioPacket>()
        let analyzer = TelemetryAudioAnalyzer(mailbox: mailbox, generation: 7)
        let rate = 48_000.0
        // Integer FFT-bin sine avoids leakage ambiguity without bypassing the real analyzer.
        let frequency = rate * 20 / 2048
        let signal = (0..<2048).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
        analyzer.consume(Array(signal.prefix(1024)), rate: rate)
        XCTAssertNil(mailbox.take(), "No incomplete-window measurement should escape the audio callback.")
        analyzer.consume(Array(signal.suffix(1024)), rate: rate)
        let packet = try XCTUnwrap(mailbox.take())
        XCTAssertEqual(packet.generation, 7)
        XCTAssertEqual(packet.sampleRate, rate)
        XCTAssertEqual(packet.rms, -9.0309, accuracy: 0.002)
        XCTAssertEqual(packet.peak, -6.0206, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(packet.frequency), frequency, accuracy: rate / 2048)
        XCTAssertFalse(packet.waveform.isEmpty)
        XCTAssertEqual(packet.spectrum.count, 48)
        XCTAssertTrue(packet.waveform.allSatisfy { $0.isFinite && abs($0) <= 0.5 })
        XCTAssertTrue(packet.spectrum.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertGreaterThan(packet.spectrum.max() ?? 0, 0)
        XCTAssertNil(mailbox.take(), "Consumed measurements must not be replayed as fresh audio.")
    }

    func testAnalyzerSilenceHasNoInventedFrequencyAndRejectsNonFiniteInput() throws {
        let mailbox = TelemetryMailbox<TelemetryAudioPacket>()
        let analyzer = TelemetryAudioAnalyzer(mailbox: mailbox)
        analyzer.consume([Float](repeating: 0, count: 2048), rate: 48_000)
        let silence = try XCTUnwrap(mailbox.take())
        XCTAssertEqual(silence.rms, -80)
        XCTAssertEqual(silence.peak, -80)
        XCTAssertNil(silence.frequency)
        XCTAssertTrue(silence.waveform.allSatisfy { $0 == 0 })
        analyzer.consume([Float](repeating: .nan, count: 2048), rate: 48_000)
        XCTAssertNil(mailbox.take())
        analyzer.consume([Float](repeating: 0, count: 2048), rate: .infinity)
        XCTAssertNil(mailbox.take())
        analyzer.consume([Float](repeating: 0, count: 2048), rate: 0)
        XCTAssertNil(mailbox.take())
        analyzer.consume([Float](repeating: 0, count: 2048), rate: 48_000)
        XCTAssertNil(try XCTUnwrap(mailbox.take()).frequency, "A rejected block must not corrupt the next complete analysis window.")
    }

    @MainActor
    func testRealAudioRenderCallbackProducesSignalRespondsToGainAndStops() async {
        let feedback = IOFeedback()
        defer { feedback.stopTone() }
        feedback.tone(frequency: 440, gain: 0.1)
        let rendered = await waitUntil { feedback.renderedFrameCount > 2048 && feedback.renderedPeak > 0.08 }
        XCTAssertTrue(rendered, feedback.error ?? "The actual AVAudioSourceNode callback did not render a nonzero signal.")
        XCTAssertNil(feedback.error)
        XCTAssertTrue(feedback.isToneRunning)
        XCTAssertLessThanOrEqual(feedback.renderedPeak, 0.101)
        let frequency440 = await measuredFrequency(feedback)
        XCTAssertEqual(frequency440, 440, accuracy: 5, "Frequency is measured from actual PCM zero crossings, independently of the command.")
        let frames = feedback.renderedFrameCount
        feedback.tone(frequency: 880, gain: 0.2)
        let adjusted = await waitUntil { feedback.renderedFrameCount > frames && feedback.renderedPeak > 0.18 }
        XCTAssertTrue(adjusted, "Gain changes must reach the running audio render callback.")
        XCTAssertLessThanOrEqual(feedback.renderedPeak, 0.201)
        let frequency880 = await measuredFrequency(feedback)
        XCTAssertEqual(frequency880, 880, accuracy: 5)
        feedback.tone(frequency: .nan, gain: .nan)
        let silent = await waitUntil { feedback.renderedPeak < 0.002 }
        XCTAssertTrue(silent, "Non-finite control values must render silence after the gain ramp.")
        feedback.stopTone()
        XCTAssertFalse(feedback.isToneRunning)
        let stoppedFrames = feedback.renderedFrameCount
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(feedback.renderedFrameCount, stoppedFrames, "Stopping must release the engine rather than merely hide its telemetry.")
    }

    @MainActor
    func testSimulatorHapticsReportsUnsupportedAndDoesNotClaimActuation() throws {
        #if targetEnvironment(simulator)
        let feedback = IOFeedback()
        XCTAssertFalse(feedback.supportsHaptics)
        XCTAssertFalse(feedback.pulse(intensity: 1))
        XCTAssertFalse(feedback.pulse(intensity: .nan))
        #else
        throw XCTSkip("Simulator capability behavior is separate from physical haptic feel.")
        #endif
    }

    @MainActor
    private func measuredFrequency(_ feedback: IOFeedback) async -> Double {
        let before = feedback.audioRenderSnapshot
        try? await Task.sleep(for: .milliseconds(250))
        let after = feedback.audioRenderSnapshot
        guard after.frames > before.frames, after.crossings >= before.crossings else { return 0 }
        return Double(after.crossings - before.crossings) * after.rate / (2 * Double(after.frames - before.frames))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
