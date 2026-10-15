import SwiftUI

struct TracePlot: View {
    let reading: SignalReading
    var seconds = 10.0
    var gain = 1.0
    var tint = IOTheme.mint
    var scrubTime: Double?
    var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)
            guard reading.samples.count > 1, let last = reading.samples.last else { return }
            let start = last.time - seconds
            let samples = reading.samples.filter { $0.time >= start }
            var trace = Path()
            for (index, sample) in samples.enumerated() {
                let x = (sample.time - start) / seconds * size.width
                let normalized = reading.definition.normalized(sample.value)
                let y = (0.5 - (normalized - 0.5) * gain) * size.height
                if index == 0 { trace.move(to: CGPoint(x: x, y: y)) } else { trace.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(trace, with: .color(tint.opacity(0.15)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            context.stroke(trace, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if let scrubTime {
                let x = scrubTime * size.width
                var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(cursor, with: .color(IOTheme.amber), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }.clipped().background(IOTheme.well, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("\(reading.definition.name) trace")
            .accessibilityValue("\(reading.definition.formatted(reading.value)) \(reading.definition.unit), \(reading.status.rawValue)")
    }
}

func drawGrid(context: inout GraphicsContext, size: CGSize) {
    var grid = Path()
    for i in 0...10 { let x = size.width * Double(i) / 10; grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
    for i in 0...6 { let y = size.height * Double(i) / 6; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
    context.stroke(grid, with: .color(IOTheme.grid), lineWidth: 0.5)
    var axis = Path(); axis.move(to: CGPoint(x: 0, y: size.height / 2)); axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
    context.stroke(axis, with: .color(IOTheme.mint.opacity(0.2)), lineWidth: 0.5)
}

struct SpectrumBars: View {
    let values: [Double]
    var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)
            guard !values.isEmpty else { return }
            let width = size.width / Double(values.count)
            for (index, value) in values.enumerated() {
                let h = max(1, min(1, max(0, value)) * size.height)
                context.fill(Path(roundedRect: CGRect(x: Double(index) * width, y: size.height - h, width: max(1, width - 2), height: h), cornerRadius: 2), with: .color(IOTheme.rose.opacity(0.3 + min(1, max(0, value)) * 0.7)))
            }
        }.background(IOTheme.well, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Microphone spectrum, normalized audio frequency bins")
    }
}

struct SignalWaterfall: View {
    let readings: [SignalReading]
    var body: some View {
        Canvas { context, size in
            guard !readings.isEmpty else { return }
            let rowH = size.height / Double(readings.count)
            for (row, reading) in readings.enumerated() {
                let samples = Array(reading.samples.suffix(100))
                let cellW = size.width / 100
                for (col, sample) in samples.enumerated() {
                    let level = reading.definition.normalized(sample.value)
                    let rect = CGRect(x: Double(100 - samples.count + col) * cellW, y: Double(row) * rowH + 1, width: cellW + 0.5, height: rowH - 2)
                    context.fill(Path(rect), with: .color(IOTheme.color(for: reading.definition.group).opacity(0.06 + 0.85 * level)))
                }
            }
        }.background(IOTheme.well).clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Signal history heatmap. Each row is a normalized channel, brighter means higher within that channel's display range.")
    }
}
