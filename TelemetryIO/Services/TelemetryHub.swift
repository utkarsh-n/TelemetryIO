import AVFoundation
import CoreBluetooth
import CoreLocation
import CoreMotion
import CoreTelephony
import Foundation
import Network
import Observation
import UIKit

struct BLEObservation: Identifiable, Sendable {
    let id: UUID
    var name: String
    var rssi: Double
    var lastSeen: Double
}

struct TelemetryEvent: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
}

/// Live transport. Permissions are requested only by an explicit enable action.
/// Hardware callbacks feed bounded mailboxes; observable state refreshes at 20 Hz.
@MainActor @Observable
final class TelemetryHub: NSObject {
    private(set) var readings: [String: SignalReading] = [:]
    private(set) var bleDevices: [BLEObservation] = []
    private(set) var waveform: [Double] = []
    private(set) var spectrum: [Double] = []
    private(set) var elapsed = 0.0
    private(set) var isDemo = false
    private(set) var isRunning = false
    private(set) var enabled: Set<String> = []
    private(set) var routeDescription = "System audio"
    private(set) var events: [TelemetryEvent] = []
    var microphoneActive: Bool { audioEngine?.isRunning == true }
    var microphoneStarting: Bool { microphoneStartTask != nil }
    var nearbyProbe: NearbyProbe { nearby }

