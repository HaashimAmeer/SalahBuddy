import Foundation
import UserNotifications

/// Schedules the next 48h of local prayer notifications:
/// - at each prayer's window start: "📸 {Prayer} just came in — be the first
///   in your circle to post!"
/// - 30 minutes before a window closes, if that prayer is still unlogged:
///   "Last call for {Prayer}!"
///
/// Reads settings/profile/logs straight from `Store` (the same files
/// `AppState` persists synchronously), so it never needs a reference to app
/// state. All "now" math goes through `AppClock.now`; triggers are
/// time-interval based relative to `AppClock.now`, so debug time-travel keeps
/// the schedule internally consistent.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private static let idPrefix = "salahbuddy."
    private static let horizonHours: TimeInterval = 48
    private static let lastCallLeadTime: TimeInterval = 30 * 60

    // MARK: - Public API (stable surface other code calls)

    /// Recompute and schedule the next 48h of prayer notifications.
    /// Safe to call repeatedly — always clears previous requests first.
    func reschedule() {
        Task { await rescheduleAsync() }
    }

    /// Remove all pending SalahBuddy notifications.
    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ours = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    // MARK: - Break reminder (v3.2)

    private static let breakReminderID = idPrefix + "breakReminder"

    /// One gentle nudge a few days into a "can't pray" break — dhikr keeps
    /// you connected, and resuming is one tap away.
    func scheduleBreakReminder(daysFromNow days: Int) {
        let content = UNMutableNotificationContent()
        content.title = "We miss you 💜"
        content.body = "No pressure — log some dhikr for a few XP, and tap Resume whenever you're ready."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(days) * 24 * 3600, repeats: false)
        let request = UNNotificationRequest(identifier: Self.breakReminderID,
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelBreakReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.breakReminderID])
    }

    /// Ask the system for notification permission. Returns true if granted.
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Current system authorization status (lets the Settings toggle reflect
    /// reality, including the denied state).
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    private func rescheduleAsync() async {
        let center = UNUserNotificationCenter.current()

        // Always start from a clean slate (only our own requests; the break
        // reminder survives reschedules — it has its own lifecycle).
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) && $0 != Self.breakReminderID }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        let settings = Store.load(Store.settingsFile, default: AppSettings())
        guard settings.notificationsEnabled else { return }

        // v3.2: no prayer nags during a "can't pray" break.
        let breakProfile = Store.load(Store.profileFile, default: UserProfile.fresh(now: AppClock.now))
        guard breakProfile.excusedModeSince == nil else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let now = AppClock.now
        let profile = Store.load(Store.profileFile, default: UserProfile.fresh(now: now))
        let logs = Store.load(Store.logsFile, default: [PrayerLog]())

        let horizon = now.addingTimeInterval(Self.horizonHours * 3600)
        let coords = activeCoordinates(settings: settings)
        let calendar = Calendar.current

        // Cover the 48h horizon: today, tomorrow, and the day after (a window
        // starting just inside the horizon can live on day +2).
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let schedule = PrayerTimeService.schedule(for: day,
                                                            latitude: coords.latitude,
                                                            longitude: coords.longitude,
                                                            method: settings.calcMethod,
                                                            madhab: settings.madhab)
            else { continue }

            for window in schedule.windows {
                scheduleStart(for: window, dayKey: schedule.dayKey,
                              now: now, horizon: horizon, streak: profile.streak,
                              center: center)
                scheduleLastCall(for: window, dayKey: schedule.dayKey,
                                 now: now, horizon: horizon, logs: logs,
                                 center: center)
            }
        }
    }

    private func scheduleStart(for window: PrayerWindow, dayKey: String,
                               now: Date, horizon: Date, streak: Int,
                               center: UNUserNotificationCenter) {
        guard window.start > now, window.start <= horizon else { return }

        // v2 copy: "📸 {Prayer} just came in — be the first in your circle to post!"
        let content = UNMutableNotificationContent()
        content.title = "📸 \(window.prayer.displayName) just came in"
        content.body = "Be the first in your circle to post!"
        content.sound = .default

        add(content: content,
            fireDate: window.start,
            identifier: "\(Self.idPrefix)start.\(dayKey).\(window.prayer.rawValue)",
            now: now, center: center)
    }

    private func scheduleLastCall(for window: PrayerWindow, dayKey: String,
                                  now: Date, horizon: Date, logs: [PrayerLog],
                                  center: UNUserNotificationCenter) {
        let fireDate = window.end.addingTimeInterval(-Self.lastCallLeadTime)
        guard fireDate > now, fireDate <= horizon else { return }
        // Skip if already logged for that schedule day.
        guard !logs.contains(where: { $0.prayer == window.prayer && $0.dayKey == dayKey })
        else { return }

        let content = UNMutableNotificationContent()
        content.title = "Last call for \(window.prayer.displayName)!"
        content.body = "Its window closes in 30 minutes \(window.prayer.emoji)"
        content.sound = .default

        add(content: content,
            fireDate: fireDate,
            identifier: "\(Self.idPrefix)lastcall.\(dayKey).\(window.prayer.rawValue)",
            now: now, center: center)
    }

    private func add(content: UNNotificationContent, fireDate: Date,
                     identifier: String, now: Date,
                     center: UNUserNotificationCenter) {
        // Interval relative to AppClock.now so debug time-travel stays
        // self-consistent (both sides carry the same offset).
        let interval = max(1, fireDate.timeIntervalSince(now))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }

    // MARK: - Helpers

    private func activeCoordinates(settings: AppSettings) -> (latitude: Double, longitude: Double) {
        if settings.useDeviceLocation, let coord = LocationProvider.shared.deviceCoordinate {
            return (coord.latitude, coord.longitude)
        }
        return (settings.fixedLatitude, settings.fixedLongitude)
    }
}
