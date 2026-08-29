import SwiftUI
import UIKit

/// v5 §3 — the app's palette, on somebody's home screen.
///
/// The widget is the app's face next to Mail and Weather, so it uses the app's
/// tokens (`Theme`, compiled into this target) rather than a second palette
/// that would drift: mint ground, dark-green ink, tier colours straight out of
/// the grid's colour language, and NEVER red — a missed prayer is `Theme.mist`
/// here exactly as it is inside the app.
///
/// What `Theme` cannot do on its own is dark mode. Its tokens are fixed hexes
/// chosen for a light app that has always drawn its own background; a widget
/// draws on whatever the person's home screen is, and mint ink on a dark tile
/// is unreadable. So each token below is a PAIR — the app's own colour in
/// light, its dark-ground counterpart in dark — resolved per trait collection
/// by UIKit, which is the only mechanism that works inside a widget's
/// render-once-and-cache lifecycle (an `@Environment(\.colorScheme)` read would
/// be resolved when the timeline was BUILT, not when the tile is drawn).
enum WidgetTheme {

    /// The tile itself. Mint in light, a deep green that keeps the same hue in
    /// dark — the palette is a garden either way, never a black rectangle.
    static let ground: Color = pair(light: Theme.bg, dark: Color(hex: 0x0E2019))

    /// A raised element on the ground: the post chips, the count pill.
    static let surface: Color = pair(light: Theme.surface, dark: Color(hex: 0x18342A))

    /// Primary text.
    static let ink: Color = pair(light: Theme.inkDeep, dark: Color(hex: 0xE7F3EB))

    /// Secondary text — times, labels, the people still to pray.
    static let inkMuted: Color = pair(light: Theme.inkMuted, dark: Color(hex: 0x9CB8A9))

    /// Hairlines and the empty half of the progress track.
    static let divider: Color = pair(light: Theme.greenSoft, dark: Color(hex: 0x24493B))

    /// The accent that carries the count. Same green as the app's primary
    /// action, lifted in dark so it holds against the deep ground.
    static let accent: Color = pair(light: Theme.green, dark: Color(hex: 0x54D392))

    /// The accent at rest — the fill behind a chip that has NOT happened yet,
    /// where solid `accent` would claim the prayer was already prayed.
    static let accentSoft: Color = pair(light: Theme.greenSoft, dark: Color(hex: 0x1D3D30))

    /// XP/streak gold, and nothing else — same rule as in the app.
    static let gold: Color = pair(light: Theme.gold, dark: Color(hex: 0xF7C548))

    /// One post's colour: the grid's language, unchanged (deep green on time,
    /// mid green prayed, amber late, blue for a make-up). Lifted a little in
    /// dark so amber and blue do not sink into the ground.
    static func tier(_ tier: LogTier) -> Color {
        let light: Color = Theme.color(for: tier == .qada ? .qada : .inWindow(tier))
        switch tier {
        case .onTime: return pair(light: light, dark: Color(hex: 0x3FBF7A))
        case .prayed: return pair(light: light, dark: Color(hex: 0x54D392))
        case .lastCall, .closeCall: return pair(light: light, dark: Color(hex: 0xF5B77A))
        case .qada: return pair(light: light, dark: Color(hex: 0x86AEF7))
        }
    }

    /// Resolve at DRAW time, per trait collection.
    private static func pair(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
