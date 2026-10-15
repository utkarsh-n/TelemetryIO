import SwiftUI

struct PatchView: View {
    let model: InstrumentModel
    @State private var sourceID = "motion.intensity"
    @State private var target: PatchTarget = .field
    @State private var choosingSource = false
    @State private var inspectedSource: SignalDefinition?
    @State private var routeFeedback = 0

    var body: some View {
        PatchBayContent(
            model: model,
            sourceID: $sourceID,
            target: $target,
            choosingSource: $choosingSource,
            inspectedSource: $inspectedSource,
            routeFeedback: $routeFeedback
        )
        .navigationTitle("Patch bay")
        .sensoryFeedback(.selection, trigger: routeFeedback)
        .sheet(isPresented: $choosingSource) {
            PatchSourcePicker(hub: model.hub, selection: $sourceID)
        }
        .sheet(item: $inspectedSource) { SignalInspector(model: model, definition: $0) }
    }
}

private struct PatchBayContent: View {
    let model: InstrumentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var sourceID: String
    @Binding var target: PatchTarget
    @Binding var choosingSource: Bool
    @Binding var inspectedSource: SignalDefinition?
    @Binding var routeFeedback: Int

    private var duplicate: Bool { model.patches.contains { $0.sourceID == sourceID && $0.target == target } }
    private var atCapacity: Bool { model.patches.count >= 16 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                introduction
                presets
                composer
                HStack {
                    Text("CONNECTED ROUTES")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(IOTheme.muted)
                    Spacer()
                    Text("\(model.patches.filter(\.enabled).count) ENABLED")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(IOTheme.mint)
                }
                if model.patches.isEmpty {
                    ContentUnavailableView {
                        Label("Make a connection", systemImage: "cable.connector")
                    } description: {
                        Text("Choose an input and a destination, or try a preset above.")
                    }
                    .foregroundStyle(IOTheme.muted)
                    .frame(minHeight: 160)
                }
                ForEach(model.patches) { patch in
                    PatchRouteLiveCard(
                        model: model,
                        patch: binding(for: patch),
                        animationActive: !choosingSource && inspectedSource == nil,
                        inspect: { inspectedSource = model.hub.reading(patch.sourceID).definition },
                        remove: {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { model.removePatch(patch.id) }
                            routeFeedback += 1
                        }
                    )
                }
                PatchOutputControls(model: model)
                Text("Routes change this app’s field, local audio and haptics. Input readings keep their original units; radio hardware is observed only through the data iOS exposes.")
                    .font(.footnote)
                    .foregroundStyle(IOTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier("patch-scroll")
        .background(IOTheme.background)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Signal → sensation.")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(IOTheme.text)
            Text("Tilt becomes motion. Sound becomes an orbit. Your touch becomes a tone. Wire the phone’s inputs into an instrument.")
                .font(.subheadline)
                .foregroundStyle(IOTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.paused {
                Label("Capture paused · Routes resume with capture", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(IOTheme.amber)
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("START WITH A PATCH")
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .tracking(1)
                .foregroundStyle(IOTheme.muted)
            GlassEffectContainer(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        preset("Motion → field", symbol: "gyroscope", tint: IOTheme.mint)
                        preset("Sound → orbit", symbol: "mic", tint: IOTheme.amber)
                        preset("Touch → tone", symbol: "hand.draw", tint: IOTheme.rose)
                    }
                }
                .contentMargins(.vertical, 3)
                .accessibilityIdentifier("patch-presets")
            }
        }
    }

    private func preset(_ name: String, symbol: String, tint: Color) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { model.applyPreset(name) }
            routeFeedback += 1
        } label: {
            Label(name, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 5)
                .frame(minHeight: 44)
        }
        .buttonStyle(.glass)
        .tint(tint)
        .accessibilityIdentifier("patch-preset-\(name)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("NEW CONNECTION")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .tracking(1)
                Spacer()
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(IOTheme.mint)
            }
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    PatchSourceButton(hub: model.hub, sourceID: sourceID) {
                        choosingSource = true
                    }

