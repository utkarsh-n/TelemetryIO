import SwiftUI

struct SignalField: View {
    let model: InstrumentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ids = ["motion.intensity", "mag.total", "pressure", "mic.rms", "ble.rssi", "location.speed", "device.battery", "touch.x"]

    var body: some View {
        let motion = reduceMotion ? OrbitalMotion() : model.orbitalMotion
        Canvas { context, size in
            draw(context: &context, size: size, motion: motion)
        }
        .hueRotation(.degrees((model.outputs[.hue] ?? 0) * 180))
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SIGNAL FIELD").font(.system(.caption2, design: .monospaced)).tracking(2)
                Text(model.hub.isDemo ? "SIMULATED INPUTS" : "DEVICE INPUTS").font(.system(size: 9, design: .monospaced)).tracking(1.4).foregroundStyle(model.hub.isDemo ? IOTheme.amber : IOTheme.muted)
            }.padding(16)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text("X \(Int(model.touchPoint.x * 100))  Y \(Int(model.touchPoint.y * 100))")
                Spacer()
                Text("DRAG TO PLAY").foregroundStyle(IOTheme.ice)
            }.font(.system(.caption2, design: .monospaced)).padding(16).foregroundStyle(IOTheme.muted)
        }
        .background(IOTheme.well, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(IOTheme.mint.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { model.touch($0.location, size: geometry.size) }.onEnded { model.touch($0.location, size: geometry.size, ended: true) })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Interactive signal field")
        .accessibilityValue("\(model.liveCount) live channels. Selected \(model.selected.definition.name). \(model.selected.definition.formatted(model.selected.value)) \(model.selected.definition.unit)")
        .accessibilityHint("Drag to change touch X and Y. Rings show normalized channel amplitude; positions are artistic, not physical bearings.")
        .accessibilityAction(named: "Increase touch X") { model.hub.recordTouch(x: min(100, (model.hub.reading("touch.x").value ?? 0) + 10), y: model.touchPoint.y * 100) }
        .accessibilityAction(named: "Decrease touch X") { model.hub.recordTouch(x: max(0, (model.hub.reading("touch.x").value ?? 0) - 10), y: model.touchPoint.y * 100) }
    }

    private func draw(context: inout GraphicsContext, size: CGSize, motion: OrbitalMotion) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.49)
        let radius = min(size.width * 0.38, size.height * 0.34)
        let energy = model.outputs[.field] ?? (model.selected.status.hasData ? model.selected.normalized * 0.5 : 0)
        var grid = Path()
        for step in -4...4 {
            let x = center.x + Double(step) * radius / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            let y = center.y + Double(step) * radius / 4
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(IOTheme.mint.opacity(0.035)), lineWidth: 0.5)
        for ring in 0..<8 {
            let reading = model.hub.reading(ids[ring])
            let color = IOTheme.color(for: reading.definition.group)
            let active = [.live, .demo].contains(reading.status)
            let level = active ? reading.normalized : 0
            let r = radius * (0.52 + Double(ring) * 0.085 + energy * 0.04)
            let tilt = Double(ring) * .pi / 8 + motion.tiltPhase + model.touchPoint.x * 0.35
            var path = Path()
            for point in 0...160 {
                let angle = Double(point) / 160 * 2 * .pi
                let px = cos(angle) * r
                let py = sin(angle) * r * (0.22 + Double(ring % 3) * 0.11)
                let q = CGPoint(x: center.x + px * cos(tilt) - py * sin(tilt), y: center.y + px * sin(tilt) + py * cos(tilt))
                if point == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            context.stroke(path, with: .color(color.opacity(active ? 0.38 : 0.11)), lineWidth: 0.7)
            if active {
                let angle = motion.ringPhases[ring] + Double(ring) * 0.9
                let px = cos(angle) * r, py = sin(angle) * r * (0.22 + Double(ring % 3) * 0.11)
                let position = CGPoint(x: center.x + px * cos(tilt) - py * sin(tilt), y: center.y + px * sin(tilt) + py * cos(tilt))
                let dotRadius = 2.5 + level * 4
                context.fill(Path(ellipseIn: CGRect(x: position.x - dotRadius * 3, y: position.y - dotRadius * 3, width: dotRadius * 6, height: dotRadius * 6)), with: .color(color.opacity(0.06)))
                context.fill(Path(ellipseIn: CGRect(x: position.x - dotRadius, y: position.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)), with: .color(color))
            }
        }
        // Phone silhouette, a diagram rather than an antenna-placement claim.
        let phone = CGRect(x: center.x - 25, y: center.y - 49, width: 50, height: 98)
        context.fill(Path(roundedRect: phone, cornerRadius: 10), with: .color(IOTheme.background.opacity(0.95)))
        context.stroke(Path(roundedRect: phone, cornerRadius: 10), with: .color(IOTheme.mint.opacity(0.8)), lineWidth: 1)
        context.fill(Path(roundedRect: CGRect(x: center.x - 9, y: center.y - 41, width: 18, height: 4), cornerRadius: 2), with: .color(IOTheme.mint.opacity(0.4)))
        context.draw(Text("I/O").font(.system(size: 16, weight: .light, design: .monospaced)).foregroundColor(IOTheme.text), at: center)
        if model.gestureActive {
            let p = CGPoint(x: model.touchPoint.x * size.width, y: model.touchPoint.y * size.height)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)), with: .color(IOTheme.ice), lineWidth: 1)
            var cable = Path(); cable.move(to: center); cable.addLine(to: p)
            context.stroke(cable, with: .color(IOTheme.ice.opacity(0.4)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
        }
        let labels = [("MOTION", IOTheme.mint, CGPoint(x: size.width * 0.16, y: size.height * 0.23)), ("RADIO", IOTheme.violet, CGPoint(x: size.width * 0.84, y: size.height * 0.30)), ("AIR", IOTheme.amber, CGPoint(x: size.width * 0.18, y: size.height * 0.72)), ("AUDIO", IOTheme.rose, CGPoint(x: size.width * 0.83, y: size.height * 0.70))]
        for (name, color, position) in labels { context.draw(Text(name).font(.system(size: 9, design: .monospaced)).tracking(1.5).foregroundColor(color.opacity(0.8)), at: position) }
    }
}
