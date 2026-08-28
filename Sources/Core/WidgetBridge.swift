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
/// there are exactly five callers in the app — all of them moments when the
/// home screen is the surface somebody could be looking at:
///
/// 1. **Backgrounding** (`RootView`). The file is rewritten on every state
///    change while the app is open; this is the one reload that pays for all
///    of them.
/// 2. **A background push** (`AppDelegate.didReceiveRemoteNotification`) — v5
///    §5's quiet reload push, sent for EVERY post in a window, the first one
///    included (`mutable-content` on the alert launches the service extension,
///    not the app, so the first post needs this one too).
/// 3. **A changed file written while the app is in the background**
///    (`AppState.publishWidgetSnapshot`) — i.e. the pull that (2) woke the app
///    to make. Without it the app would wake, rewrite `widget.json` and go
///    back to sleep with nobody's tile having moved.
/// 4. **A buddy photo the file already NAMES finishing its download**
///    (`AppState.prefetchWidgetPhotos`) — see `prefetchOwesReload`.
/// 5. **Reset all data** (`AppState.resetAllData`), which is the one place the
///    tile can be showing a circle that no longer exists.
///
/// The SIXTH is not in this file and cannot be: `NotificationService/` is a
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

    /// v5 §3 (P3) — whether a finished photo prefetch owes the home screen a
    /// reload.
    ///
    /// **The race it exists for.** `applyCircleSnapshot` writes `widget.json`
    /// and spends caller 3's reload IMMEDIATELY; the download the file's new
    /// `thumb` names is still in flight, and lands a second or so later. On the
    /// path this phase is about — a quiet push waking a sleeping phone, whose
    /// Today grid never fetched the full-size photo either — the chip therefore
    /// draws the emoji, and nothing reloads again: the next timeline entry is
    /// the window's END. The newest post's face would be missing for exactly
    /// the window it belongs to.
    ///
    /// Two conditions, and both are the rationing rather than the fix:
    ///
    /// - `wrote` counts thumbnails that were NOT already on disk. A pull that
    ///   cached nothing new redraws the same picture, and a reload that redraws
    ///   the same picture is one out of §5-A's ~40–70 a day.
    /// - `backgrounded` is `publishWidgetSnapshot`'s own rule, read at the
    ///   moment the picture lands rather than when the fetch began: while the
    ///   app is on screen the widget behind it has nothing to show anybody, and
    ///   the backgrounding reload (caller 1) picks the photo up on the way out.
    ///
    /// Bounded by construction: the prefetch fetches at most
    /// `WidgetSnapshot.postCap` paths for ONE window, and a photo already
    /// cached costs a `stat` and answers zero.
    static func prefetchOwesReload(wrote: Int, backgrounded: Bool) -> Bool {
        wrote > 0 && backgrounded
    }
}
