import Foundation
import SwiftUI

/// Time formatting helpers for the Today screen + onboarding (home-agent owned).
enum HomeTimeFormat {

    /// Compact countdown: "2h 14m", "14m 5s", "45s". Never negative.
    static func countdown(to target: Date, from now: Date) -> String {
        let total = max(0, Int(target.timeIntervalSince(now)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Locale-aware short clock time, e.g. "5:12 AM".
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    /// Header date line, e.g. "Tuesday, June 10".
    static func dayLine(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

// MARK: - Today layout model (home-agent owned extension)

/// The centerpiece "current prayer" block: which prayer, which schedule day
/// its grid belongs to, and when its window closes. Pre-fajr this is
/// YESTERDAY's isha with yesterday's dayKey (its window ends at today's fajr).
struct TodayBlock: Equatable {
    let prayer: Prayer
    let dayKey: String
    let windowEnd: Date
    let isYesterdayIsha: Bool
    /// v3.3: travel — the partner prayer combined into this block (nil = normal
    /// single-prayer block). When set, `prayer` is the LEAD (earlier) prayer.
    var combinedWith: Prayer? = nil
}

@MainActor
extension AppState {

    /// Latest prayer whose window has started — the live centerpiece.
    /// Before today's fajr the current block is yesterday's isha. While
    /// traveling, a Dhuhr/Asr or Maghrib/Isha pair is shown as one combined
    /// block (the lead prayer, partner folded in) until both are logged.
    func currentTodayBlock(now: Date) -> TodayBlock? {
        guard let schedule = todaySchedule else { return nil }

        if let fajr = schedule.window(for: .fajr), now < fajr.start {
            let calendar = Calendar.current
            let yesterdayStart = calendar.date(byAdding: .day, value: -1,
                                               to: calendar.startOfDay(for: now))
            let yesterdayKey = yesterdayStart.map { AppClock.dayKey(for: $0) } ?? schedule.dayKey
            return TodayBlock(prayer: .isha, dayKey: yesterdayKey,
                              windowEnd: fajr.start, isYesterdayIsha: true)
        }

        guard let current = schedule.windows
            .filter({ $0.start <= now })
            .max(by: { $0.start < $1.start }) else { return nil }

        // Travel: fold the current prayer into its combined pair.
        if isTraveling, let partner = TravelPairs.partner(of: current.prayer) {
            let lead = TravelPairs.lead(of: current.prayer)
            let follow = TravelPairs.partner(of: lead) ?? partner   // the later prayer
            let end = schedule.window(for: follow)?.end ?? current.end
            // Both already logged → show the pair as a completed block.
            return TodayBlock(prayer: lead, dayKey: schedule.dayKey, windowEnd: end,
                              isYesterdayIsha: false, combinedWith: follow)
        }

        return TodayBlock(prayer: current.prayer, dayKey: schedule.dayKey,
                          windowEnd: current.end, isYesterdayIsha: false)
    }

    /// Today's passed-unlogged prayers — the make-up (qada) candidates.
    ///
    /// `.beforeJoining` counts. Somebody installing at Maghrib may well have
    /// prayed Fajr through Asr already, and refusing to record that is a worse
    /// wrong than the accusatory framing it was meant to avoid — it makes the
    /// app's first act a refusal. What changes on day one is the WORDING and
    /// the missed-XP arithmetic (see `beforeJoiningOnly` and
    /// `GameEngine.missedOutXP`), not whether the action exists.
    var makeUpPrayers: [Prayer] {
        Prayer.allCases.filter {
            switch status(of: $0) {
            case .missedWindow, .beforeJoining: return true
            default: return false
            }
        }
    }

    /// Every make-up candidate predates the account — i.e. this is day one and
    /// nothing has actually been missed. Drives the invitation-shaped copy.
    var makeUpIsBeforeJoiningOnly: Bool {
        let candidates = makeUpPrayers
        guard !candidates.isEmpty else { return false }
        return candidates.allSatisfy {
            if case .beforeJoining = status(of: $0) { return true }
            return false
        }
    }
}

// MARK: - Today pager (v5 mockup)

/// What one Today page shows for YOU.
enum TodayPageStatus: Equatable {
    case upcoming
    case open
    case logged(PrayerLog)
    /// The window passed with nothing logged. `canMakeUp` mirrors the make-up
    /// section's own candidates (today only), so the two never disagree.
    case missed(canMakeUp: Bool)
    case excused
}

@MainActor
extension AppState {

    /// Every page of the Today pager, in time order — see `TodayPages`.
    func todayPages(now: Date) -> [TodayPage] {
        guard let schedule = todaySchedule else { return [] }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1,
                                              to: Calendar.current.startOfDay(for: now))
        let yesterdayKey = yesterday.map { AppClock.dayKey(for: $0) } ?? schedule.dayKey
        return TodayPages.build(schedule: schedule, yesterdayKey: yesterdayKey,
                                traveling: isTraveling, now: now)
    }

    func pageStatus(_ page: TodayPage, now: Date) -> TodayPageStatus {
        if isExcused(prayer: page.prayer, dayKey: page.dayKey) { return .excused }
        if let log = GameEngine.latestLog(prayer: page.prayer, dayKey: page.dayKey, in: logs) {
            return .logged(log)
        }
        if let start = page.start, now < start { return .upcoming }
        if now < page.end { return .open }
        let candidates = makeUpPrayers
        let canMakeUp = page.dayKey == todayKey
            && (candidates.contains(page.prayer)
                || page.combinedWith.map(candidates.contains) == true)
        return .missed(canMakeUp: canMakeUp)
    }

    /// The tier a post would earn on `page` right now — the pair's combined
    /// window while traveling, exactly as `logCombined` judges it.
    func pageTier(_ page: TodayPage) -> LogTier? {
        postOutlook(prayer: page.prayer, combinedLead: page.combinedWith != nil ? page.prayer : nil)?.tier
    }
}
