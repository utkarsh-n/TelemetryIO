import Foundation

public enum SignalCatalog {
    public static let all: [SignalDefinition] = {
        var result: [SignalDefinition] = []
        func add(_ id: String, _ name: String, _ group: SignalGroup, _ unit: String, _ range: ClosedRange<Double>, _ symbol: String, _ explanation: String, _ source: String, _ permission: String? = nil, _ decimals: Int = 2) {
            result.append(SignalDefinition(id, name, group, unit, range, symbol, explanation, source, permission: permission, decimals: decimals))
        }
        for (prefix, label, unit, range, explanation) in [
            ("accel", "Acceleration", "g", -2.0...2.0, "Raw acceleration includes gravity. One g is about 9.81 m/s²."),
            ("gyro", "Rotation", "rad/s", -8.0...8.0, "Angular velocity around each phone axis."),
            ("gravity", "Gravity", "g", -1.0...1.0, "Gravity separated from movement by sensor fusion."),
            ("userAccel", "User acceleration", "g", -2.0...2.0, "Movement with the estimated gravity vector removed."),
            ("mag", "Magnetic field", "µT", -150.0...150.0, "Magnetic flux density along each phone axis, including nearby magnets.")
        ] {
            for axis in ["x", "y", "z"] { add("\(prefix).\(axis)", "\(label) \(axis.uppercased())", .motion, unit, range, prefix == "mag" ? "compass.drawing" : "gyroscope", explanation, "Core Motion", "motion") }
        }
        for axis in ["roll", "pitch", "yaw"] { add("attitude.\(axis)", axis.capitalized, .motion, "°", -180...180, "rotate.3d", "Fused phone orientation. Yaw can drift without a reliable magnetic reference.", "Core Motion", "motion", 1) }
        add("mag.total", "Field magnitude", .motion, "µT", 0...150, "compass.drawing", "Length of the magnetic field vector. This is low-frequency magnetometry, not an RF spectrum analyzer.", "Core Motion", "motion", 1)
        add("motion.intensity", "Movement energy", .motion, "g", 0...2, "figure.walk", "Magnitude of acceleration after gravity is removed.", "Core Motion · derived", "motion")
        add("steps.count", "Session steps", .motion, "steps", 0...500, "figure.walk", "Steps counted since the current session started.", "CMPedometer", "steps", 0)
        add("steps.cadence", "Walking cadence", .motion, "steps/s", 0...4, "figure.walk", "Current cadence when the pedometer supplies it.", "CMPedometer", "steps")
        add("steps.distance", "Walking distance", .motion, "m", 0...1000, "point.topleft.down.to.point.bottomright.curvepath", "Estimated distance walked during this session.", "CMPedometer", "steps", 1)
        add("pressure", "Air pressure", .environment, "kPa", 80...110, "barometer", "Ambient pressure from the phone's barometer.", "CMAltimeter", "barometer")
        add("altitude.relative", "Relative altitude", .environment, "m", -30...30, "mountain.2", "Height change since the barometer was started; weather can also affect it.", "CMAltimeter", "barometer")
        add("camera.luma", "Camera luminance", .environment, "%", 0...100, "sun.max", "Mean brightness of camera pixels; exposure changes affect it. It is not a calibrated ambient lux meter.", "AVCaptureVideoDataOutput", "camera", 1)
        for color in ["red", "green", "blue"] { add("camera.\(color)", "Camera \(color)", .environment, "%", 0...100, "camera", "Mean color component from a subsampled camera frame. Frames are discarded after measurement.", "AVCaptureVideoDataOutput", "camera", 1) }
        add("camera.iso", "Camera ISO", .environment, "ISO", 20...2000, "camera.aperture", "Camera sensor gain reported by the capture device.", "AVCaptureDevice", "camera", 0)
        add("camera.exposure", "Exposure time", .environment, "ms", 0...100, "camera.aperture", "Actual camera exposure duration.", "AVCaptureDevice", "camera")
        add("location.latitude", "Latitude", .location, "°", -90...90, "location", "Position estimate from Core Location; GPS, Wi-Fi and cellular can all contribute. Location stays in memory unless you export a capture.", "Core Location", "location", 5)
        add("location.longitude", "Longitude", .location, "°", -180...180, "location", "Core Location does not expose raw satellite RF, satellite counts, or GNSS-only usage.", "Core Location", "location", 5)
        add("location.altitude", "Location altitude", .location, "m", -50...3000, "mountain.2", "Altitude estimate relative to sea level; check vertical accuracy.", "Core Location", "location", 1)
        add("location.accuracy", "Position accuracy", .location, "m", 0...100, "scope", "Estimated horizontal uncertainty. Lower is better.", "Core Location", "location", 1)
        add("location.verticalAccuracy", "Vertical accuracy", .location, "m", 0...100, "scope", "Estimated vertical uncertainty; absent when invalid.", "Core Location", "location", 1)
        add("location.speed", "Ground speed", .location, "m/s", 0...35, "speedometer", "Ground speed estimate; absent when unavailable.", "Core Location", "location")
        add("location.course", "Travel course", .location, "°", 0...360, "location.north", "Direction of travel, not the direction the phone faces.", "Core Location", "location", 1)
        add("location.heading", "Magnetic heading", .location, "°", 0...360, "compass", "Compass direction relative to magnetic north. Calibration and nearby metal affect it.", "CLHeading", "location", 1)
        add("mic.rms", "Microphone level", .audio, "dBFS", -80...0, "mic", "Root-mean-square sample amplitude. dBFS is digital level, not calibrated sound pressure in dB SPL.", "AVAudioEngine · derived", "microphone", 1)
        add("mic.peak", "Microphone peak", .audio, "dBFS", -80...0, "waveform", "Peak audio sample magnitude in each block.", "AVAudioEngine · derived", "microphone", 1)
        add("mic.frequency", "Dominant frequency", .audio, "Hz", 20...8000, "waveform", "Strongest spectral bin of a windowed microphone block; silence has no reliable pitch.", "Microphone · FFT", "microphone", 0)
        add("audio.sampleRate", "Audio sample rate", .audio, "Hz", 8000...96000, "waveform", "Current audio session sampling frequency.", "AVAudioSession", nil, 0)
        add("audio.volume", "Output volume", .audio, "%", 0...100, "speaker.wave.2", "System media output volume; the app cannot read audio played by other apps.", "AVAudioSession", nil, 0)
        add("network.wifi", "Wi-Fi path", .radio, "active", 0...1, "wifi", "Whether the current network path uses Wi-Fi; this is not all Wi-Fi radio activity.", "NWPathMonitor", nil, 0)
        add("network.cellular", "Cellular path", .radio, "active", 0...1, "antenna.radiowaves.left.and.right", "Whether the current network path uses cellular data.", "NWPathMonitor", nil, 0)
        add("network.quality", "Link quality", .radio, "grade", 0...3, "chart.bar", "System path-quality category: 0 unknown, 1 minimal, 2 moderate, 3 good. Not RSSI.", "NWPath.linkQuality", nil, 0)
        add("network.expensive", "Metered path", .radio, "flag", 0...1, "antenna.radiowaves.left.and.right", "The system considers this path expensive, such as cellular or a hotspot.", "NWPath.isExpensive", nil, 0)
        add("network.constrained", "Low Data Mode", .radio, "flag", 0...1, "network", "The active path is constrained by Low Data Mode.", "NWPath.isConstrained", nil, 0)
        add("network.reachable", "Network reachable", .radio, "flag", 0...1, "network", "The system reports a satisfied network path. This does not prove an internet endpoint is reachable.", "NWPathMonitor", nil, 0)
        add("network.rx", "Network receive", .radio, "B/s", 0...10_000_000, "arrow.down.circle", "Aggregate bytes received on available transport interfaces. Counters include other activity and cannot identify apps or packet contents; 32-bit wraps and resets start a new baseline when ambiguous.", "getifaddrs · aggregate counters", nil, 0)
        add("network.tx", "Network transmit", .radio, "B/s", 0...10_000_000, "arrow.up.circle", "Aggregate bytes transmitted on available transport interfaces, measured between samples. This is not per-app traffic or a persistent data-usage total.", "getifaddrs · aggregate counters", nil, 0)
        add("cellular.generation", "Cellular technology", .radio, "G", 0...5, "antenna.radiowaves.left.and.right", "Reported radio access technology for active cellular service. Zero means unknown; no tower or signal-strength measurement is available.", "CTTelephonyNetworkInfo", nil, 0)
        add("ble.count", "Nearby BLE advertisers", .radio, "devices", 0...30, "dot.radiowaves.left.and.right", "Unique Bluetooth LE advertisers heard recently; this is not a list of paired devices.", "CoreBluetooth", "bluetooth", 0)
        add("ble.rssi", "Strongest BLE signal", .radio, "dBm", -100 ... -20, "dot.radiowaves.left.and.right", "Strongest received advertisement power. Obstacles and antenna orientation make RSSI a poor distance measure.", "CoreBluetooth", "bluetooth", 0)
        add("ble.rate", "BLE advertisements", .radio, "/s", 0...100, "dot.radiowaves.left.and.right", "Advertisement callbacks delivered to this app, not total over-the-air packet traffic.", "CoreBluetooth · derived", "bluetooth", 1)
        add("ble.state", "Bluetooth state", .radio, "on", 0...1, "dot.radiowaves.left.and.right", "Bluetooth central manager power state.", "CoreBluetooth", "bluetooth", 0)
        add("nfc.reads", "NFC tag reads", .radio, "tags", 0...20, "wave.3.right", "NDEF tags read during a user-started NFC session. Payment and background NFC traffic are not exposed.", "Core NFC", "nfc", 0)
        add("uwb.distance", "UWB peer distance", .radio, "m", 0...10, "sensor.tag.radiowaves.forward", "Nearby Interaction needs a participating peer and exchanged discovery tokens. Capability is visible; ranging requires a paired session.", "Nearby Interaction", "peer")
        for axis in ["x", "y", "z"] {
            add("uwb.direction.\(axis)", "UWB direction \(axis.uppercased())", .radio, "component", -1...1, "location.north", "Component of the measured peer direction unit vector, relative to the phone's coordinate frame. No value is supplied when direction is unsupported or the peer cannot be resolved.", "Nearby Interaction", "peer")
        }
        add("device.battery", "Battery charge", .device, "%", 0...100, "battery.100percent", "Battery charge level supplied by iOS. Current draw and battery temperature are not public telemetry.", "UIDevice", nil, 0)
        add("device.charging", "Charging", .device, "flag", 0...1, "bolt", "iOS battery state. Charging source and wattage are not available.", "UIDevice", nil, 0)
        add("device.thermal", "Thermal state", .device, "grade", 0...3, "thermometer.medium", "System thermal pressure: nominal, fair, serious or critical. This is not a temperature sensor readout.", "ProcessInfo", nil, 0)
        add("device.lowPower", "Low Power Mode", .device, "flag", 0...1, "battery.50percent", "System energy-saving mode.", "ProcessInfo", nil, 0)
        add("device.brightness", "Screen brightness", .device, "%", 0...100, "sun.max", "Current screen brightness setting; not ambient light intensity.", "UIScreen", nil, 0)
        add("device.proximity", "Proximity", .device, "near", 0...1, "sensor", "Binary near/far state when proximity monitoring is enabled; not a distance measurement.", "UIDevice", "proximity", 0)
        add("touch.x", "Touch X", .interaction, "%", 0...100, "hand.draw", "Horizontal position in the interactive signal field.", "SwiftUI gesture", nil, 1)
        add("touch.y", "Touch Y", .interaction, "%", 0...100, "hand.draw", "Vertical position in the interactive signal field.", "SwiftUI gesture", nil, 1)
        add("output.pitch", "Synth frequency", .output, "Hz", 80...1600, "waveform", "Frequency commanded to this app's local oscillator. This is audio synthesis, not RF transmission.", "Telemetry I/O output", nil, 0)
        add("output.level", "Synth level", .output, "%", 0...100, "speaker.wave.2", "Gain commanded to the app's oscillator.", "Telemetry I/O output", nil, 1)
        add("output.haptic", "Haptic drive", .output, "%", 0...100, "hand.tap", "Intensity requested from this app's haptic output; not a measured vibration.", "Telemetry I/O output", nil, 1)
        return result
    }()
    public static func definition(_ id: String) -> SignalDefinition? { all.first { $0.id == id } }
    public static let restrictions: [(String, String, String)] = [
        ("RF spectrum & baseband", "antenna.radiowaves.left.and.right", "No public I/Q samples, frequency sweeps, cellular dBm, transmit power or baseband packet feed."),
        ("Wi-Fi neighborhood", "wifi", "General Wi-Fi scanning and RSSI are unavailable to a normal iPhone app. Path status and quality are accessible."),
        ("Other apps' I/O", "app.connected.to.app.below.fill", "iOS does not expose other apps' network content, microphone use, sensor use or per-app radio attribution."),
        ("GNSS satellites", "location", "Core Location exposes fused position estimates, not raw satellite measurements, constellations or satellite counts."),
        ("Private sensors", "lock", "Ambient light lux, battery current/temperature, biometric internals and Secure Enclave telemetry have no general public readout.")
    ]
}
