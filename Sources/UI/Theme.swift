import SwiftUI

/// SalahBuddy v2 design tokens — "BeReal but more simple, less dark":
/// soft mint background, dark-green text, clean sans-serif, soft chunky
/// flat buttons, never red. Legacy v1 token names are kept as aliases so
/// v1 views compile and pick up the new palette automatically.
enum Theme {
    // MARK: v2 tokens
    static let bg        = Color(hex: 0xECF6EE)   // soft mint background
    static let surface   = Color.white
    static let inkDeep   = Color(hex: 0x16382A)   // dark green primary text
    static let inkMuted  = Color(hex: 0x5F7A6C)
    static let green     = Color(hex: 0x2BAE66)   // primary action
    static let greenSoft = Color(hex: 0xCDEBD8)
    static let gold      = Color(hex: 0xF5B722)   // XP/streak only
    static let qadaBlue  = Color(hex: 0x5B8DEF)
    static let amber     = Color(hex: 0xF2A65A)   // lastCall
    static let lilac     = Color(hex: 0xA98BDB)   // excused
    static let mist      = Color(hex: 0xC9CFCB)   // missed (NEVER red)

    // MARK: legacy aliases (v1 names → v2 palette)
    static let cream     = bg
    static let card      = surface
    static let ink       = inkDeep
    static let inkSoft   = inkMuted
    static let greenDark = Color(hex: 0x1F8A50)   // darker tint of v2 green (pressed states)
    static let coral     = amber                  // v1 "danger" — never red in v2
    static let sky       = qadaBlue

    // MARK: Typography — clean sans-serif (NOT rounded)
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Legacy alias — v1 call sites keep compiling, now render the v2 sans.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        sans(size, weight)
    }

    /// Subtle prayer accent colors (v2 palette, no red).
    static func color(for prayer: Prayer) -> Color {
        switch prayer {
        case .fajr: return qadaBlue
        case .dhuhr: return gold
        case .asr: return green
        case .maghrib: return amber
        case .isha: return lilac
        }
    }

    /// §2 grid color language: deep green = onTime, mid green = prayed,
    /// amber = lastCall, blue = qada, lilac = excused, mist = missed.
    static func color(for cell: GridCellState) -> Color {
        switch cell {
        case .inWindow(let tier):
            switch tier {
            case .onTime: return Color(hex: 0x1F8A50)   // deep green
            case .prayed: return green                  // mid green
            case .lastCall: return amber
            case .closeCall: return amber.opacity(0.8)  // 4th quarter
            case .qada: return qadaBlue                 // defensive (shouldn't occur)
            }
        case .qada: return qadaBlue
        case .missed: return mist
        case .excused: return lilac
        case .future: return greenSoft.opacity(0.5)
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

/// Standard v2 card chrome: white, cornerRadius 22, flat soft shadow.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

// MARK: - Centered modal (v3.6 — design session)

/// A dimmed-backdrop CENTERED pop-up card (instead of a bottom sheet) with an
/// X in the corner — "if it's like a central modal, it would be kind of
/// nicer". Present inside a ZStack with a spring transition:
///
///     if showThing { CenteredModal(onClose: { showThing = false }) { ... } }
struct CenteredModal<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.inkMuted.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)

                content
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
            )
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        }
    }

    private func close() {
        withAnimation(Theme.spring) { onClose() }
    }
}
