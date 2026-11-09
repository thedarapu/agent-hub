import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// Light value from the handoff tokens; dark value derived to keep the same warm, calm feel.
    static func token(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

enum Theme {
    static let bg = Color.token(0xF7F5F0, 0x181715)
    static let surface = Color.token(0xFFFFFF, 0x22211E)
    static let sunken = Color.token(0xEFEBE3, 0x2A2925)
    static let sunken2 = Color.token(0xEAE6DD, 0x302E2A)
    static let hairline = Color.token(0xE3DED4, 0x3A3833)
    static let scrim = Color.token(0xCFCAC0, 0x000000)
    static let text = Color.token(0x1F1E1B, 0xEDEAE3)
    static let secondary = Color.token(0x6B6860, 0xA8A398)
    static let needsText = Color.token(0xA35F00, 0xE6A94F)
    static let needsBg = Color.token(0xF3E6CF, 0x3A2E1A)
    static let needsBorder = Color.token(0xE8D4AF, 0x5A4626)
    static let success = Color.token(0x3E7D4F, 0x72BE86)
    static let destructive = Color.token(0xB3261E, 0xF2867E)
    static let code = Color.token(0xF4F1EA, 0x2A2925)
    static let terminalBg = Color(UIColor(hex: 0x1C1B19))

    static func agent(_ a: AgentKind) -> Color {
        switch a {
        case .claude: Color(UIColor(hex: 0xC96442))
        case .codex: Color(UIColor(hex: 0x2F6FDB))
        case .amp: Color(UIColor(hex: 0x7B5BD6))
        case .shell, .ssh: Color.token(0x5E5B54, 0x9A968C)
        }
    }

    // New York for greeting, assistant text and titles; SF Pro elsewhere.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }
    static func mono(_ style: Font.TextStyle = .footnote) -> Font { .system(style, design: .monospaced) }
}

/// Filled dot = running; ring = idle/done.
struct AgentDot: View {
    var agent: AgentKind
    var filled: Bool
    var size: CGFloat = 8

    var body: some View {
        Group {
            if filled {
                Circle().fill(Theme.agent(agent))
            } else {
                Circle().strokeBorder(Theme.agent(agent), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(kind == .primary ? Theme.bg : (kind == .destructive ? Theme.destructive : Theme.text))
            .background {
                Capsule().fill(kind == .primary ? Theme.text : Color.clear)
                if kind != .primary { Capsule().strokeBorder(Theme.hairline) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct IconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Theme.text)
        .accessibilityLabel(label)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }
}
