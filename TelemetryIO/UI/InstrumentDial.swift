import SwiftUI

/// The same relative-drag mechanics as Spectra and Gyre, with a visible linear alternative.
struct InstrumentDial: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    @State private var startPosition: Double?
    @State private var resetValue: Double
    @State private var feedbackTick = 0
    @FocusState private var focused: Bool

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, tint: Color) {
        self.title = title
        _value = value
        self.range = range
        self.unit = unit
        self.tint = tint
        _resetValue = State(initialValue: value.wrappedValue)
    }

    private var span: Double { max(0.000_001, range.upperBound - range.lowerBound) }
    private var position: Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }
    private var displayValue: String {
        let shown = unit == "%" && range.upperBound <= 1 ? value * 100 : value
        let format = unit == "%" || span >= 100 ? "%.0f" : span >= 10 ? "%.1f" : "%.2f"
        return "\(String(format: format, shown))\(unit.isEmpty ? "" : " \(unit)")"
    }

    var body: some View {
        VStack(spacing: 7) {
            dial
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(IOTheme.muted)
                .multilineTextAlignment(.center)
            Text(displayValue)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(IOTheme.text)
                .contentTransition(.numericText(value: value))
            Slider(value: sliderBinding, in: range, step: span / 20)
                .tint(tint)
                .frame(minHeight: 44)
                .accessibilityLabel("\(title), slider")
                .accessibilityValue(displayValue)
                .accessibilityIdentifier("dial-slider-\(title)")
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: feedbackTick)
    }

    private var dial: some View {
        ZStack {
            InstrumentDialArc(position: 1)
                .stroke(IOTheme.muted.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            InstrumentDialArc(position: position)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: tint.opacity(0.45), radius: 5)
            ForEach(0..<21, id: \.self) { tick in
                Capsule()
                    .fill(tint.opacity(tick <= Int((position * 20).rounded()) ? 0.85 : 0.18))
                    .frame(width: tick.isMultiple(of: 5) ? 2 : 1, height: tick.isMultiple(of: 5) ? 6 : 3)
                    .offset(y: -47)
                    .rotationEffect(.degrees(-135 + Double(tick) * 13.5))
            }
            ZStack {
                Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1)
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 12)
                    .offset(y: -22)
                    .rotationEffect(.degrees(-135 + 270 * position))
                Circle().fill(tint.opacity(0.6)).frame(width: 5, height: 5)
            }
            .frame(width: 66, height: 66)
            .glassEffect(.regular.tint(tint.opacity(startPosition == nil ? 0.1 : 0.25)).interactive(), in: .circle)
            .scaleEffect(startPosition == nil ? 1 : 1.045)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.2), value: startPosition == nil)
        }
        .frame(width: 104, height: 104)
        .contentShape(Circle())
        .gesture(turn)
        .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        .onChange(of: dragging) { _, active in if !active { startPosition = nil } }
        .onDisappear { startPosition = nil }
        .focusable()
        .focused($focused)
        .onKeyPress(.upArrow) { nudge(1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(displayValue)
        .accessibilityHint("Drag up or right to increase. Double tap to reset. A slider follows this dial.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset") { reset() }
        .accessibilityIdentifier("dial-\(title)")
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { next in
            setPosition((next - range.lowerBound) / span)
        })
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { gesture in
                if startPosition == nil { startPosition = position; focused = true }
                let travel = Double(gesture.translation.width - gesture.translation.height) / 230
                setPosition((startPosition ?? position) + travel)
            }
            .onEnded { _ in startPosition = nil }
    }

    private func setPosition(_ raw: Double) {
        let p = min(1, max(0, raw.isFinite ? raw : 0))
        let step = (p * 20).rounded()
        let next = range.lowerBound + span * step / 20
        guard abs(next - value) > span * 0.000_01 else { return }
        value = next
        // A discrete five-percent step is the only feedback event while turning.
        feedbackTick += 1
    }

    private func nudge(_ direction: Double) { setPosition(position + direction / 20) }

    private func reset() {
        guard value != resetValue else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            value = min(range.upperBound, max(range.lowerBound, resetValue))
        }
        feedbackTick += 1
    }
}

private struct InstrumentDialArc: Shape {
    var position: Double
    var animatableData: Double {
        get { position }
        set { position = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - 10
        let steps = max(1, Int(max(0, position) * 72))
        var path = Path()
        for step in 0...steps {
            let angle = (-135 + 270 * position * Double(step) / Double(steps)) * .pi / 180
            let point = CGPoint(x: rect.midX + sin(angle) * radius, y: rect.midY - cos(angle) * radius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
