import Foundation

// PLACEHOLDER — owned by the stats-settings agent, which will replace this
// file's contents. The no-op API below is the stable surface other code calls.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    /// Recompute and schedule the next 48h of prayer notifications.
    func reschedule() {
        // no-op placeholder
    }

    /// Remove all pending SalahBuddy notifications.
    func cancelAll() {
        // no-op placeholder
    }
}