                    PatchDestinationMenu(selectedTarget: target, selection: $target)
                        .equatable()

                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                            model.addPatch(sourceID: sourceID, target: target)
                        }
                        routeFeedback += 1
                    } label: {
                        Label(atCapacity ? "16 routes connected" : duplicate ? "Already connected" : "Connect route", systemImage: duplicate || atCapacity ? "checkmark" : "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(IOTheme.mint)
                    .disabled(duplicate || atCapacity)
                    .accessibilityIdentifier("patch-connect")
                }
            }
            PatchSourceGuidance(hub: model.hub, sourceID: sourceID)
        }
        .foregroundStyle(IOTheme.text)
        .padding(18)
        .background(IOTheme.panel, in: RoundedRectangle(cornerRadius: 24))
    }

    private func binding(for patch: ModulationPatch) -> Binding<ModulationPatch> {
        Binding(get: { model.patches.first { $0.id == patch.id } ?? patch }, set: { replacement in
            guard let index = model.patches.firstIndex(where: { $0.id == patch.id }) else { return }
            model.patches[index] = replacement
        })
    }
}

private struct PatchSourceButton: View {
    let hub: TelemetryHub
    let sourceID: String
    let action: () -> Void

    var body: some View {
        // Keep live status observation out of the composer and native menu host.
        let source = hub.reading(sourceID)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: source.definition.symbol)
                    .frame(width: 26)
                    .foregroundStyle(IOTheme.color(for: source.definition.group))
                VStack(alignment: .leading, spacing: 3) {
                    Text("INPUT").font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted)
                    Text(source.definition.name).font(.subheadline.weight(.medium)).foregroundStyle(IOTheme.text)
                }
                Spacer(minLength: 8)
                patchStatus(source.status)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(IOTheme.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .accessibilityLabel("Input: \(source.definition.name), \(source.status.rawValue)")
        .accessibilityHint("Choose the signal that drives this route.")
        .accessibilityIdentifier("patch-source-picker")
    }
}

private struct PatchSourceGuidance: View {
    let hub: TelemetryHub
    let sourceID: String

