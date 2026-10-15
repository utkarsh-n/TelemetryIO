import AVFoundation
import CoreHaptics
import Synchronization
import UIKit

struct AudioRenderSnapshot: Equatable, Sendable {
    let frames: UInt64
    let crossings: UInt64
    let rate: Double
    let peak: Double
}

private final class OscillatorControl: @unchecked Sendable {
    private let frequency = Atomic<Double>(220)
    private let gain = Atomic<Double>(0)
    private let frames = Atomic<UInt64>(0)
    private let peak = Atomic<Double>(0)
    private let crossings = Atomic<UInt64>(0)
    private let rate = Atomic<Double>(0)
    private let diagnosticSequence = Atomic<UInt64>(0)
    func set(frequency: Double, gain: Double) {
        self.frequency.store(frequency, ordering: .relaxed)
        self.gain.store(gain, ordering: .relaxed)
    }
    func get() -> (Double, Double) { (frequency.load(ordering: .relaxed), gain.load(ordering: .relaxed)) }
    var renderedFrameCount: UInt64 { frames.load(ordering: .relaxed) }
    var renderedPeak: Double { peak.load(ordering: .relaxed) }
    func resetDiagnostics() {
        let sequence = diagnosticSequence.load(ordering: .relaxed)
        diagnosticSequence.store(sequence &+ 1, ordering: .sequentiallyConsistent)
        frames.store(0, ordering: .relaxed); peak.store(0, ordering: .relaxed)
        crossings.store(0, ordering: .relaxed); rate.store(0, ordering: .relaxed)
        diagnosticSequence.store(sequence &+ 2, ordering: .sequentiallyConsistent)
    }
    func didRender(frames count: UInt64, peak blockPeak: Double) {
        frames.store(frames.load(ordering: .relaxed) &+ count, ordering: .relaxed)
        peak.store(blockPeak, ordering: .relaxed)
    }
    func didRenderBlock(frames count: UInt64, crossings countCrossings: UInt64, rate sampleRate: Double, peak blockPeak: Double) {
        let sequence = diagnosticSequence.load(ordering: .relaxed)
        diagnosticSequence.store(sequence &+ 1, ordering: .sequentiallyConsistent)
        crossings.store(crossings.load(ordering: .relaxed) &+ countCrossings, ordering: .relaxed)
        rate.store(sampleRate, ordering: .relaxed)
        didRender(frames: count, peak: blockPeak)
        diagnosticSequence.store(sequence &+ 2, ordering: .sequentiallyConsistent)
    }
    /// Only readers retry. The render thread publishes four scalars without spinning or locking.
    func snapshot() -> AudioRenderSnapshot? {
        for _ in 0..<8 {
            let before = diagnosticSequence.load(ordering: .sequentiallyConsistent)
            if before & 1 != 0 { continue }
            let snapshot = AudioRenderSnapshot(frames: frames.load(ordering: .relaxed), crossings: crossings.load(ordering: .relaxed), rate: rate.load(ordering: .relaxed), peak: peak.load(ordering: .relaxed))
            if diagnosticSequence.load(ordering: .sequentiallyConsistent) == before { return snapshot }
        }
        return nil
    }
}

