import SwiftUI

struct ChannelsView: View {
    let model: InstrumentModel
    @State private var search = ""
    @State private var group: SignalGroup?
    @State private var inspector: SignalDefinition?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every accessible channel.").font(.system(.title, design: .serif))
                    Text("\(SignalCatalog.all.count) channels · measured, derived, or awaiting access").font(.caption).foregroundStyle(IOTheme.muted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        filterButton("All", selected: group == nil) { group = nil }
                        ForEach(SignalGroup.allCases, id: \.self) { category in filterButton(category.rawValue, selected: group == category) { group = category } }
                    }
                }.accessibilityIdentifier("channel-groups")
                ForEach(SignalGroup.allCases.filter { group == nil || group == $0 }, id: \.self) { category in
                    let definitions = SignalCatalog.all.filter { $0.group == category && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.explanation.localizedCaseInsensitiveContains(search)) }
                    if !definitions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionEyebrow(number: String(format: "%02d", (SignalGroup.allCases.firstIndex(of: category) ?? 0) + 1), title: category.rawValue.uppercased())
                            ForEach(definitions) { definition in
                                ChannelRow(hub: model.hub, definition: definition) { inspector = definition }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionEyebrow(number: "⊘", title: "WHAT iOS DOESN'T EXPOSE")
                    ForEach(SignalCatalog.restrictions, id: \.0) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.1).frame(width: 24).foregroundStyle(IOTheme.amber)
                            VStack(alignment: .leading, spacing: 4) { Text(item.0).font(.subheadline.weight(.medium)); Text(item.2).font(.caption).foregroundStyle(IOTheme.muted) }
                        }
                    }
                }.instrumentPanel()
            }.padding(16).padding(.bottom, 20)
        }.accessibilityIdentifier("channels-scroll").background(IOTheme.background).searchable(text: $search, prompt: "Find a signal, sensor, or radio")
            .sheet(item: $inspector) { SignalInspector(model: model, definition: $0) }
    }
    private func filterButton(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44) }
            .buttonStyle(.plain).foregroundStyle(selected ? IOTheme.background : IOTheme.muted).background(selected ? IOTheme.mint : IOTheme.panel, in: Capsule())
            .accessibilityIdentifier("channel-filter-\(text)")
    }
}

private struct ChannelRow: View {
    let hub: TelemetryHub
    let definition: SignalDefinition
    let action: () -> Void

    var body: some View {
        // Observe live readings in the row, leaving the native search container stable.
        let reading = hub.reading(definition.id)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: reading.definition.symbol).font(.title3).foregroundStyle(IOTheme.color(for: reading.definition.group)).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(reading.definition.name).font(.subheadline.weight(.medium))
                    HStack(spacing: 8) { StatusBadge(status: reading.status); Text(reading.definition.source).font(.caption2).foregroundStyle(IOTheme.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(reading.definition.formatted(reading.value)).font(.system(.callout, design: .monospaced)).monospacedDigit()
                    Text(reading.definition.unit).font(.caption2).foregroundStyle(IOTheme.muted)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(IOTheme.muted)
            }.padding(14).frame(minHeight: 72).background(IOTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("channel-\(definition.id)")
    }
}

struct SignalInspector: View {
    let model: InstrumentModel
    let definition: SignalDefinition
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showPeer = false
    private var reading: SignalReading { model.hub.reading(definition.id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Label(definition.group.rawValue, systemImage: definition.symbol).foregroundStyle(IOTheme.color(for: definition.group)); Spacer(); StatusBadge(status: reading.status) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(definition.formatted(scrubbedValue ?? reading.value)).font(.system(.largeTitle, design: .monospaced).weight(.light)).monospacedDigit()
                        Text(definition.unit).foregroundStyle(IOTheme.muted)
                    }
                    VStack(spacing: 8) {
                        TracePlot(reading: reading, seconds: model.timeWindow, gain: model.gain, tint: IOTheme.color(for: definition.group), scrubTime: scrub).frame(height: 190)
                            .overlay { GeometryReader { geo in Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { scrub = min(1, max(0, $0.location.x / max(1, geo.size.width))) }.onEnded { _ in }) } }
                        HStack { Text(scrub == nil ? "DRAG TO INSPECT HISTORY" : "HISTORY HELD"); Spacer(); if scrub != nil { Button("Return live") { scrub = nil }.frame(minHeight: 44) } }.font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted)
                    }
                    Text(definition.explanation).font(.body).foregroundStyle(IOTheme.text)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionEyebrow(number: "↳", title: "PROVENANCE")
                        LabeledContent("Source", value: definition.source)
                        LabeledContent("Display range", value: "\(definition.formatted(definition.range.lowerBound)) … \(definition.formatted(definition.range.upperBound)) \(definition.unit)")
                        LabeledContent("History", value: "\(reading.samples.count) samples")
                        if !reading.detail.isEmpty { Text(reading.detail).font(.caption).foregroundStyle(IOTheme.muted) }
                    }.font(.caption).instrumentPanel()
                    if let permission = definition.permission {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.hub.isDemo ? "Demo source" : "Sensor access").font(.headline)
                            if model.hub.isDemo { Text("This value is generated. Switch off Demo to read the phone.").font(.subheadline).foregroundStyle(IOTheme.amber) }
                            else {
                                HStack {
                                    if permission == "peer" {
                                        Button("Pair UWB peer", systemImage: "link") { showPeer = true }.buttonStyle(.glassProminent)
                                    } else if permission == "nfc" {
                                        Button("Read NFC tag", systemImage: "wave.3.right") { model.hub.enable("nfc") }.buttonStyle(.glassProminent)
                                    } else if model.hub.enabled.contains(permission) {
                                        Button("Stop source", systemImage: "stop.fill") { model.hub.disable(permission) }.buttonStyle(.glass).accessibilityIdentifier("inspector-stop-\(permission)")
                                    } else {
                                        Button(permission == "peer" ? "Check capability" : permission == "nfc" ? "Read NFC tag" : "Enable source", systemImage: "play.fill") { model.hub.enable(permission) }.buttonStyle(.glassProminent).accessibilityIdentifier("inspector-enable-\(permission)")
                                    }
                                    if reading.status == .permission || reading.status == .unavailable || reading.status == .restricted {
                                        Button("Settings", systemImage: "arrow.up.forward.app") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(.glass)
                                    }
                                }
                            }
                        }.instrumentPanel()
                    }
                    HStack {
                        Button("Show in Field", systemImage: "circle.hexagongrid") { model.showInField(definition.id); dismiss() }.buttonStyle(.glass)
                        Menu { ForEach(PatchTarget.allCases, id: \.self) { target in Button(target.rawValue) { model.addPatch(sourceID: definition.id, target: target) } } } label: { Label("Patch to…", systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(.glassProminent).accessibilityIdentifier("inspector-patch-menu")
                    }
                    if definition.group == .audio && definition.id.hasPrefix("mic") { SpectrumBars(values: model.hub.spectrum).frame(height: 140); Text("Audio spectrum · normalized FFT bins").font(.caption).foregroundStyle(IOTheme.muted) }
                }.padding(20)
            }.accessibilityIdentifier("inspector-scroll").background(IOTheme.background).navigationTitle(definition.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.large]).sheet(isPresented: $showPeer) { PeerRangingView(model: model) }
    }
    private var scrubbedValue: Double? {
        guard let scrub, let last = reading.samples.last else { return nil }
        let time = last.time - model.timeWindow + scrub * model.timeWindow
        return reading.samples.min(by: { abs($0.time - time) < abs($1.time - time) })?.value
    }
}
