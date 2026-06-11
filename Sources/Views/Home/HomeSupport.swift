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
}

@MainActor
extension AppState {

    /// Latest prayer whose window has started — the live centerpiece.
    /// Before today's fajr the current block is yesterday's isha.
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
        return TodayBlock(prayer: current.prayer, dayKey: schedule.dayKey,
                          windowEnd: current.end, isYesterdayIsha: false)
    }

    /// Today's prayers whose windows already started, excluding the current
    /// block's prayer (oldest first). Empty pre-fajr.
    func earlierTodayPrayers(now: Date) -> [Prayer] {
        guard let schedule = todaySchedule,
              let block = currentTodayBlock(now: now), !block.isYesterdayIsha else { return [] }
        return schedule.windows
            .filter { $0.start <= now && $0.prayer != block.prayer }
            .sorted { $0.start < $1.start }
            .map(\.prayer)
    }

    /// Today's prayers whose windows haven't opened yet (soonest first).
    func upcomingTodayWindows(now: Date) -> [PrayerWindow] {
        guard let schedule = todaySchedule else { return [] }
        return schedule.windows.filter { $0.start > now }.sorted { $0.start < $1.start }
    }

    /// Today's passed-unlogged prayers — the make-up (qada) candidates.
    var makeUpPrayers: [Prayer] {
        Prayer.allCases.filter {
            if case .missedWindow = status(of: $0) { return true }
            return false
        }
    }
}
