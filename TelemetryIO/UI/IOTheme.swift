import SwiftUI

enum IOTheme {
    static let background = Color(red: 0.025, green: 0.045, blue: 0.04)
    static let panel = Color(red: 0.065, green: 0.095, blue: 0.083)
    static let well = Color(red: 0.016, green: 0.032, blue: 0.028)
    static let mint = Color(red: 0.4, green: 0.96, blue: 0.56)
    static let amber = Color(red: 1, green: 0.75, blue: 0.37)
    static let ice = Color(red: 0.56, green: 0.83, blue: 1)
    static let rose = Color(red: 1, green: 0.56, blue: 0.72)
    static let violet = Color(red: 0.78, green: 0.6, blue: 1)
    static let text = Color(red: 0.91, green: 0.95, blue: 0.93)
    static let muted = Color(red: 0.58, green: 0.69, blue: 0.63)
    static let grid = mint.opacity(0.08)
    static let panelRadius: CGFloat = 24
    static func color(for group: SignalGroup) -> Color {
        switch group { case .motion: mint; case .environment: amber; case .location: ice; case .audio: rose; case .radio: violet; case .device: amber; case .interaction: ice; case .output: rose }
    }
}

extension View {
    func instrumentPanel() -> some View {
        padding(18).background(IOTheme.panel, in: RoundedRectangle(cornerRadius: IOTheme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: IOTheme.panelRadius).stroke(.white.opacity(0.07)))
    }
}

struct StatusBadge: View {
    let status: SignalStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(status.rawValue).font(.system(.caption2, design: .monospaced).weight(.semibold))
        }.foregroundStyle(tint).padding(.horizontal, 7).padding(.vertical, 5)
            .background(tint.opacity(0.1), in: Capsule())
            .accessibilityLabel("Source status: \(status.rawValue)")
    }
    private var tint: Color {
        switch status { case .live: IOTheme.mint; case .demo: IOTheme.amber; case .permission, .waiting: IOTheme.ice; case .stale: IOTheme.rose; default: IOTheme.muted }
    }
}

struct SectionEyebrow: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Text(number).foregroundStyle(IOTheme.mint)
            Text(title).foregroundStyle(IOTheme.muted)
            Spacer()
        }.font(.system(.caption, design: .monospaced).weight(.medium)).tracking(1.5)
    }
}
