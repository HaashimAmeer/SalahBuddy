import UserNotifications
import WidgetKit

/// v5 §5-B — the only way a friend's post reaches a home-screen widget.
///
/// There is no API for "the server pushes an update to a widget" (§5 is blunt
/// about it, and the alternatives it lists are a self-scheduled timeline, which
/// cannot know about other people, and a Live Activity, which is P4). What
/// exists is this: an alert carrying `mutable-content: 1` gives the app about
/// thirty seconds of extension time BEFORE the banner is shown, and
/// `WidgetCenter.reloadAllTimelines()` can be called from it. The tile is
/// current roughly a second after the push lands, with the app closed.
///
/// **Its only job is that one call.** It does not modify the notification, does
/// not fetch anything, does not open the container and does not touch the
/// session. Three reasons, all of them load-bearing:
///
/// - **The tray must not move.** §6's alert collapses to one per prayer window
///   per friend (`apns-collapse-id`), and §5 says to keep that behaviour
///   EXACTLY as it is. Handing `request.content` back unchanged is what
///   guarantees it: there is no attachment, no re-titling, no badge arithmetic
///   here to get wrong.
/// - **It cannot know anything the app does not.** This process has no mirror,
///   no `GameEngine`, no network permission worth using in thirty seconds — so
///   writing `widget.json` from a push payload would be a second, worse writer
///   for a file that has one. What it reloads is whatever the app last wrote;
///   the QUIET push (§5's `not_first` wrinkle) is the half that wakes the app to
///   write a newer one.
/// - **Failure has to be invisible.** If this extension crashes or times out,
///   iOS delivers the original notification anyway. Doing nothing but a
///   synchronous call means there is no window in which it can fail to deliver.
///
/// Note the asymmetry with the quiet push: a background push (`content-
/// available`) never reaches here at all — it goes to the APP's
/// `didReceiveRemoteNotification`. This extension runs only for pushes that
/// have an alert AND `mutable-content: 1`, which today is the first-post
/// announcement and nothing else.
final class NotificationService: UNNotificationServiceExtension {

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler:
                                @escaping (UNNotificationContent) -> Void) {
        // Before the handler, not after: once `contentHandler` is called the
        // system is free to tear this process down, and a reload requested from
        // a dying extension is a reload that may never be sent.
        WidgetCenter.shared.reloadAllTimelines()
        // Unchanged. This is the notification `notify` composed, delivered as
        // `notify` composed it.
        contentHandler(request.content)
    }

    /// Unreachable today: `didReceive` finishes synchronously, so the system's
    /// ~30-second timer never gets a chance to expire. Empty is also the
    /// correct body if it ever does — a service extension that does not call
    /// its handler in time has the ORIGINAL notification delivered for it,
    /// which is precisely what this one would have handed back anyway.
    ///
    /// Overridden rather than omitted so the next person to put an `await`
    /// above finds the hook already here, next to the reason it matters.
    override func serviceExtensionTimeWillExpire() {}
}