    var body: some View {
        let status = hub.reading(sourceID).status
        Text(status.hasData ? "The source range becomes 0–1, then depth and smoothing shape its influence." : "This input is \(status.rawValue.lowercased()). You can wire it now; the route waits for accessible data.")
            .font(.footnote)
            .foregroundStyle(IOTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PatchOutputControls: View {
    let model: InstrumentModel

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Text("PHYSICAL OUTPUTS")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .tracking(1)
                .foregroundStyle(IOTheme.muted)
            Toggle(isOn: $model.soundEnabled) {
                Label("Local oscillator", systemImage: "speaker.wave.2")
                    .foregroundStyle(IOTheme.text)
            }
            .tint(IOTheme.amber)
            .frame(minHeight: 44)
            .accessibilityIdentifier("patch-sound-toggle")
            Toggle(isOn: $model.hapticsEnabled) {
                Label("Haptic pulses", systemImage: "hand.tap")
                    .foregroundStyle(IOTheme.text)
            }
            .tint(IOTheme.rose)
            .frame(minHeight: 44)
            .accessibilityIdentifier("patch-haptics-toggle")
            if !model.supportsHaptics {
                Label("Haptic hardware is unavailable in this runtime.", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(IOTheme.muted)
            }
            if model.soundEnabled, let error = model.outputError {
                Label("Audio unavailable: \(error)", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(IOTheme.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.paused ? "Capture is paused, so physical outputs are stopped. Enabled outputs resume with capture." : "Outputs start muted. Connect an available input to Tone pitch or Tone level before enabling audio. Microphone-to-tone routes can pick up the phone’s own speaker.")
                .font(.footnote)
                .foregroundStyle(IOTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.patches.contains(where: { $0.sourceID.hasPrefix("touch.") }) {
                Text("Touch routes respond to drags in the Field tab.")
                    .font(.footnote)
                    .foregroundStyle(IOTheme.ice)
            }
        }
        .padding(18)
        .background(IOTheme.panel, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct PatchRouteLiveCard: View {
    let model: InstrumentModel
    @Binding var patch: ModulationPatch
    let animationActive: Bool
    let inspect: () -> Void
    let remove: () -> Void

    var body: some View {
        // A route observes its live input/output without invalidating the whole bay.
        PatchRouteCard(
            patch: $patch,
            reading: model.hub.reading(patch.sourceID),
            outputReadout: outputReadout(patch.target),
            muted: outputMuted(patch.target),
            running: model.hub.isRunning && !model.paused,
            animationActive: animationActive,
            inspect: inspect,
            remove: remove
        )
    }

    private func outputMuted(_ target: PatchTarget) -> Bool {
        switch target {
        case .pitch, .amplitude: !model.soundEnabled || model.paused || !model.hub.isRunning
        case .haptic: !model.hapticsEnabled || model.paused || !model.hub.isRunning
        default: false
        }
    }

    private func outputReadout(_ target: PatchTarget) -> String {
        guard !outputMuted(target) else { return "MUTED" }
        let outputID: String?
        switch target {
        case .pitch: outputID = "output.pitch"
        case .amplitude: outputID = "output.level"
        case .haptic: outputID = "output.haptic"
        default: outputID = nil
        }
        if let outputID {
            let reading = model.hub.reading(outputID)
            guard reading.status.hasData else { return reading.status.rawValue }
            return "\(reading.definition.formatted(reading.value)) \(reading.definition.unit)"
        }
        return String(format: "%.0f %%", (model.outputs[target] ?? 0) * 100)
    }
}

private struct PatchDestinationMenu: View, Equatable {
    let selectedTarget: PatchTarget
    let selection: Binding<PatchTarget>

    // Live source readings should not rebuild the native menu while it is open.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTarget == rhs.selectedTarget
    }

    var body: some View {
        Menu {
            ForEach(PatchTarget.allCases, id: \.self) { output in
                Button {
                    selection.wrappedValue = output
                } label: {
                    Label(output.rawValue, systemImage: selectedTarget == output ? "checkmark" : output.symbol)
                }
                .accessibilityIdentifier("patch-destination-\(output.rawValue)")
                .accessibilityAddTraits(selectedTarget == output ? .isSelected : [])
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedTarget.symbol).frame(width: 26).foregroundStyle(IOTheme.ice)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DESTINATION").font(.system(.caption2, design: .monospaced)).foregroundStyle(IOTheme.muted)
                    Text(selectedTarget.rawValue).font(.subheadline.weight(.medium)).foregroundStyle(IOTheme.text)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(IOTheme.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .accessibilityLabel("Destination: \(selectedTarget.rawValue)")
        .accessibilityIdentifier("patch-target-picker")
    }
}

private struct PatchRouteCard: View {
    @Binding var patch: ModulationPatch
    let reading: SignalReading
    let outputReadout: String
    let muted: Bool
    let running: Bool
    let animationActive: Bool
    let inspect: () -> Void
    let remove: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { IOTheme.color(for: reading.definition.group) }
    private var mapped: Double {
        ModulationMath.mapped(reading.value ?? reading.definition.range.lowerBound, definition: reading.definition, depth: patch.depth, inverted: patch.inverted)
    }
    private var flowing: Bool { patch.enabled && [.live, .demo].contains(reading.status) && running }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: inspect) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: reading.definition.symbol)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(reading.definition.name).font(.headline).foregroundStyle(IOTheme.text)
                        Label(patch.target.rawValue, systemImage: "arrow.turn.down.right")
                            .font(.subheadline).foregroundStyle(IOTheme.muted)
                    }
                    Spacer(minLength: 0)
                    patchStatus(reading.status)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(IOTheme.muted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect input \(reading.definition.name), \(reading.status.rawValue)")
            .accessibilityIdentifier("patch-inspect-\(patch.sourceID)-\(patch.target.rawValue)")
            PatchCircuit(
                normalized: reading.normalized,
                mapped: mapped,
                smoothing: patch.smoothing,
                outputReadout: outputReadout,
                sourceValue: "\(reading.definition.formatted(reading.value)) \(reading.definition.unit)",
                tint: tint,
                enabled: flowing,
                animationActive: animationActive,
                hasData: reading.status.hasData,
                inverted: patch.inverted,
                muted: muted
            )
            .accessibilityIdentifier("patch-path-\(patch.sourceID)-\(patch.target.rawValue)")
            GlassEffectContainer(spacing: 12) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        enableControl
                        HStack(spacing: 12) { invertControl; Spacer(); removeControl }
                    }
                } else {
                    HStack(spacing: 12) { enableControl; invertControl; removeControl }
                }
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 16) { dials }
                } else {
                    HStack(alignment: .top, spacing: 20) { dials }
                }
            }
            Text(patch.enabled ? (patch.inverted ? "Inversion flips 0 ↔ 1 before depth is applied. Smoothing steadies the response." : "Depth sets the influence. Smoothing trades quick response for a steadier signal.") : "Route bypassed. The input can still be measured; this connection adds no modulation.")
                .font(.footnote)
                .foregroundStyle(IOTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(IOTheme.panel, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(tint.opacity(patch.enabled ? 0.16 : 0.04), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("patch-route-\(patch.sourceID)-\(patch.target.rawValue)")
    }

    @ViewBuilder private var dials: some View {
        InstrumentDial(title: "Depth", value: $patch.depth, range: 0...1, unit: "%", tint: tint)
        InstrumentDial(title: "Smoothing", value: $patch.smoothing, range: 0...1, unit: "%", tint: IOTheme.ice)
    }

    private var enableControl: some View {
        Toggle("Route", isOn: $patch.enabled)
            .tint(tint)
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityLabel("Enable \(reading.definition.name) to \(patch.target.rawValue)")
            .accessibilityIdentifier("patch-enable-\(patch.sourceID)-\(patch.target.rawValue)")
    }

    private var invertControl: some View {
        Button { patch.inverted.toggle() } label: {
            Label(patch.inverted ? "Inverted" : "Invert", systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .buttonStyle(.glass)
        .tint(patch.inverted ? IOTheme.amber : IOTheme.muted)
        .accessibilityLabel("Invert \(reading.definition.name)")
        .accessibilityValue(patch.inverted ? "On" : "Off")
        .accessibilityIdentifier("patch-invert-\(patch.sourceID)-\(patch.target.rawValue)")
    }

    private var removeControl: some View {
        Button(role: .destructive, action: remove) {
            Image(systemName: "trash")
                .font(.subheadline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Remove \(reading.definition.name) route")
        .accessibilityIdentifier("patch-remove-\(patch.sourceID)-\(patch.target.rawValue)")
    }
}

private struct PatchCircuit: View {
    let normalized: Double
    let mapped: Double
    let smoothing: Double
    let outputReadout: String
    let sourceValue: String
    let tint: Color
    let enabled: Bool
    let animationActive: Bool
    let hasData: Bool
    let inverted: Bool
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                caption("SOURCE")
                caption("NORMALIZE")
                caption("SMOOTH")
                caption("OUTPUT")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !enabled || !visible || !animationActive)) { timeline in
                Canvas { context, size in
                    let y = size.height / 2
                    let points = (0..<4).map { CGPoint(x: size.width * (Double($0) + 0.5) / 4, y: y) }
                    var grid = Path()
                    for x in stride(from: 0.0, to: size.width, by: 18) {
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for lineY in stride(from: 0.0, to: size.height, by: 18) {
                        grid.move(to: CGPoint(x: 0, y: lineY)); grid.addLine(to: CGPoint(x: size.width, y: lineY))
                    }
                    context.stroke(grid, with: .color(IOTheme.grid), lineWidth: 0.5)
                    for segment in 0..<3 {
                        let a = points[segment], b = points[segment + 1]
                        let c1 = CGPoint(x: a.x + (b.x - a.x) * 0.45, y: y + 24)
                        let c2 = CGPoint(x: b.x - (b.x - a.x) * 0.45, y: y - 24)
                        var cable = Path(); cable.move(to: a); cable.addCurve(to: b, control1: c1, control2: c2)
                        context.stroke(cable, with: .color(tint.opacity(enabled ? 0.12 : 0.03)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        context.stroke(cable, with: .color(tint.opacity(enabled ? 0.72 : 0.22)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: enabled ? [] : [3, 4]))
                        if enabled && !reduceMotion && animationActive {
                            let phase = (timeline.date.timeIntervalSinceReferenceDate * (0.45 + normalized * 0.6) + Double(segment) * 0.21).truncatingRemainder(dividingBy: 1)
                            let point = cubic(phase, a, c1, c2, b)
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(tint))
                        }
                    }
                    for (index, point) in points.enumerated() {
                        let nodeColor = index == 3 && muted ? IOTheme.muted : tint
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(IOTheme.well))
                        context.stroke(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(nodeColor.opacity(enabled ? 0.85 : 0.3)), lineWidth: 1.3)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(nodeColor.opacity(enabled ? 1 : 0.25)))
                    }
                }
            }
            .frame(height: 62)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .onDisappear { visible = false }
            HStack(alignment: .top, spacing: 0) {
                readout(sourceValue)
                readout(hasData ? String(format: "%.2f", normalized) : "—")
                readout(String(format: "τ %.2f s", 0.015 + smoothing * 1.5))
                readout(outputReadout)
            }
        }
        .padding(.vertical, 12)
        .background(IOTheme.well, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal path")
        .accessibilityValue("Source \(sourceValue), normalized \(hasData ? String(format: "%.2f", normalized) : "unavailable"), \(inverted ? "inverted, " : "")depth result \(hasData ? String(format: "%.2f", mapped) : "unavailable"), smoothing time constant \(String(format: "%.2f seconds", 0.015 + smoothing * 1.5)), combined destination output \(outputReadout).")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(IOTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
    }
    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(enabled ? tint : IOTheme.muted)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
    private func cubic(_ t: Double, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                       y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
    }
}

private struct PatchSourcePicker: View {
    let hub: TelemetryHub
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var definitions: [SignalDefinition] {
        SignalCatalog.all.filter { $0.group != .output && (query.isEmpty || "\($0.name) \($0.group.rawValue) \($0.source)".localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(SignalGroup.allCases.filter { $0 != .output }, id: \.self) { group in
                    let signals = definitions.filter { $0.group == group }
                    if !signals.isEmpty {
                        Section(group.rawValue) {
                            ForEach(signals) { definition in
                                PatchSourceRow(hub: hub, definition: definition, selectedSnapshot: selection == definition.id) {
                                    selection = definition.id
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("patch-input-list")
            .background(IOTheme.background)
            .searchable(text: $query, prompt: "Signal, group or sensor")
            .navigationTitle("Choose an input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay {
                if definitions.isEmpty { ContentUnavailableView.search(text: query).foregroundStyle(IOTheme.muted) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

private struct PatchSourceRow: View {
    let hub: TelemetryHub
    let definition: SignalDefinition
    let selectedSnapshot: Bool
    let action: () -> Void

    var body: some View {
        // Observe live readings in the row, leaving the native search container stable.
        let reading = hub.reading(definition.id)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: definition.symbol)
                    .foregroundStyle(IOTheme.color(for: definition.group))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.name).font(.subheadline.weight(.medium)).foregroundStyle(IOTheme.text)
                    Text("\(definition.formatted(reading.value)) \(definition.unit)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(IOTheme.muted)
                }
                Spacer()
                patchStatus(reading.status)
                if selectedSnapshot { Image(systemName: "checkmark").foregroundStyle(IOTheme.mint) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .listRowBackground(IOTheme.panel)
        .accessibilityLabel("\(definition.name), \(reading.status.rawValue), \(definition.formatted(reading.value)) \(definition.unit)")
        .accessibilityIdentifier("patch-input-\(definition.id)")
    }
}

private func patchStatus(_ status: SignalStatus) -> some View {
    StatusBadge(status: status)
}
