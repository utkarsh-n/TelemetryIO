import SwiftUI

struct FieldView: View {
    @Bindable var model: InstrumentModel
    @State private var inspector: SignalDefinition?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let featured = ["motion.intensity", "mag.total", "pressure", "mic.rms", "ble.rssi", "location.speed", "device.battery", "touch.x"]
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your phone,\nin signals.").font(.system(.largeTitle, design: .serif).weight(.regular)).tracking(-1)
                        Text(model.hub.isDemo ? "A PLAYABLE DEMO OF THE INSTRUMENT" : "LIVE INPUTS · LOCAL OUTPUTS").font(.system(.caption2, design: .monospaced)).tracking(1.2).foregroundStyle(IOTheme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%02d", model.hub.isDemo ? model.demoCount : model.liveCount)).font(.system(.largeTitle, design: .monospaced).weight(.light)).foregroundStyle(model.hub.isDemo ? IOTheme.amber : IOTheme.mint)
                        Text(model.hub.isDemo ? "DEMO CHANNELS" : "LIVE CHANNELS").font(.system(size: 9, design: .monospaced)).foregroundStyle(IOTheme.muted)
                    }
                }
                Picker("Visualization", selection: $model.fieldMode) {
                    ForEach(FieldMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).accessibilityIdentifier("field-mode")
                display.frame(height: 340)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(featured, id: \.self) { id in
                            let reading = model.hub.reading(id)
                            Button { model.select(id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 5) {
                                        Circle().fill(IOTheme.color(for: reading.definition.group)).frame(width: 5, height: 5)
                                        Text(shortName(id)).font(.system(.caption2, design: .monospaced))
                                    }
                                    Text("\(reading.definition.formatted(reading.value)) \(reading.definition.unit)").font(.system(.caption, design: .monospaced)).monospacedDigit()
                                }.foregroundStyle(model.selectedSignalID == id ? IOTheme.text : IOTheme.muted).padding(12).frame(minWidth: 110, minHeight: 58, alignment: .leading)
                                    .background(model.selectedSignalID == id ? IOTheme.color(for: reading.definition.group).opacity(0.1) : IOTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.selectedSignalID == id ? IOTheme.color(for: reading.definition.group).opacity(0.6) : .white.opacity(0.06)))
                            }.buttonStyle(.plain).accessibilityLabel("Select \(reading.definition.name)").accessibilityIdentifier("select-\(id)")
                        }
                    }
                }.accessibilityIdentifier("field-featured")
                selectedReadout
                if !model.hub.isDemo && model.hub.enabled.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start with movement.").font(.headline)
                        Text("Turn your phone into the input. Enable Motion, or explore the full instrument with clearly labeled demo signals.").font(.subheadline).foregroundStyle(IOTheme.muted)
                        HStack {
                            Button("Enable Motion", systemImage: "gyroscope") { model.hub.enable("motion") }.buttonStyle(.glassProminent).accessibilityIdentifier("enable-motion")
                            Button("Try Demo") { model.setDemo(true) }.buttonStyle(.glass).accessibilityIdentifier("try-demo")
                        }
                    }.instrumentPanel()
                }
                GlassEffectContainer(spacing: 20) {
                    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(spacing: 18))
                    layout {
                        InstrumentDial(title: "Gain", value: $model.gain, range: 0.25...4, unit: "×", tint: IOTheme.mint)
                        InstrumentDial(title: "Window", value: $model.timeWindow, range: 2...30, unit: "s", tint: IOTheme.ice)
                    }
                }
                Text("Rings map channel amplitude. Their positions are artistic, not physical antenna locations. Drag adds touch telemetry; the Patch bay connects it to outputs.").font(.caption).foregroundStyle(IOTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).padding(.bottom, 20)
        }.accessibilityIdentifier("field-scroll").background(IOTheme.background).sheet(item: $inspector) { SignalInspector(model: model, definition: $0) }
    }
    @ViewBuilder private var display: some View {
        switch model.fieldMode {
        case .orbital: SignalField(model: model)
        case .scope:
            VStack(alignment: .leading, spacing: 12) {
                SectionEyebrow(number: "01", title: "\(model.selected.definition.name.uppercased())")
                TracePlot(reading: model.selected, seconds: model.timeWindow, gain: model.gain, tint: IOTheme.color(for: model.selected.definition.group))
                HStack { Text("−\(Int(model.timeWindow)) s"); Spacer(); Text("NOW") }.font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted)
            }.instrumentPanel()
        case .waterfall:
            VStack(alignment: .leading, spacing: 12) {
                SectionEyebrow(number: "02", title: "CHANNEL HISTORY")
                SignalWaterfall(readings: featured.map { model.hub.reading($0) })
                Text("Motion · Field · Air · Audio · BLE · Speed · Battery · Touch\nBrightness = normalized value; this is not an RF spectrogram.").font(.caption2).foregroundStyle(IOTheme.muted)
            }.instrumentPanel()
        }
    }
    private var selectedReadout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { SectionEyebrow(number: "↳", title: model.selected.definition.name.uppercased()); StatusBadge(status: model.selected.status) }
            HStack(alignment: .firstTextBaseline) {
                Text(model.selected.definition.formatted(model.selected.value)).font(.system(.largeTitle, design: .monospaced).weight(.light)).monospacedDigit()
                Text(model.selected.definition.unit).font(.caption).foregroundStyle(IOTheme.muted)
                Spacer()
                Button("Inspect", systemImage: "slider.horizontal.3") { inspector = model.selected.definition }.buttonStyle(.glass).accessibilityIdentifier("inspect-selected")
            }
            TracePlot(reading: model.selected, seconds: model.timeWindow, tint: IOTheme.color(for: model.selected.definition.group)).frame(height: 68)
        }.instrumentPanel()
    }
    private func shortName(_ id: String) -> String {
        switch id { case "motion.intensity": "MOTION"; case "mag.total": "FIELD"; case "pressure": "AIR"; case "mic.rms": "AUDIO"; case "ble.rssi": "BLE"; case "location.speed": "SPEED"; case "device.battery": "BATTERY"; default: "TOUCH" }
    }
}
