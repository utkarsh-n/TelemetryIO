import SwiftUI

private enum InstrumentTab: String { case field, channels, patch, log }
private enum InstrumentSheet: String, Identifiable { case sensors, about; var id: String { rawValue } }

struct RootView: View {
    @Bindable var model: InstrumentModel
    @State private var tab: InstrumentTab = .field
    @State private var sheet: InstrumentSheet?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $tab) {
            Tab("Field", systemImage: "circle.hexagongrid", value: .field) { navigation { FieldView(model: model) } }
            Tab("Channels", systemImage: "slider.horizontal.3", value: .channels) { navigation { ChannelsView(model: model) } }
            Tab("Patch", systemImage: "point.3.connected.trianglepath.dotted", value: .patch) { navigation { PatchView(model: model) } }
            Tab("Session", systemImage: "clock.arrow.circlepath", value: .log) { navigation { SessionView(model: model) } }
        }
        .sheet(item: $sheet) { item in
            switch item { case .sensors: SensorAccessView(model: model); case .about: AboutView() }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-demo") { model.setDemo(true) }
            if ProcessInfo.processInfo.arguments.contains("-channels") { tab = .channels }
            if ProcessInfo.processInfo.arguments.contains("-patch") { tab = .patch }
            model.start()
        }
        .onChange(of: model.fieldRequest) { _, _ in tab = .field }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.start() } else { model.stop() } }
    }
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().foregroundStyle(IOTheme.text)
                .navigationTitle("Telemetry I/O").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Toggle("Demo signals", isOn: Binding(get: { model.hub.isDemo }, set: { model.setDemo($0) }))
                            Button("Sensor access", systemImage: "sensor") { sheet = .sensors }
                            Button("About this instrument", systemImage: "info.circle") { sheet = .about }
                        } label: { Image(systemName: model.hub.isDemo ? "sparkles" : "sensor").frame(width: 44, height: 44) }.accessibilityLabel("Source mode and sensors").accessibilityIdentifier("source-menu")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.togglePause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 44, height: 44) }.accessibilityLabel(model.paused ? "Resume capture" : "Pause capture").accessibilityIdentifier("capture-transport")
                    }
                }
        }
    }
}

struct SensorAccessView: View {
    let model: InstrumentModel
    @State private var showPeer = false
    @Environment(\.dismiss) private var dismiss
    private let sensors: [(String, String, String, String)] = [
        ("motion", "Motion & magnetic field", "gyroscope", "Acceleration, rotation, gravity, attitude, magnetic field."),
        ("barometer", "Air pressure", "barometer", "Pressure and relative altitude."),
        ("steps", "Steps & cadence", "figure.walk", "Session walking measurements."),
        ("location", "Location & heading", "location", "Position, accuracy, speed, course and compass. Foreground only."),
        ("microphone", "Microphone", "mic", "Digital level and audio spectrum. Audio is processed locally."),
        ("camera", "Camera measurements", "camera", "Brightness, color, ISO and exposure. Frames are discarded."),
        ("bluetooth", "Nearby BLE", "dot.radiowaves.left.and.right", "Advertisement callbacks and received signal strength."),
        ("proximity", "Proximity", "sensor", "The screen can darken when a near object is detected."),
        ("nfc", "NFC tag session", "wave.3.right", "Read a nearby NDEF tag deliberately. Requires NFC signing capability."),
        ("peer", "UWB capability", "sensor.tag.radiowaves.forward", "Check ranging support. Live distance requires a participating peer.")
    ]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Demo signals", isOn: Binding(get: { model.hub.isDemo }, set: { model.setDemo($0) })).accessibilityIdentifier("sensor-demo-toggle")
                    Text(model.hub.isDemo ? "All generated inputs carry a DEMO label. Device measurements resume when you leave demo." : "Enable each source when you want to use it. Capture stops when the app leaves the foreground.").font(.caption).foregroundStyle(IOTheme.muted)
                }
                Section("Inputs") {
                    ForEach(sensors, id: \.0) { sensor in
                        VStack(alignment: .leading, spacing: 8) {
                            if sensor.0 == "nfc" || sensor.0 == "peer" {
                                Button { if sensor.0 == "peer" { showPeer = true } else { model.hub.enable(sensor.0) } } label: { Label(sensor.1, systemImage: sensor.2).frame(minHeight: 44) }.disabled(model.hub.isDemo).accessibilityIdentifier("sensor-\(sensor.0)")
                            } else {
                                Toggle(isOn: Binding(get: { model.hub.enabled.contains(sensor.0) }, set: { $0 ? model.hub.enable(sensor.0) : model.hub.disable(sensor.0) })) { Label(sensor.1, systemImage: sensor.2) }.disabled(model.hub.isDemo).accessibilityIdentifier("sensor-\(sensor.0)")
                            }
                            Text(sensor.3).font(.caption).foregroundStyle(IOTheme.muted)
                        }.padding(.vertical, 4)
                    }
                }
                Section("Outputs") {
                    Toggle("Hear the local synth", isOn: Binding(get: { model.soundEnabled }, set: { model.soundEnabled = $0 })).accessibilityIdentifier("sensor-sound-toggle")
                    Toggle("Feel routed haptic pulses", isOn: Binding(get: { model.hapticsEnabled }, set: { model.hapticsEnabled = $0 })).accessibilityIdentifier("sensor-haptics-toggle")
                    Text("Patch inputs to tone or haptic targets. The oscillator makes sound through the current audio route; it does not transmit RF.").font(.caption).foregroundStyle(IOTheme.muted)
                }
            }.accessibilityIdentifier("sensor-access-list").scrollContentBackground(.hidden).background(IOTheme.background).navigationTitle("Sensor access").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $showPeer) { PeerRangingView(model: model) }
        }
    }
}