    @ObservationIgnored private var motion: CMMotionManager?
    @ObservationIgnored private var altimeter: CMAltimeter?
    @ObservationIgnored private var pedometer: CMPedometer?
    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private let sensorQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "TelemetryIO.motion"; queue.maxConcurrentOperationCount = 1; return queue
    }()
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var telephony: CTTelephonyNetworkInfo?
    @ObservationIgnored private var ratToken: NotificationCenter.ObservationToken?
    @ObservationIgnored private var notifications: [any NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clock = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var lastSlowUpdate = -Double.infinity
    @ObservationIgnored private var lastMotionTimestamp: [String: TimeInterval] = [:]
    @ObservationIgnored private var bleByID: [UUID: BLEObservation] = [:]
    @ObservationIgnored private var advertisementTimes: [Double] = []
    @ObservationIgnored private let audioMailbox = TelemetryMailbox<TelemetryAudioPacket>()
    @ObservationIgnored private let cameraMailbox = TelemetryMailbox<TelemetryCameraPacket>()
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var audioAnalyzer: TelemetryAudioAnalyzer?
    @ObservationIgnored private let audioSession = AudioSessionCoordinator.shared
    @ObservationIgnored private let microphoneOwner = UUID()
    @ObservationIgnored private var microphoneReservation: AudioSessionCoordinator.Reservation?
    @ObservationIgnored private var microphoneStartTask: Task<Void, Never>?
    @ObservationIgnored private var cameraCapture: TelemetryCameraCapture?
    @ObservationIgnored private let traffic = InterfaceTraffic()
    @ObservationIgnored private let nfc = NFCProbe()
    @ObservationIgnored private let nearby = NearbyProbe()
    @ObservationIgnored private var demoBLEIDs = (0..<5).map { _ in UUID() }
    @ObservationIgnored private var sessionStarted = Date()
    @ObservationIgnored private var recorded: [String: [(time: Double, value: Double, mode: String)]] = [:]
    @ObservationIgnored private var pendingRequests: Set<String> = []
    @ObservationIgnored private var audioTokens: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var microphoneRequestPending = false
    @ObservationIgnored private var cameraRequestPending = false
    @ObservationIgnored private var trafficHasBaseline = false
    @ObservationIgnored private var microphoneCanResume = true
    @ObservationIgnored private var microphoneEpoch = 0
    @ObservationIgnored private var cameraEpoch = 0
    @ObservationIgnored private var waitingSince: [String: Double] = [:]

    override init() {
        super.init()
        for definition in SignalCatalog.all {
            var reading = SignalReading(definition: definition)
            if definition.permission != nil { reading.status = .permission; reading.detail = "Enable this source to begin." }
            if definition.permission == "peer" { reading.status = .waiting; reading.detail = "A participating Nearby Interaction peer is required." }
            readings[definition.id] = reading
        }
        #if targetEnvironment(simulator)
        for permission in ["motion", "barometer", "steps", "camera", "bluetooth", "proximity", "nfc", "peer"] {
            mark(permission, .unavailable, "This hardware source is unavailable in iOS Simulator. Use an iPhone to measure it.")
        }
        #endif
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.headingFilter = kCLHeadingFilterNone
        nfc.onRead = { [weak self] count, summary in
            guard let self, self.isRunning, !self.isDemo, self.enabled.contains("nfc") else { return }
            self.publish("nfc.reads", value: Double(count), detail: summary)
            self.event("NFC tag read", detail: summary)
        }
        nearby.onUpdate = { [weak self] distance, direction, detail in
            guard let self, self.isRunning, !self.isDemo, self.enabled.contains("peer") else { return }
            if let distance { self.publish("uwb.distance", value: distance, detail: detail) }
            else { self.status("uwb.distance", self.nearby.supported ? .waiting : .unavailable, detail: detail) }
            if let direction {
                self.publish("uwb.direction.x", value: Double(direction.x), detail: detail)
                self.publish("uwb.direction.y", value: Double(direction.y), detail: detail)
                self.publish("uwb.direction.z", value: Double(direction.z), detail: detail)
            } else {
                for axis in ["x", "y", "z"] { self.status("uwb.direction.\(axis)", self.nearby.supported ? .waiting : .unavailable, detail: "No peer direction is currently supplied.") }
            }
        }
    }

    isolated deinit {
        isRunning = false
        timer?.invalidate()
        stopHardware()
    }

    func reading(_ id: String) -> SignalReading {
        if let reading = readings[id] { return reading }
        let definition = SignalCatalog.definition(id) ?? SignalDefinition(id, id, .device, "", 0...1, "questionmark", "Unknown signal.", "Unavailable")
        return SignalReading(definition: definition)
    }

    func publish(_ id: String, value: Double, status: SignalStatus = .live, detail: String = "") {
        guard value.isFinite, var reading = readings[id] else { return }
        reading.append(value, at: elapsed, status: status)
        waitingSince.removeValue(forKey: id)
        reading.detail = detail
        readings[id] = reading
        var capture = recorded[id] ?? []
        capture.append((elapsed, value, status == .demo ? "DEMO" : "LIVE"))
        if capture.count > 600 { capture.removeFirst(capture.count - 600) }
        recorded[id] = capture
    }

    func status(_ id: String, _ status: SignalStatus, detail: String = "") {
        guard var reading = readings[id] else { return }
        if status == .waiting {
            if reading.status != .waiting || waitingSince[id] == nil { waitingSince[id] = elapsed }
        } else { waitingSince.removeValue(forKey: id) }
        // Muted outputs can report the same state every routing tick. Keep their
        // waiting bookkeeping above without invalidating every live signal view.
        guard reading.status != status || reading.detail != detail || (!status.hasData && reading.value != nil) else { return }
        reading.status = status; reading.detail = detail
        if !status.hasData { reading.value = nil }
        readings[id] = reading
    }

    func event(_ title: String, detail: String = "") {
        events.insert(TelemetryEvent(date: Date(), title: title, detail: detail), at: 0)
        if events.count > 80 { events.removeLast(events.count - 80) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true; epoch += 1
        clock = ProcessInfo.processInfo.systemUptime - elapsed
        lastSlowUpdate = -Double.infinity
        if isDemo {
            event("Demo resumed", detail: "All generated sensor values are marked DEMO.")
        } else {
            startPassive()
            for permission in enabled where permission != "nfc" { begin(permission, request: pendingRequests.contains(permission)) }
            pendingRequests.removeAll()
            event("Live session", detail: "Passive device and network readings started. Enable sources individually.")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false; epoch += 1
        timer?.invalidate(); timer = nil
        stopHardware()
        for id in readings.keys where readings[id]?.status.hasData == true { status(id, .stale, detail: "Capture paused.") }
        event("Session paused", detail: "Hardware capture and scanning stopped.")
    }

    func setDemo(_ value: Bool) {
        guard isDemo != value else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        isDemo = value
        bleDevices = []; bleByID = [:]; waveform = []; spectrum = []
        for id in readings.keys {
            status(id, .off, detail: value ? "Explicit demo mode." : "Live source has not delivered a sample.")
            readings[id]?.samples.removeAll()
        }
        for definition in SignalCatalog.all where definition.permission != nil && !enabled.contains(definition.permission!) {
            status(definition.id, definition.permission == "peer" ? .waiting : .permission, detail: "Enable this source to begin.")
        }
        #if targetEnvironment(simulator)
        if !value {
            for permission in ["motion", "barometer", "steps", "camera", "bluetooth", "proximity", "nfc", "peer"] {
                mark(permission, .unavailable, "This hardware source is unavailable in iOS Simulator. Use an iPhone to measure it.")
            }
        }
        #endif
        event(value ? "Demo enabled" : "Live mode enabled", detail: value ? "Synthetic values are clearly marked DEMO." : "Only measured values will be shown.")
        if wasRunning { start() }
    }

    func enable(_ permission: String) {
        enabled.insert(permission)
        guard isRunning else {
            pendingRequests.insert(permission)
            mark(permission, .waiting, "Resume capture to enable this source."); return
        }
        guard !isDemo else { event("Demo source enabled", detail: permission.capitalized); return }
        begin(permission, request: true)
    }

    func disable(_ permission: String) {
        enabled.remove(permission)
        pendingRequests.remove(permission)
        switch permission {
        case "motion": motion?.stopDeviceMotionUpdates(); motion?.stopAccelerometerUpdates(); motion?.stopGyroUpdates(); motion?.stopMagnetometerUpdates(); lastMotionTimestamp = [:]
        case "barometer": altimeter?.stopRelativeAltitudeUpdates()
        case "steps": pedometer?.stopUpdates()
        case "location": location.stopUpdatingLocation(); location.stopUpdatingHeading()
        case "microphone": stopMicrophone()
        case "camera": cameraEpoch += 1; cameraCapture?.stop(); cameraMailbox.clear()
        case "bluetooth": central?.stopScan(); central?.delegate = nil; central = nil; bleByID = [:]; bleDevices = []; advertisementTimes = []
        case "proximity": UIDevice.current.isProximityMonitoringEnabled = false
        case "nfc": nfc.stop()
        case "peer": nearby.stop()
        default: break
        }
        mark(permission, .off, "Source disabled.")
        event("Source disabled", detail: permission.capitalized)
    }

    func recordTouch(x: Double, y: Double) {
        guard isRunning else { return }
        publish("touch.x", value: min(100, max(0, x)))
        publish("touch.y", value: min(100, max(0, y)))
    }

    private func mark(_ permission: String, _ state: SignalStatus, _ detail: String) {
        for definition in SignalCatalog.all where definition.permission == permission { status(definition.id, state, detail: detail) }
    }

    private func begin(_ permission: String, request: Bool) {
        #if targetEnvironment(simulator)
        if ["motion", "barometer", "steps", "camera", "bluetooth", "proximity", "nfc", "peer"].contains(permission) {
            mark(permission, .unavailable, "This hardware source is unavailable in iOS Simulator. Use an iPhone to measure it.")
            return
        }
        #endif
        switch permission {
        case "motion": startMotion()
        case "barometer": startBarometer(request: request)
        case "steps": startPedometer(request: request)
        case "location": startLocation(request: request)
        case "microphone": startMicrophone(request: request)
        case "camera": startCamera(request: request)
        case "bluetooth": startBluetooth(request: request)
        case "proximity":
            UIDevice.current.isProximityMonitoringEnabled = true
            if UIDevice.current.isProximityMonitoringEnabled { publish("device.proximity", value: UIDevice.current.proximityState ? 1 : 0) }
            else { mark(permission, .unavailable, "This device does not expose a proximity sensor.") }
        case "nfc":
            guard request else { return }
            if nfc.isAvailable { nfc.start(); mark(permission, .waiting, "Hold an NDEF tag near the top of your iPhone.") }
            else { mark(permission, .unavailable, "NFC tag reading is unavailable on this device.") }
        case "peer":
            guard nearby.supported else { mark(permission, .unavailable, "Nearby Interaction ranging is unsupported on this device."); return }
            if request { nearby.prepare() }
            mark(permission, .waiting, "Exchange discovery tokens with a participating nearby peer.")
        default: break
        }
    }

    private func tick() {
        guard isRunning else { return }
        elapsed = max(0, ProcessInfo.processInfo.systemUptime - clock)
        if isDemo { demoTick(); return }
        if enabled.contains("motion") { sampleMotion() }
        if enabled.contains("microphone"), let packet = audioMailbox.take(), packet.generation == microphoneEpoch {
            publish("mic.rms", value: packet.rms); publish("mic.peak", value: packet.peak)
            if let frequency = packet.frequency { publish("mic.frequency", value: frequency, detail: "Strongest FFT bin; not a pitch guarantee.") }
            else { status("mic.frequency", .waiting, detail: "No reliable dominant frequency at this level.") }
            publish("audio.sampleRate", value: packet.sampleRate)
            waveform = packet.waveform; spectrum = packet.spectrum
        }
        if enabled.contains("camera"), let packet = cameraMailbox.take(), packet.generation == cameraEpoch {
            publish("camera.red", value: packet.red); publish("camera.green", value: packet.green); publish("camera.blue", value: packet.blue)
            publish("camera.luma", value: packet.luma); publish("camera.iso", value: packet.iso); publish("camera.exposure", value: packet.exposure)
        }
        if elapsed - lastSlowUpdate >= 1 {
            lastSlowUpdate = elapsed
            sampleDevice(); sampleTelephony()
            if enabled.contains("bluetooth") { sampleBluetooth() }
            if enabled.contains("nfc") {
                if let error = nfc.error { status("nfc.reads", .unavailable, detail: error) }
                else if !nfc.isReading, reading("nfc.reads").status == .waiting { status("nfc.reads", .off, detail: "Tap NFC again to start a tag-read session.") }
            }
            let interfaces = traffic.sample(now: elapsed)
            if !interfaces.isEmpty {
                if trafficHasBaseline {
                    let names = interfaces.map(\.name).joined(separator: ", ")
                    publish("network.rx", value: interfaces.reduce(0) { $0 + $1.rxRate }, detail: "Whole-interface receive counters: \(names).")
                    publish("network.tx", value: interfaces.reduce(0) { $0 + $1.txRate }, detail: "Whole-interface transmit counters: \(names).")
                } else {
                    status("network.rx", .waiting, detail: "Building an interface-counter baseline.")
                    status("network.tx", .waiting, detail: "Building an interface-counter baseline.")
                    trafficHasBaseline = true
                }
            } else {
                trafficHasBaseline = false
                status("network.rx", .waiting, detail: "Waiting for active interface counters.")
                status("network.tx", .waiting, detail: "Waiting for active interface counters.")
            }
            // Settings, network paths, NFC reads and step counts represent event-driven state.
            for definition in SignalCatalog.all where ["motion", "barometer", "microphone", "camera", "location", "peer"].contains(definition.permission ?? "") || definition.id == "steps.cadence" {
                guard var reading = readings[definition.id] else { continue }
                let timeout = definition.permission == "location" ? 15.0 : definition.permission == "barometer" || definition.id == "steps.cadence" ? 10.0 : 3.0
                let wasLive = reading.status == .live
                reading.markStale(now: elapsed, after: timeout)
                if wasLive, reading.status == .stale { reading.detail = "No fresh sensor callback for more than \(Int(timeout)) seconds." }
                readings[definition.id] = reading
            }
            // Continuous sensors must not stay "waiting" forever after a successful
            // start API that never delivers a buffer. Event-driven sources are exempt.
            for definition in SignalCatalog.all where ["motion", "barometer", "microphone", "camera"].contains(definition.permission ?? "") {
                guard let permission = definition.permission, enabled.contains(permission), readings[definition.id]?.status == .waiting, let started = waitingSince[definition.id] else { continue }
                if definition.id == "mic.frequency" { continue } // Silence has no reliable frequency.
                let timeout = permission == "barometer" ? 15.0 : 5.0
                if elapsed - started > timeout {
                    status(definition.id, .unavailable, detail: "No measurements arrived after this source started. Try disabling and enabling it again.")
                }
            }
        }
    }

    private func startMotion() {
        let motion = motion ?? CMMotionManager()
        self.motion = motion
        mark("motion", .waiting, "Waiting for Core Motion samples.")
        let interval = 1.0 / 30.0
        motion.accelerometerUpdateInterval = interval; motion.gyroUpdateInterval = interval
        motion.magnetometerUpdateInterval = interval; motion.deviceMotionUpdateInterval = interval
        if motion.isAccelerometerAvailable { motion.startAccelerometerUpdates() }
        else { for axis in ["x", "y", "z"] { status("accel.\(axis)", .unavailable, detail: "Accelerometer unavailable.") } }
        if motion.isGyroAvailable { motion.startGyroUpdates() }
        else { for axis in ["x", "y", "z"] { status("gyro.\(axis)", .unavailable, detail: "Gyroscope unavailable.") } }
        if motion.isMagnetometerAvailable { motion.startMagnetometerUpdates() }
        else { for id in ["mag.x", "mag.y", "mag.z", "mag.total"] { status(id, .unavailable, detail: "Magnetometer unavailable.") } }
        if motion.isDeviceMotionAvailable {
            let available = CMMotionManager.availableAttitudeReferenceFrames()
            let frame: CMAttitudeReferenceFrame = available.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
            motion.startDeviceMotionUpdates(using: frame)
        } else {
            for definition in SignalCatalog.all where definition.id.hasPrefix("gravity.") || definition.id.hasPrefix("userAccel.") || definition.id.hasPrefix("attitude.") || definition.id == "motion.intensity" {
                status(definition.id, .unavailable, detail: "Fused device motion unavailable.")
            }
        }
        event("Motion enabled", detail: "Native sensors run at 30 Hz; the display samples at 20 Hz.")
    }

    private func newMotion(_ stream: String, timestamp: Double) -> Bool {
        guard lastMotionTimestamp[stream] != timestamp else { return false }
        lastMotionTimestamp[stream] = timestamp; return true
    }

    private func sampleMotion() {
        guard let motion else { return }
        if let data = motion.accelerometerData, newMotion("accel", timestamp: data.timestamp) {
            publish("accel.x", value: data.acceleration.x); publish("accel.y", value: data.acceleration.y); publish("accel.z", value: data.acceleration.z)
        }
        if let data = motion.gyroData, newMotion("gyro", timestamp: data.timestamp) {
            publish("gyro.x", value: data.rotationRate.x); publish("gyro.y", value: data.rotationRate.y); publish("gyro.z", value: data.rotationRate.z)
        }
        if let data = motion.magnetometerData, newMotion("mag", timestamp: data.timestamp) {
            let field = data.magneticField
            publish("mag.x", value: field.x); publish("mag.y", value: field.y); publish("mag.z", value: field.z)
            publish("mag.total", value: sqrt(field.x * field.x + field.y * field.y + field.z * field.z))
        }
        if let data = motion.deviceMotion, newMotion("deviceMotion", timestamp: data.timestamp) {
            let gravity = data.gravity, acceleration = data.userAcceleration
            publish("gravity.x", value: gravity.x); publish("gravity.y", value: gravity.y); publish("gravity.z", value: gravity.z)
            publish("userAccel.x", value: acceleration.x); publish("userAccel.y", value: acceleration.y); publish("userAccel.z", value: acceleration.z)
            let toDegrees = 180.0 / Double.pi
            publish("attitude.roll", value: data.attitude.roll * toDegrees); publish("attitude.pitch", value: data.attitude.pitch * toDegrees); publish("attitude.yaw", value: data.attitude.yaw * toDegrees)
            publish("motion.intensity", value: sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z))
        }
    }

    private func startBarometer(request: Bool) {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { mark("barometer", .unavailable, "This device has no accessible barometer."); return }
        let auth = CMAltimeter.authorizationStatus()
        guard auth != .denied && auth != .restricted else { mark("barometer", .restricted, "Motion & Fitness access is denied in Settings."); return }
        guard request || auth == .authorized else { mark("barometer", .permission, "Enable to request Motion & Fitness access."); return }
        mark("barometer", .waiting, "Waiting for pressure measurements.")
        let altimeter = altimeter ?? CMAltimeter()
        self.altimeter = altimeter
        let epoch = epoch
        altimeter.startRelativeAltitudeUpdates(to: sensorQueue) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.epoch == epoch, self.enabled.contains("barometer") else { return }
                if let error { self.mark("barometer", .unavailable, error.localizedDescription); return }
                if let data { self.publish("pressure", value: data.pressure.doubleValue); self.publish("altitude.relative", value: data.relativeAltitude.doubleValue) }
            }
        }
    }

    private func startPedometer(request: Bool) {
        guard CMPedometer.isStepCountingAvailable() else { mark("steps", .unavailable, "Step counting is unavailable."); return }
        let auth = CMPedometer.authorizationStatus()
        guard auth != .denied && auth != .restricted else { mark("steps", .restricted, "Motion & Fitness access is denied in Settings."); return }
        guard request || auth == .authorized else { mark("steps", .permission, "Enable to request Motion & Fitness access."); return }
        mark("steps", .waiting, "Walk a few steps to begin.")
        let pedometer = pedometer ?? CMPedometer()
        self.pedometer = pedometer
        let epoch = epoch
        pedometer.startUpdates(from: sessionStarted) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.epoch == epoch, self.enabled.contains("steps") else { return }
                if let error { self.mark("steps", .unavailable, error.localizedDescription); return }
                guard let data else { return }
                self.publish("steps.count", value: data.numberOfSteps.doubleValue)
                if let cadence = data.currentCadence { self.publish("steps.cadence", value: cadence.doubleValue) }
                else { self.status("steps.cadence", .waiting, detail: "Current cadence is not supplied.") }
                if let distance = data.distance { self.publish("steps.distance", value: distance.doubleValue) }
                else { self.status("steps.distance", .unavailable, detail: "Walking distance is not supplied.") }
            }
        }
    }

    private func startLocation(request: Bool) {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            mark("location", .waiting, "Waiting for a location fix.")
            location.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
            else { status("location.heading", .unavailable, detail: "Compass heading unavailable.") }
        case .notDetermined:
            mark("location", request ? .waiting : .permission, "Enable Location to request access.")
            if request { location.requestWhenInUseAuthorization() }
        case .restricted, .denied: mark("location", .restricted, "Location access is denied in Settings.")
        @unknown default: mark("location", .unavailable, "Location authorization is unavailable.")
        }
    }

    private func startMicrophone(request: Bool) {
        guard audioEngine == nil, microphoneStartTask == nil else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .denied: mark("microphone", .restricted, "Microphone access is denied in Settings.")
        case .undetermined:
            guard request else { mark("microphone", .permission, "Enable to request microphone access."); return }
            guard !microphoneRequestPending else { return }
            microphoneRequestPending = true
            mark("microphone", .waiting, "Requesting microphone access.")
            let epoch = epoch
            Task { [weak self] in
                let granted = await AVAudioApplication.requestRecordPermission()
                self?.microphoneRequestPending = false
                guard let self, self.isRunning, !self.isDemo, self.epoch == epoch, self.enabled.contains("microphone") else { return }
                if granted { self.beginAudioEngine() }
                else { self.mark("microphone", .restricted, "Microphone access is denied in Settings.") }
            }
        case .granted: beginAudioEngine()
        @unknown default: mark("microphone", .unavailable, "Microphone authorization unavailable.")
        }
    }

    private func beginAudioEngine() {
        guard isRunning, !isDemo, enabled.contains("microphone"), audioEngine == nil, microphoneStartTask == nil, microphoneCanResume else { return }
        microphoneEpoch += 1
        let generation = microphoneEpoch
        let captureEpoch = epoch
        // Reserve synchronously, before an oscillator can request a playback category.
        let reservation = audioSession.reserve(owner: microphoneOwner, recording: true)
        microphoneReservation = reservation
        mark("microphone", .waiting, "Activating the microphone audio session.")
        microphoneStartTask = Task { [weak self, audioSession] in
            do {
                let activated = try await audioSession.waitUntilActive(reservation)
                guard let self, self.microphoneEpoch == generation, self.epoch == captureEpoch, !Task.isCancelled else { return }
                guard activated, self.isRunning, !self.isDemo, self.enabled.contains("microphone"), self.microphoneCanResume else { return }
                try await self.installMicrophoneEngineWhenReady(generation: generation, captureEpoch: captureEpoch)
                guard self.microphoneEpoch == generation, self.epoch == captureEpoch, !Task.isCancelled else { return }
                self.microphoneStartTask = nil
            } catch {
                guard let self, self.microphoneEpoch == generation, self.epoch == captureEpoch, !Task.isCancelled else { return }
                self.microphoneStartTask = nil
                self.mark("microphone", .unavailable, error.localizedDescription)
                audioSession.release(reservation)
                self.microphoneReservation = nil
            }
        }
    }

    private func installMicrophoneEngineWhenReady(generation: Int, captureEpoch: Int) async throws {
        let delays: [Duration] = [.zero, .milliseconds(40), .milliseconds(100), .milliseconds(200), .milliseconds(350)]
        for (attempt, delay) in delays.enumerated() {
            if delay != .zero { try await Task.sleep(for: delay) }
            guard !Task.isCancelled, microphoneEpoch == generation, epoch == captureEpoch, isRunning, !isDemo, enabled.contains("microphone"), microphoneCanResume else { throw CancellationError() }
            do {
                // A fresh RemoteIO is required after a zero-format attempt; reusing
                // the failed input node would retain that disabled hardware bus.
                try installMicrophoneEngine(generation: generation)
                return
            } catch {
                let failure = error as NSError
                let session = AVAudioSession.sharedInstance()
                guard failure.domain == "TelemetryIO.Audio", failure.code == 1,
                      attempt < delays.count - 1, session.sampleRate.isFinite, session.sampleRate > 0,
                      session.inputNumberOfChannels > 0, !session.currentRoute.inputs.isEmpty else { throw error }
                mark("microphone", .waiting, "Waiting for Core Audio to supply the microphone hardware format.")
            }
        }
    }

    private func installMicrophoneEngine(generation: Int) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate.isFinite, hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            let session = AVAudioSession.sharedInstance()
            let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ", ")
            let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
            let detail = "No microphone input format is available. Engine hardware input: \(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) channels; tap output: \(format.sampleRate) Hz, \(format.channelCount) channels. Session: \(session.sampleRate) Hz, \(session.inputNumberOfChannels) input channels, category \(session.category.rawValue). Route input: \(inputs.isEmpty ? "none" : inputs); output: \(outputs.isEmpty ? "none" : outputs)."
            throw NSError(domain: "TelemetryIO.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        let analyzer = TelemetryAudioAnalyzer(mailbox: audioMailbox, generation: generation)
        try input.installAudioTap(onBus: 0, bufferSize: 1024, format: format, tapProvider: TelemetryAudioAnalyzer.tap(analyzer))
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        audioEngine = engine; audioAnalyzer = analyzer
        mark("microphone", .waiting, "Waiting for microphone samples.")
        publish("audio.sampleRate", value: format.sampleRate)
        sampleAudioRoute(); event("Microphone enabled", detail: "Local level, waveform and FFT analysis. Audio is not recorded.")
    }

    private func stopMicrophone() {
        microphoneEpoch += 1
        microphoneStartTask?.cancel(); microphoneStartTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0); audioEngine?.stop(); audioEngine = nil; audioAnalyzer = nil
        audioMailbox.clear(); waveform = []; spectrum = []
        // Release only after this engine stops. The coordinator retains a concurrent synth owner.
        if let microphoneReservation { audioSession.release(microphoneReservation) }
        microphoneReservation = nil
    }

    private func startCamera(request: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCamera()
        case .notDetermined:
            guard request else { mark("camera", .permission, "Enable to request camera access."); return }
            guard !cameraRequestPending else { return }
            cameraRequestPending = true
            mark("camera", .waiting, "Requesting camera access.")
            let epoch = epoch
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.cameraRequestPending = false
                    guard let self, self.isRunning, !self.isDemo, self.epoch == epoch, self.enabled.contains("camera") else { return }
                    if granted { self.beginCamera() } else { self.mark("camera", .restricted, "Camera access is denied in Settings.") }
                }
            }
        case .denied, .restricted: mark("camera", .restricted, "Camera access is denied in Settings.")
        @unknown default: mark("camera", .unavailable, "Camera authorization unavailable.")
        }
    }

    private func beginCamera() {
        cameraEpoch += 1
        let cameraEpoch = cameraEpoch
        if cameraCapture == nil { cameraCapture = TelemetryCameraCapture(mailbox: cameraMailbox) }
        mark("camera", .waiting, "Waiting for camera measurements.")
        let epoch = epoch
        cameraCapture?.start(generation: cameraEpoch) { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.epoch == epoch, self.cameraEpoch == cameraEpoch, self.enabled.contains("camera") else { return }
                if let error { self.mark("camera", .unavailable, error) }
                else { self.event("Camera enabled", detail: "Frames are measured at 10 Hz and immediately discarded.") }
            }
        }
    }

    private func startBluetooth(request: Bool) {
        let authorization = CBCentralManager.authorization
        if authorization == .denied || authorization == .restricted { mark("bluetooth", .restricted, "Bluetooth access is denied in Settings."); return }
        guard request || authorization == .allowedAlways else { mark("bluetooth", .permission, "Enable to request Bluetooth access."); return }
        mark("bluetooth", .waiting, "Waiting for Bluetooth state.")
        if let central { centralManagerDidUpdateState(central) }
        else { central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
    }

    private func sampleBluetooth() {
        guard central?.state == .poweredOn, central?.isScanning == true else { return }
        bleByID = bleByID.filter { elapsed - $0.value.lastSeen < 10 }
        bleDevices = Array(bleByID.values.sorted { $0.rssi > $1.rssi }.prefix(32))
        advertisementTimes.removeAll { elapsed - $0 > 1 }
        publish("ble.count", value: Double(bleDevices.count), detail: "Unique advertisers heard in the last 10 seconds.")
        publish("ble.rate", value: Double(advertisementTimes.count), detail: "Callbacks delivered during the last second.")
        if let strongest = bleDevices.first {
            let age = elapsed - strongest.lastSeen
            publish("ble.rssi", value: strongest.rssi, status: age > 3 ? .stale : .live, detail: "\(strongest.name) · heard \(Int(age))s ago")
        }
        else { status("ble.rssi", .waiting, detail: "No recent BLE advertiser heard.") }
    }

    private func startPassive() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let names: [Notification.Name] = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification, UIDevice.proximityStateDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange, UIScreen.brightnessDidChangeNotification]
        for name in names {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.isRunning, !self.isDemo else { return }; self.sampleDevice() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioRouteChanged() }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.enabled.contains("microphone"), self.microphoneCanResume, let engine = self.audioEngine, notification.object as? AVAudioEngine === engine else { return }
                self.stopMicrophone(); self.beginAudioEngine()
            }
        })
        audioTokens.append(NotificationCenter.default.addObserver(of: AVAudioSession.sharedInstance(), for: .didBecomeInactive) { [weak self] (message: AVAudioSession.DidBecomeInactiveMessage) in
            guard case .systemInterruption = message.deactivationResult else { return }
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.enabled.contains("microphone") else { return }
                self.microphoneCanResume = false
                self.stopMicrophone(); self.mark("microphone", .waiting, "Audio was interrupted by the system.")
            }
        })
        audioTokens.append(NotificationCenter.default.addObserver(of: AVAudioSession.sharedInstance(), for: .resumptionRecommendation) { [weak self] (message: AVAudioSession.ResumptionRecommendationMessage) in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.enabled.contains("microphone") else { return }
                self.microphoneCanResume = message.recommendation == .shouldResume
                guard self.microphoneCanResume else { return }
                self.startMicrophone(request: false)
            }
        })
        let monitor = NWPathMonitor()
        let epoch = epoch
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo, self.epoch == epoch else { return }
                self.pathChanged(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "TelemetryIO.network", qos: .utility)); networkMonitor = monitor
        ratToken = NotificationCenter.default.addObserver(of: String.self, for: .radioAccessTechnologyDidChange) { [weak self] (_: CTTelephonyNetworkInfo.RadioAccessTechnologyDidChangeMessage) in
            Task { @MainActor in self?.sampleTelephony() }
        }
        #if !targetEnvironment(simulator)
        telephony = CTTelephonyNetworkInfo()
        #endif
        traffic.reset(); trafficHasBaseline = false
        sampleDevice(); sampleTelephony(); sampleAudioRoute()
    }

    private func sampleDevice() {
        let device = UIDevice.current
        if device.batteryLevel >= 0 { publish("device.battery", value: Double(device.batteryLevel) * 100) }
        else { status("device.battery", .unavailable, detail: "iOS has not supplied a battery level.") }
        if device.batteryState != .unknown { publish("device.charging", value: device.batteryState == .charging || device.batteryState == .full ? 1 : 0, detail: device.batteryState == .full ? "Full" : device.batteryState == .charging ? "Charging" : "Unplugged") }
        else { status("device.charging", .unavailable, detail: "Battery state unavailable.") }
        let process = ProcessInfo.processInfo
        publish("device.thermal", value: Double(process.thermalState.rawValue), detail: ["Nominal", "Fair", "Serious", "Critical"][min(3, max(0, process.thermalState.rawValue))])
        publish("device.lowPower", value: process.isLowPowerModeEnabled ? 1 : 0)
        if let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })?.screen {
            publish("device.brightness", value: Double(screen.brightness) * 100)
        } else { status("device.brightness", .waiting, detail: "No foreground screen is available.") }
        if enabled.contains("proximity"), device.isProximityMonitoringEnabled { publish("device.proximity", value: device.proximityState ? 1 : 0) }
        publish("audio.volume", value: Double(AVAudioSession.sharedInstance().outputVolume) * 100)
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        if sampleRate > 0 { publish("audio.sampleRate", value: sampleRate) }
        else { status("audio.sampleRate", .waiting, detail: "The audio session has no active sample rate.") }
    }

    private func sampleAudioRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.map(\.portName).joined(separator: ", ")
        let output = route.outputs.map(\.portName).joined(separator: ", ")
        routeDescription = input.isEmpty ? (output.isEmpty ? "System audio" : output) : "\(input) → \(output)"
    }

    private func audioRouteChanged() {
        guard isRunning, !isDemo else { return }
        sampleAudioRoute(); event("Audio route changed", detail: routeDescription)
        // The engine configuration observer rebuilds the tap when hardware format changes.
    }

    private func pathChanged(_ path: NWPath) {
        let reachable = path.status == .satisfied
        publish("network.wifi", value: reachable && path.usesInterfaceType(.wifi) ? 1 : 0)
        publish("network.cellular", value: reachable && path.usesInterfaceType(.cellular) ? 1 : 0)
        publish("network.reachable", value: reachable ? 1 : 0, detail: "Path status only; no endpoint probe is performed.")
        publish("network.expensive", value: path.isExpensive ? 1 : 0)
        publish("network.constrained", value: path.isConstrained ? 1 : 0)
        let quality: Double
        switch path.linkQuality { case .minimal: quality = 1; case .moderate: quality = 2; case .good: quality = 3; default: quality = 0 }
        publish("network.quality", value: quality, detail: quality == 0 ? "The system did not supply a quality grade." : "System link-quality category; not RSSI.")
        traffic.interfaceNames = Set(path.availableInterfaces.map(\.name))
        event("Network path changed", detail: !reachable ? "No satisfied network path" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Cellular" : "Other network interface")
    }

    private func sampleTelephony() {
        guard isRunning, !isDemo else { return }
        let technologies = telephony?.serviceCurrentRadioAccessTechnology ?? [:]
        let active = telephony?.dataServiceIdentifier.flatMap { technologies[$0] } ?? technologies.values.first
        guard let technology = active else { status("cellular.generation", .unavailable, detail: "No cellular radio technology was supplied."); return }
        let generation: Double
        if technology.contains("NR") { generation = 5 }
        else if technology.contains("LTE") { generation = 4 }
        else if technology.contains("WCDMA") || technology.contains("HSDPA") || technology.contains("HSUPA") || technology.contains("EVDO") || technology.contains("eHRPD") { generation = 3 }
        else if technology.contains("GPRS") || technology.contains("Edge") || technology.contains("CDMA") { generation = 2 }
        else { generation = 0 }
        publish("cellular.generation", value: generation, detail: technology)
    }

    private func stopHardware() {
        motion?.stopDeviceMotionUpdates(); motion?.stopAccelerometerUpdates(); motion?.stopGyroUpdates(); motion?.stopMagnetometerUpdates(); lastMotionTimestamp = [:]
        altimeter?.stopRelativeAltitudeUpdates(); pedometer?.stopUpdates()
        location.stopUpdatingLocation(); location.stopUpdatingHeading()
        stopMicrophone(); microphoneCanResume = true; cameraEpoch += 1; cameraCapture?.stop(); cameraMailbox.clear()
        central?.stopScan(); central?.delegate = nil; central = nil
        bleByID = [:]; bleDevices = []; advertisementTimes = []
        networkMonitor?.cancel(); networkMonitor = nil; telephony = nil; ratToken = nil
        audioTokens.removeAll(); traffic.reset(); trafficHasBaseline = false
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }; notifications = []
        UIDevice.current.isProximityMonitoringEnabled = false; UIDevice.current.isBatteryMonitoringEnabled = false
        nfc.stop()
        nearby.stop()
    }

    private func demoTick() {
        let t = elapsed
        for definition in SignalCatalog.all where definition.group != .output && definition.group != .interaction {
            let phase = Double(definition.id.utf8.reduce(0) { $0 + Int($1) } % 29) * 0.31
            var value = definition.range.lowerBound + (sin(t * 0.7 + phase) + 1) * 0.5 * (definition.range.upperBound - definition.range.lowerBound)
            switch definition.id {
            case "pressure": value = 101.3 + sin(t * 0.08) * 0.25
            case "altitude.relative": value = sin(t * 0.2) * 3
            case "location.latitude": value = 41.8781 + sin(t * 0.02) * 0.0002
            case "location.longitude": value = -87.6298 + cos(t * 0.02) * 0.0002
            case "device.battery": value = 76
            case "device.thermal": value = 0
            case "mic.rms": value = -24 + sin(t * 2) * 8
            case "mic.peak": value = -12 + sin(t * 2) * 8
            case "mic.frequency": value = 220 + sin(t * 0.5) * 80
            case "audio.sampleRate": value = 48000
            case "network.wifi", "network.reachable", "ble.state": value = 1
            case "network.cellular", "network.expensive", "network.constrained", "device.charging", "device.lowPower", "device.proximity": value = 0
            case "network.quality": value = 3
            case "cellular.generation": value = 5
            case "ble.count": value = 5
            case "ble.rate": value = 12 + sin(t) * 4
            case "ble.rssi": value = -46 + sin(t * 0.5) * 5
            case "nfc.reads": value = 0
            case "steps.count": value = floor(t * 1.6)
            default: break
            }
            publish(definition.id, value: value, status: .demo, detail: "Synthetic demo value; no hardware measurement.")
        }
        bleDevices = demoBLEIDs.enumerated().map { index, id in BLEObservation(id: id, name: "Demo advertiser \(index + 1)", rssi: -46 - Double(index) * 9 + sin(t + Double(index)) * 5, lastSeen: t) }
        waveform = (0..<192).map { sin(Double($0) * 0.15 + t * 6) * (0.2 + 0.12 * sin(t)) }
        spectrum = (0..<48).map { max(0, 0.65 * exp(-pow((Double($0) - 14 - sin(t) * 5) / 4, 2))) }
        routeDescription = "DEMO · synthetic audio visualization"
    }

    func csv() -> String {
        func escaped(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["signal,name,unit,time_s,value,mode"]
        for definition in SignalCatalog.all {
            for sample in recorded[definition.id] ?? [] {
                rows.append([escaped(definition.id), escaped(definition.name), escaped(definition.unit), String(format: "%.3f", sample.time), String(format: "%.8f", sample.value), escaped(sample.mode)].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }
}

extension TelemetryHub: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning, !isDemo, enabled.contains("location") else { return }
        startLocation(request: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, !isDemo, enabled.contains("location"), let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        let age = max(0, Date().timeIntervalSince(fix.timestamp))
        let state: SignalStatus = age > 10 ? .stale : .live
        let precision = manager.accuracyAuthorization == .reducedAccuracy ? "Approximate location" : "Precise location"
        let origin: String
        if fix.sourceInformation?.isSimulatedBySoftware == true { origin = "Software-simulated Core Location" }
        else if fix.sourceInformation?.isProducedByAccessory == true { origin = "Accessory-supplied Core Location" }
        else {
            #if targetEnvironment(simulator)
            origin = "iOS Simulator Core Location"
            #else
            origin = "Fused Core Location"
            #endif
        }
        let provenance = "\(origin) · \(precision)"
        publish("location.latitude", value: fix.coordinate.latitude, status: state, detail: provenance)
        publish("location.longitude", value: fix.coordinate.longitude, status: state, detail: provenance)
        publish("location.accuracy", value: fix.horizontalAccuracy, status: state, detail: provenance)
        if fix.verticalAccuracy >= 0 { publish("location.altitude", value: fix.altitude, status: state, detail: provenance); publish("location.verticalAccuracy", value: fix.verticalAccuracy, status: state, detail: provenance) }
        else { status("location.altitude", .waiting, detail: "No valid altitude estimate."); status("location.verticalAccuracy", .waiting, detail: "No valid vertical accuracy.") }
        if fix.speed >= 0 { publish("location.speed", value: fix.speed, status: state, detail: provenance) }
        else { status("location.speed", .waiting, detail: "Speed is unavailable for this fix.") }
        if fix.course >= 0 { publish("location.course", value: fix.course, status: state, detail: provenance) }
        else { status("location.course", .waiting, detail: "Travel course is unavailable for this fix.") }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard isRunning, !isDemo, enabled.contains("location"), heading.headingAccuracy >= 0 else { return }
        publish("location.heading", value: heading.magneticHeading, detail: "Magnetic heading · ±\(Int(heading.headingAccuracy))°")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isRunning, !isDemo, enabled.contains("location") else { return }
        if let locationError = error as? CLError, locationError.code == .locationUnknown {
            mark("location", .waiting, "The system is still acquiring a location fix.")
        } else { mark("location", .restricted, error.localizedDescription) }
    }
}

extension TelemetryHub: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isRunning, !isDemo, enabled.contains("bluetooth") else { return }
        switch central.state {
        case .poweredOn:
            publish("ble.state", value: 1)
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            for id in ["ble.count", "ble.rate", "ble.rssi"] { status(id, .waiting, detail: "Listening for BLE advertisements.") }
        case .poweredOff:
            bleByID = [:]; bleDevices = []; advertisementTimes = []
            mark("bluetooth", .unavailable, "Bluetooth is powered off."); publish("ble.state", value: 0)
        case .unauthorized:
            bleByID = [:]; bleDevices = []; advertisementTimes = []
            mark("bluetooth", .restricted, "Bluetooth access is denied in Settings.")
        case .unsupported:
            bleByID = [:]; bleDevices = []; advertisementTimes = []
            mark("bluetooth", .unavailable, "Bluetooth LE is unsupported on this device.")
        case .resetting, .unknown:
            bleByID = [:]; bleDevices = []; advertisementTimes = []
            mark("bluetooth", .waiting, "Bluetooth is initializing.")
        @unknown default: mark("bluetooth", .unavailable, "Bluetooth state unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isRunning, !isDemo, enabled.contains("bluetooth"), central.isScanning else { return }
        let rssi = RSSI.doubleValue
        guard rssi != 127, rssi < 0, rssi >= -127 else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unnamed advertiser"
        bleByID[peripheral.identifier] = BLEObservation(id: peripheral.identifier, name: String(name.prefix(64)), rssi: rssi, lastSeen: elapsed)
        if bleByID.count > 64 {
            let keep = Set(bleByID.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(32).map(\.id))
            bleByID = bleByID.filter { keep.contains($0.key) }
        }
        advertisementTimes.append(elapsed)
        if advertisementTimes.count > 2000 { advertisementTimes.removeFirst(advertisementTimes.count - 2000) }
    }
}