@MainActor final class IOFeedback {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private let control = OscillatorControl()
    private var lastPulse = -Double.infinity
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private let audioSession = AudioSessionCoordinator.shared
    private let audioOwner = UUID()
    private var audioReservation: AudioSessionCoordinator.Reservation?
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0
    private(set) var error: String?
    var isToneRunning: Bool { engine?.isRunning == true }
    var isToneStarting: Bool { startTask != nil }
    var renderedFrameCount: UInt64 { control.renderedFrameCount }
    var renderedPeak: Double { control.renderedPeak }
    private var lastRenderSnapshot = AudioRenderSnapshot(frames: 0, crossings: 0, rate: 0, peak: 0)
    var audioRenderSnapshot: AudioRenderSnapshot {
        if let snapshot = control.snapshot() { lastRenderSnapshot = snapshot }
        return lastRenderSnapshot
    }
    var renderedZeroCrossingCount: UInt64 { audioRenderSnapshot.crossings }
    var renderedSampleRate: Double { audioRenderSnapshot.rate }
    var supportsHaptics: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #endif
    }
    private var canResumeAudio = true
    private var configurationObserver: (any NSObjectProtocol)?
    private var sessionObservers: [NotificationCenter.ObservationToken] = []

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(of: session, for: .didBecomeInactive) { [weak self] (message: AVAudioSession.DidBecomeInactiveMessage) in
            guard let self else { return }
            guard case .systemInterruption = message.deactivationResult else { return }
            self.canResumeAudio = false
            self.suspendTone()
        })
        sessionObservers.append(center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] (message: AVAudioSession.ResumptionRecommendationMessage) in
            self?.canResumeAudio = message.recommendation == .shouldResume
        })
    }

    isolated deinit { cancelToneStart() }

    func tone(frequency: Double, gain: Double, recording: Bool = false) {
        control.set(frequency: frequency.isFinite ? min(1600, max(80, frequency)) : 220, gain: gain.isFinite ? min(0.25, max(0, gain)) : 0)
        guard error == nil, canResumeAudio else { return }
        if engine?.isRunning != true {
            teardownEngine()
            startTone(recording: recording)
        }
    }
    private func startTone(recording: Bool) {
        guard startTask == nil else { return }
        startGeneration += 1
        let generation = startGeneration
        let reservation = audioReservation ?? audioSession.reserve(owner: audioOwner, recording: recording)
        audioReservation = reservation
        startTask = Task { [weak self, audioSession] in
            do {
                let activated = try await audioSession.waitUntilActive(reservation)
                guard let self, self.startGeneration == generation, !Task.isCancelled else { return }
                self.startTask = nil
                guard activated, self.canResumeAudio, self.error == nil else { return }
                try self.buildToneEngine()
            } catch {
                guard let self, self.startGeneration == generation, !Task.isCancelled else { return }
                self.startTask = nil
                self.error = error.localizedDescription
                self.teardownEngine()
                audioSession.release(reservation)
                self.audioReservation = nil
            }
        }
    }

    private func buildToneEngine() throws {
        let session = AVAudioSession.sharedInstance()
        let audio = AVAudioEngine()
        let rate = session.sampleRate > 0 ? session.sampleRate : 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let node = Self.makeSource(control: control, sampleRate: rate)
        audio.attach(node); try audio.connectNode(node, to: audio.mainMixerNode, format: format)
        control.resetDiagnostics()
        try audio.start()
        source = node; engine = audio; error = nil
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVAudioEngine === self.engine else { return }
                self.teardownEngine()
            }
        }
    }

    /// Construct the render callback outside MainActor; it runs on the hardware audio thread.
    nonisolated private static func makeSource(control: OscillatorControl, sampleRate: Double) -> AVAudioSourceNode {
        var phase = 0.0
        var smoothGain = 0.0
        var previousSample: Float = 0
        return AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let (frequency, gain) = control.get()
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            var blockPeak = 0.0
            var blockCrossings: UInt64 = 0
            for frame in 0..<Int(frameCount) {
                smoothGain += (gain - smoothGain) * 0.002
                let sample = Float(sin(phase) * smoothGain)
                blockPeak = max(blockPeak, abs(Double(sample)))
                if (previousSample > 0 && sample <= 0) || (previousSample < 0 && sample >= 0) { blockCrossings &+= 1 }
                previousSample = sample
                phase += 2 * .pi * frequency / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
            }
            control.didRenderBlock(frames: UInt64(frameCount), crossings: blockCrossings, rate: sampleRate, peak: blockPeak)
            return noErr
        }
    }

    private func teardownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if let source { engine?.detach(source) }
        engine = nil; source = nil
    }

    private func cancelToneStart() {
        startGeneration += 1
        startTask?.cancel(); startTask = nil
        teardownEngine()
        if let audioReservation { audioSession.release(audioReservation) }
        audioReservation = nil
    }

    func stopTone() {
        control.set(frequency: 220, gain: 0)
        cancelToneStart(); error = nil; canResumeAudio = true
    }
    /// Automatic source loss must not clear an interruption or turn a failed route
    /// into a 20 Hz activation retry loop. Explicit mute/pause uses stopTone().
    func suspendTone() {
        control.set(frequency: 220, gain: 0)
        cancelToneStart()
    }
    @discardableResult func pulse(intensity: Double) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard supportsHaptics, intensity.isFinite, intensity > 0, now - lastPulse > 0.4 else { return false }
        lastPulse = now
        haptic.prepare(); haptic.impactOccurred(intensity: min(1, intensity))
        return true
    }
}
