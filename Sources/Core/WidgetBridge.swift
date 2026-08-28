import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// v5 §3/§5 — the app's one line of contact with the widget process.
///
/// Deliberately not folded into `WidgetSnapshotBuilder`: that file is pure and
/// this one is an effect, and the reason to keep them apart is the same reason
/// `GameEngine` holds no I/O. It is also the only place in the app that imports
/// `WidgetKit`, so what the app can ask the home screen to do is one file long.
///
/// §5 is blunt about what is possible here: there is no API for "push an update
/// to a home-screen widget". A reload is a REQUEST, the system decides when to
/// honour it, and the budget is roughly 40–70 a day. So this is called once per
/// backgrounding and from nowhere else — the file itself is rewritten on every
/// state change, and a widget behind a foreground app has nobody looking at it.
/// P3 adds the second caller (an NSE, on a friend's push); P4 adds the third.
enum WidgetBridge {

    /// Ask WidgetKit to re-read `widget.json`.
    ///
    /// A no-op wherever `WidgetKit` is unavailable, and harmless on a build with
    /// no widget installed — the framework simply has nothing to reload.
    static func reloadAllTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
