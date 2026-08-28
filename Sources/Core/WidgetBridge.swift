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
/// honour it, and the budget is roughly 40–70 a day. So it is rationed, and
/// there are exactly four callers in the app — all of them moments when the
/// home screen is the surface somebody could be looking at:
///
/// 1. **Backgrounding** (`RootView`). The file is rewritten on every state
///    change while the app is open; this is the one reload that pays for all
///    of them.
/// 2. **A background push** (`AppDelegate.didReceiveRemoteNotification`) — v5
///    §5's quiet reload push, sent for every post after the first one in a
///    window.
/// 3. **A changed file written while the app is in the background**
///    (`AppState.publishWidgetSnapshot`) — i.e. the pull that (2) woke the app
///    to make. Without it the app would wake, rewrite `widget.json` and go
///    back to sleep with nobody's tile having moved.
/// 4. **Reset all data** (`AppState.resetAllData`), which is the one place the
///    tile can be showing a circle that no longer exists.
///
/// The FOURTH is not in this file and cannot be: `NotificationService/` is a
/// separate process and calls `WidgetCenter` itself, on a `mutable-content`
/// alert, which is the only path that reaches a widget with the app closed.
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
