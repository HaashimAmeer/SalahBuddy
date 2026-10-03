import Foundation

/// v5 (mockup): the Today screen is a sideways pager, one page per prayer.
///
/// A page is a WINDOW you can post into — so while traveling a Dhuhr + Asr
/// pair is one page (one post logs both), and before today's Fajr the first
/// page is last night's Isha, whose window runs until Fajr and whose posts
/// carry YESTERDAY's dayKey. Both rules already decide `currentTodayBlock`;
/// this builds every page the same way so the pager and the block that used
/// to sit alone on Today cannot disagree about which window is which.
///
/// PURE, in the `GameEngine` sense: no clock reads, no state — the caller
/// hands in the schedule and `now`.
struct TodayPage: Identifiable, Equatable {
    /// The prayer you post into — the LEAD of a travel pair.
    let prayer: Prayer
    /// The SCHEDULE day the window belongs to (yesterday for last night's Isha).
    let dayKey: String
    /// nil for last night's Isha: its start lives in yesterday's schedule, and
    /// nothing on the page needs it once the window is open.
    let start: Date?
    let end: Date
    var combinedWith: Prayer? = nil
    var isYesterdayIsha: Bool = false

    var id: String { "\(dayKey)-\(prayer.rawValue)" }

    /// "Dhuhr + Asr" for a travel pair, otherwise the prayer's own name.
    var title: String {
        if let partner = combinedWith { return "\(prayer.displayName) + \(partner.displayName)" }
        return prayer.displayName
    }

    /// The window as `GameEngine.tier` wants it, when its start is known.
    var window: PrayerWindow? {
        start.map { PrayerWindow(prayer: prayer, start: $0, end: end) }
    }
}

enum TodayPages {

    /// Every page for the day `schedule` describes, in time order.
    ///
    /// - `yesterdayKey`: last night's dayKey, used only before today's Fajr,
    ///   when the first page is last night's Isha (it ends at today's Fajr).
    static func build(schedule: DaySchedule, yesterdayKey: String,
                      traveling: Bool, now: Date) -> [TodayPage] {
        var pages: [TodayPage] = []

        if let fajr = schedule.window(for: .fajr), now < fajr.start {
            pages.append(TodayPage(prayer: .isha, dayKey: yesterdayKey, start: nil,
                                   end: fajr.start, isYesterdayIsha: true))
        }

        for window in schedule.windows.sorted(by: { $0.start < $1.start }) {
            if traveling, let partner = TravelPairs.partner(of: window.prayer) {
                // The follow prayer is folded into its lead's page.
                guard TravelPairs.lead(of: window.prayer) == window.prayer else { continue }
                let end = schedule.window(for: partner)?.end ?? window.end
                pages.append(TodayPage(prayer: window.prayer, dayKey: schedule.dayKey,
                                       start: window.start, end: end, combinedWith: partner))
            } else {
                pages.append(TodayPage(prayer: window.prayer, dayKey: schedule.dayKey,
                                       start: window.start, end: window.end))
            }
        }
        return pages
    }

    /// The page Today opens on: the latest window that has started (last
    /// night's Isha before Fajr), else the first page.
    static func currentIndex(in pages: [TodayPage], now: Date) -> Int {
        if let first = pages.first, first.isYesterdayIsha { return 0 }
        let started = pages.indices.filter { (pages[$0].start ?? .distantPast) <= now }
        return started.last ?? 0
    }

    /// When the tier you would earn right now next drops — the end of the
    /// current quarter of `window` — or nil outside it.
    static func tierBoundary(for window: PrayerWindow, at now: Date) -> Date? {
        guard now >= window.start, now < window.end else { return nil }
        let quarter = window.end.timeIntervalSince(window.start) / 4
        guard quarter > 0 else { return nil }
        let elapsed = now.timeIntervalSince(window.start)
        let index = min(3, Int(elapsed / quarter))
        return window.start.addingTimeInterval(quarter * Double(index + 1))
    }
}