struct SessionView: View {
    let model: InstrumentModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("A session in signals.").font(.system(.title, design: .serif))
                HStack {
                    metric("SESSION", String(format: "%.0f s", model.hub.elapsed))
                    metric("CHANNELS", "\(model.hub.readings.values.filter { !$0.samples.isEmpty }.count)")
                    metric("ROUTES", "\(model.patches.filter(\.enabled).count)")
                }.instrumentPanel()
                VStack(alignment: .leading, spacing: 12) {
                    SectionEyebrow(number: "01", title: "CAPTURE")
                    Text("A rolling history of up to 600 samples per channel stays in memory (about 30 seconds at 20 Hz). Export includes channel ID, timestamp, value, unit, and provenance. Enabled location channels include coordinates.").font(.subheadline).foregroundStyle(IOTheme.muted)
                    Button("Prepare CSV export", systemImage: "square.and.arrow.up") { model.export() }.buttonStyle(.glassProminent).accessibilityIdentifier("export-csv")
                    if let url = model.lastExport { ShareLink(item: url) { Label("Share capture", systemImage: "square.and.arrow.up") }.buttonStyle(.glass).accessibilityIdentifier("share-capture") }
                    if let error = model.exportError { Text(error).font(.caption).foregroundStyle(IOTheme.rose) }
                }.instrumentPanel()
                if !model.hub.bleDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionEyebrow(number: "02", title: "BLE ADVERTISERS")
                        ForEach(model.hub.bleDevices) { device in
                            HStack {
                                VStack(alignment: .leading) { Text(device.name).font(.subheadline); Text(device.id.uuidString.prefix(8)).font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted) }
                                Spacer(); Text(String(format: "%.0f dBm", device.rssi)).font(.system(.callout, design: .monospaced)).foregroundStyle(IOTheme.violet)
                            }.padding(.vertical, 5)
                        }
                        Text("App-scoped identifiers. Advertisements heard by this app; no connections or physical bearings.").font(.caption).foregroundStyle(IOTheme.muted)
                    }.instrumentPanel()
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionEyebrow(number: "03", title: "EVENTS")
                    if model.hub.events.isEmpty { Text("Source and permission changes appear here.").font(.subheadline).foregroundStyle(IOTheme.muted) }
                    ForEach(model.hub.events.reversed()) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(IOTheme.mint).frame(width: 6, height: 6).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) { Text(event.title).font(.subheadline.weight(.medium)); Text(event.detail).font(.caption).foregroundStyle(IOTheme.muted) }
                            Spacer(); Text(event.date, style: .time).font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted)
                        }
                    }
                }.instrumentPanel()
                Text("\(model.hub.routeDescription)").font(.caption).foregroundStyle(IOTheme.muted)
            }.padding(16).padding(.bottom, 20)
        }.accessibilityIdentifier("session-scroll").background(IOTheme.background)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted); Text(value).font(.system(.title3, design: .monospaced)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Telemetry\nI/O").font(.system(size: 52, weight: .light, design: .serif))
                    Text("An instrument for the signals your phone can share.").font(.title3)
                    Text("Built from Spectra's glass over phosphor language and Gyre's direct, tactile controls. Inspect a channel, drag the field, and connect an input to an output in Patch.").foregroundStyle(IOTheme.muted)
                    Text("LIVE is measured or derived from a current public API. DEMO is generated. WAITING needs data or a peer. STALE has stopped updating. UNAVAILABLE and RESTRICTED explain access limits.").font(.subheadline)
                    Text("This app sees its own telemetry and public device state. iOS does not expose a universal view of every app's radio and sensor usage. No remote service receives your capture. Export is a deliberate action.").font(.subheadline).foregroundStyle(IOTheme.muted)
                    Link("Apple sensor and privacy documentation", destination: URL(string: "https://developer.apple.com/documentation/coremotion")!)
                }.padding(24)
            }.accessibilityIdentifier("about-scroll").background(IOTheme.background).navigationTitle("About").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
