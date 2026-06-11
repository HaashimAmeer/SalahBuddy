import SwiftUI

/// SalahBuddy design tokens — Duolingo-energy: cream background, white cards,
/// chunky 3D buttons, SF Rounded everywhere.
enum Theme {
    static let green     = Color(hex: 0x2DBE6C)  // primary action / success
    static let greenDark = Color(hex: 0x1F9954)
    static let gold      = Color(hex: 0xF5B722)  // XP, badges, streak
    static let cream     = Color(hex: 0xFDF8EF)  // app background
    static let card      = Color.white
    static let ink       = Color(hex: 0x2F3E36)  // primary text
    static let inkSoft   = Color(hex: 0x8A9A90)  // secondary text
    static let coral     = Color(hex: 0xF26B5B)  // missed / danger
    static let sky       = Color(hex: 0x4DA8DA)
    static let lilac     = Color(hex: 0x9B7EDE)

    /// SF Rounded — ALL app text goes through this.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Subtle prayer accent colors: fajr sky, dhuhr gold, asr green,
    /// maghrib coral, isha lilac.
    static func color(for prayer: Prayer) -> Color {
        switch prayer {
        case .fajr: return sky
        case .dhuhr: return gold
        case .asr: return green
        case .maghrib: return coral
        case .isha: return lilac
        }
    }

    /// House spring for all bouncy transitions.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Standard card chrome: white, cornerRadius 20, soft shadow.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}
