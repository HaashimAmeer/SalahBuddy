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

    /// Today's prayers whose windows already started, excluding whatever the
    /// current block already represents (oldest first). Empty pre-fajr.
    func earlierTodayPrayers(now: Date) -> [Prayer] {
        guard let schedule = todaySchedule,
              let block = currentTodayBlock(now: now), !block.isYesterdayIsha else { return [] }
        var shown: Set<Prayer> = [block.prayer]
        if let partner = block.combinedWith { shown.insert(partner) }
        return schedule.windows
            .filter { $0.start <= now && !shown.contains($0.prayer) }
            .sorted { $0.start < $1.start }
            .map(\.prayer)
    }

    /// Today's prayers whose windows haven't opened yet (soonest first). While
    /// traveling, a pair whose lead is still upcoming collapses to one entry
    /// (the lead window; the UI labels it "Dhuhr + Asr").
    func upcomingTodayWindows(now: Date) -> [PrayerWindow] {
        guard let schedule = todaySchedule else { return [] }
        let future = schedule.windows.filter { $0.start > now }.sorted { $0.start < $1.start }
        guard isTraveling else { return future }
        // Drop the follow prayer of any pair whose lead is also upcoming —
        // the combined card/row covers it.
        return future.filter { window in
            guard let lead = TravelPairs.partner(of: window.prayer).map({ _ in TravelPairs.lead(of: window.prayer) }),
                  lead != window.prayer else { return true }
            return !future.contains { $0.prayer == lead }
        }
    }

    /// Whether an upcoming window should be labelled as a combined pair.
    func upcomingCombinedPartner(for prayer: Prayer, now: Date) -> Prayer? {
        guard isTraveling, TravelPairs.lead(of: prayer) == prayer,
              let follow = TravelPairs.partner(of: prayer) else { return nil }
        return follow
    }

    /// Today's passed-unlogged prayers — the make-up (qada) candidates.
    var makeUpPrayers: [Prayer] {
        Prayer.allCases.filter {
            if case .missedWindow = status(of: $0) { return true }
            return false
        }
    }
}
