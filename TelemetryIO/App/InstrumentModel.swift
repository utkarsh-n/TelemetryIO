import SwiftUI
import Observation

enum FieldMode: String, CaseIterable, Identifiable {
    case orbital = "Orbit", scope = "Scope", waterfall = "Waterfall"
    var id: String { rawValue }
    var symbol: String { switch self { case .orbital: "circle.hexagongrid"; case .scope: "waveform.path"; case .waterfall: "chart.bar.xaxis" } }
}

@MainActor @Observable final class InstrumentModel {
    let hub = TelemetryHub()
    var patches: [ModulationPatch] = [] {
        didSet {
            savePatches()
            if active && !paused { tick() }
            else { router.reset(); outputs.removeAll(); lastRoutingTime = nil }
        }
    }
    var outputs: [PatchTarget: Double] = [:]
    private(set) var orbitalMotion = OrbitalMotion()
    var soundEnabled = false {
        didSet {
            if !soundEnabled {
                feedback.stopTone(); outputError = nil
                hub.status("output.pitch", .off, detail: "Local oscillator is muted.")
                hub.status("output.level", .off, detail: "Local oscillator is muted.")
            } else if active && !paused { tick() }
        }
    }
    var hapticsEnabled = false {
        didSet {
            if !hapticsEnabled { hub.status("output.haptic", .off, detail: "Haptic output is muted.") }
            else if active && !paused { tick() }
        }
    }
    var gain = 1.0
    var timeWindow = 10.0
    var fieldMode: FieldMode = .orbital
    var selectedSignalID = "motion.intensity"
    var fieldRequest = 0
    var paused = false
    var touchPoint = CGPoint(x: 0.5, y: 0.5)
    var gestureActive = false
    var lastExport: URL?
    var exportError: String?
    var outputError: String?
    @ObservationIgnored private let feedback = IOFeedback()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var router = ModulationRouter()
    @ObservationIgnored private var lastRoutingTime: TimeInterval?
    @ObservationIgnored private var active = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "telemetry.patches.v1"), let saved = try? JSONDecoder().decode([ModulationPatch].self, from: data) {
            patches = ModulationRouter.sanitized(saved)
        } else {
            patches = [ModulationPatch(sourceID: "motion.intensity", target: .field), ModulationPatch(sourceID: "attitude.roll", target: .orbit)]
        }
    }
    var selected: SignalReading { hub.reading(selectedSignalID) }
    var liveCount: Int { hub.readings.values.filter { $0.status == .live }.count }
    var demoCount: Int { hub.readings.values.filter { $0.status == .demo }.count }
    var toneRunning: Bool { feedback.isToneRunning }
    var supportsHaptics: Bool { feedback.supportsHaptics }

    func start() {
        guard !active else { return }
        active = true
        lastRoutingTime = nil
        if !paused { hub.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func stop() {
        active = false; timer?.invalidate(); timer = nil; hub.stop()
        clearRouting(detail: "Capture stopped.")
    }
    func togglePause() {
        paused.toggle()
        if paused {
            hub.stop(); clearRouting(detail: "Capture paused.")
        } else if active {
            lastRoutingTime = nil; hub.start(); tick()
        }
    }
    func setDemo(_ value: Bool) {
        guard hub.isDemo != value else { return }
        clearRouting(detail: "Source mode changed."); hub.setDemo(value)
        if paused { hub.stop() }
        else if active { tick() }
    }
    func select(_ id: String) { if SignalCatalog.definition(id) != nil { selectedSignalID = id } }
    func showInField(_ id: String) {
        guard SignalCatalog.definition(id) != nil else { return }
        selectedSignalID = id; fieldRequest += 1
    }
    func touch(_ point: CGPoint, size: CGSize, ended: Bool = false) {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return }
        touchPoint = CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
        gestureActive = !ended
        if !paused { hub.recordTouch(x: touchPoint.x * 100, y: touchPoint.y * 100) }
    }
    func addPatch(sourceID: String, target: PatchTarget) {
        guard patches.count < 16, SignalCatalog.definition(sourceID) != nil,
              !patches.contains(where: { $0.sourceID == sourceID && $0.target == target }) else { return }
        patches.append(ModulationPatch(sourceID: sourceID, target: target))
        if !hub.isDemo, let permission = SignalCatalog.definition(sourceID)?.permission { hub.enable(permission) }
    }
    func removePatch(_ id: UUID) { patches.removeAll { $0.id == id } }
    func applyPreset(_ name: String) {
        let replacement: [ModulationPatch]
        let permission: String?
        switch name {
        case "Motion → field", "Motion":
            replacement = [ModulationPatch(sourceID: "motion.intensity", target: .field), ModulationPatch(sourceID: "attitude.roll", target: .orbit)]
            permission = "motion"
        case "Sound → orbit", "Sound":
            replacement = [ModulationPatch(sourceID: "mic.rms", target: .field), ModulationPatch(sourceID: "mic.frequency", target: .orbit)]
            permission = "microphone"
        case "Touch → tone", "Touch":
            replacement = [ModulationPatch(sourceID: "touch.x", target: .pitch), ModulationPatch(sourceID: "touch.y", target: .amplitude, inverted: true)]
            permission = nil; selectedSignalID = "touch.x"
        default: return
        }
        router.reset(); patches = replacement
        if !hub.isDemo, let permission { hub.enable(permission) }
    }
    func export() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TelemetryIO-\(Int(Date().timeIntervalSince1970)).csv")
            try hub.csv().write(to: url, atomically: true, encoding: .utf8)
            lastExport = url; exportError = nil
        } catch { exportError = error.localizedDescription }
    }
    /// Also callable by the simulator-host tests after publishing a deterministic source sample.
    func tick() {
        guard active, !paused else { return }
        guard hub.isRunning else { clearRouting(detail: "Capture stopped."); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastRoutingTime.map { max(0, now - $0) } ?? 0
        lastRoutingTime = now
        let result = router.evaluate(patches: patches, readings: hub.readings, dt: dt)
        let values = result.values
        outputs = values
        orbitalMotion.advance(orbit: values[.orbit] ?? 0.2, dt: dt)
        let tone = result.tone
        if soundEnabled, let tone { feedback.tone(frequency: tone.frequency, gain: tone.gain, recording: hub.microphoneActive) }
        else { feedback.suspendTone() }
        outputError = soundEnabled ? feedback.error : nil
        let haptic = values[.haptic] ?? 0
        if hapticsEnabled && feedback.supportsHaptics && haptic > 0.1 { feedback.pulse(intensity: haptic) }
        if soundEnabled, let tone, feedback.isToneRunning {
            hub.publish("output.pitch", value: tone.frequency, detail: "Commanded audio oscillator frequency")
            hub.publish("output.level", value: tone.gain * 100, detail: "Commanded oscillator gain")
        } else {
            let status: SignalStatus = soundEnabled && feedback.error != nil ? .unavailable : .off
            let detail = feedback.error ?? (soundEnabled ? "Connect a tone route with an available input." : "Local oscillator is muted.")
            hub.status("output.pitch", status, detail: detail)
            hub.status("output.level", status, detail: detail)
        }
        if hapticsEnabled && !feedback.supportsHaptics {
            hub.status("output.haptic", .unavailable, detail: "This runtime has no haptic output hardware.")
        } else if hapticsEnabled { hub.publish("output.haptic", value: haptic * 100, detail: "Requested haptic drive") }
        else { hub.status("output.haptic", .off, detail: "Haptic output is muted.") }
    }
    private func clearRouting(detail: String) {
        feedback.stopTone(); router.reset(); outputs.removeAll(); lastRoutingTime = nil
        outputError = nil; gestureActive = false
        for id in ["output.pitch", "output.level", "output.haptic"] { hub.status(id, .off, detail: detail) }
    }
    private func savePatches() {
        if let data = try? JSONEncoder().encode(patches) { UserDefaults.standard.set(data, forKey: "telemetry.patches.v1") }
    }
}
