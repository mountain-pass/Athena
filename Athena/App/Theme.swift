import SwiftUI

/// Bailongma-inspired dark terminal aesthetic, in English.
enum Theme {
    // Backgrounds
    static let bg        = Color(hex: 0x080D14)   // page background
    static let panel     = Color(hex: 0x0D1520)   // card/panel background
    static let panelAlt  = Color(hex: 0x111A27)   // slightly raised
    static let border    = Color(hex: 0x1B2735)

    // Accents
    static let amber     = Color(hex: 0xF5A64A)   // primary accent (Bailongma orange)
    static let amberDim  = Color(hex: 0x8A5A2A)
    static let green     = Color(hex: 0x3DDC84)   // "online" / success
    static let blue      = Color(hex: 0x4A9EF5)
    static let red       = Color(hex: 0xE5534B)

    // Text
    static let text      = Color(hex: 0xE6EDF3)
    static let textDim   = Color(hex: 0x8B98A8)
    static let textFaint = Color(hex: 0x55606E)

    // Typography — monospace everywhere for the terminal look.
    // uiScale bumps every font in the app uniformly.
    static let uiScale: CGFloat = 1.2
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight, design: .monospaced)
    }
    static let label   = mono(10, weight: .medium)  // tiny section labels: "HEARTBEAT"
    static let body    = mono(13)
    static let title   = mono(16, weight: .semibold)
    static let bigStat = mono(22, weight: .bold)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

/// Standard panel chrome: rounded card with hairline border and tiny header label.
struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

/// Tiny uppercase section label, e.g. "ACTION LOG".
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.textFaint
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .kerning(1.5)
            .foregroundStyle(color)
    }
}

/// Small status dot + label, e.g. "● CONNECTED".
struct StatusDot: View {
    let on: Bool
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Theme.green : Theme.red).frame(width: 6, height: 6)
            Text(label).font(Theme.label).foregroundStyle(Theme.textDim)
        }
    }
}
