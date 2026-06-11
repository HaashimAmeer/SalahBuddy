import Foundation

/// Pure, testable game rules. No I/O, no singletons, no clock reads —
/// every function takes its inputs explicitly. `AppState` delegates here.
enum GameEngine {

    // MARK: - Tier math

    /// Tier earned if `prayer` is logged at `now` against its window.
    /// - nil        → window hasn't opened yet (can't log)
    /// - onTime     → first ⅓ of the window
    /// - prayed     → second ⅓
    /// - lastCall   → final ⅓
    /// - qada       → at/after window end (caller enforces same-schedule-day rule)
    static func tier(for window: PrayerWindow, at now: Date) -> LogTier? {
        guard now >= window.start else { return nil }
        guard now < window.end else { return .qada }
        let duration = window.end.timeIntervalSince(window.start)
        let elapsed = now.timeIntervalSince(window.start)
        if elapsed < duration / 3 { return .onTime }
        if elapsed < duration * 2 / 3 { return .prayed }
        return .lastCall
    }

    // MARK: - Levels

    static let dailyGoalDefault = 100
    static let perfectDayBonus = 25
    static let maxStreakFreezes = 2

    static let levelTitles = ["Seeker", "Committed", "Consistent", "Devoted",
                              "Steadfast", "Radiant", "Luminous"]

    /// XP required to advance from `level` to `level + 1`.
    static func xpToAdvance(from level: Int) -> Int {
        100 + (max(1, level) - 1) * 25
    }

    /// Level (starting at 1) for a cumulative XP total.
    static func level(forTotalXP totalXP: Int) -> Int {
        var level = 1
        var remaining = max(0, totalXP)
        while remaining >= xpToAdvance(from: level) {
            remaining -= xpToAdvance(from: level)
            level += 1
        }
        return level
    }

    /// XP accumulated inside the current level.
    static func xpIntoLevel(forTotalXP totalXP: Int) -> Int {
        var level = 1
        var remaining = max(0, totalXP)
        while remaining >= xpToAdvance(from: level) {
            remaining -= xpToAdvance(from: level)
            level += 1
        }
        return remaining
    }

    /// Title for a level — a new title every 5 levels, clamped at the end.
    static func title(forLevel level: Int) -> String {
        let index = min(max(0, (level - 1) / 5), levelTitles.count - 1)
        return levelTitles[index]
    }

    // MARK: - Day queries

    static func logs(in logs: [PrayerLog], dayKey: String) -> [PrayerLog] {
        logs.filter { $0.dayKey == dayKey }
    }

    /// All 5 prayers logged (any tier, including qada).
    static func isDayComplete(logs: [PrayerLog], dayKey: String) -> Bool {
        let prayed = Set(logs.lazy.filter { $0.dayKey == dayKey }.map(\.prayer))
        return prayed.count == Prayer.allCases.count
    }

    /// All 5 prayers logged IN-WINDOW (onTime/prayed/lastCall). Qada disqualifies.
    static func isPerfectDay(logs: [PrayerLog], dayKey: String) -> Bool {
        let dayLogs = logs.filter { $0.dayKey == dayKey }
        guard Set(dayLogs.map(\.prayer)).count == Prayer.allCases.count else { return false }
        return dayLogs.allSatisfy { $0.tier.isInWindow }
    }

    /// Raw log XP + perfect-day bonus for one day.
    static func xp(forDay dayKey: String, logs: [PrayerLog]) -> Int {
        let base = logs.lazy.filter { $0.dayKey == dayKey }.reduce(0) { $0 + $1.xp }
        return base + (isPerfectDay(logs: logs, dayKey: dayKey) ? perfectDayBonus : 0)
    }

    // MARK: - Streak

    /// Apply the streak increment that fires the moment the 5th prayer of
    /// `dayKey` is logged. No-op if this day already counted.
    static func applyStreakIncrement(to profile: UserProfile, dayKey: String) -> UserProfile {
        guard profile.lastStreakDayKey != dayKey else { return profile }
        var p = profile
        p.streak += 1
        p.longestStreak = max(p.longestStreak, p.streak)
        p.lastStreakDayKey = dayKey
        if p.streak > 0, p.streak % 7 == 0 {
            p.streakFreezes = min(maxStreakFreezes, p.streakFreezes + 1)
        }
        return p
    }

    /// Reverse a streak increment (undo path). Only acts if `dayKey` was the
    /// day that most recently extended the streak.
    static func reverseStreakIncrement(on profile: UserProfile, dayKey: String) -> UserProfile {
        guard profile.lastStreakDayKey == dayKey else { return profile }
        var p = profile
        if p.streak > 0, p.streak % 7 == 0, p.streakFreezes > 0 {
            p.streakFreezes -= 1   // give back the freeze this increment earned
        }
        p.streak = max(0, p.streak - 1)
        p.lastStreakDayKey = nil
        return p
    }

    /// Reconcile elapsed days (NEVER including today). `elapsedDays` is the
    /// ordered list of (dayKey, isComplete) from the day after
    /// `lastReconciledDayKey` through yesterday. Incomplete day → consume a
    /// freeze if available, else streak resets to 0.
    static func reconcile(profile: UserProfile,
                          elapsedDays: [(dayKey: String, isComplete: Bool)]) -> UserProfile {
        var p = profile
        for day in elapsedDays {
            if !day.isComplete {
                if p.streakFreezes > 0 {
                    p.streakFreezes -= 1
                } else {
                    p.streak = 0
                }
            }
            p.lastReconciledDayKey = day.dayKey
        }
        return p
    }

    // MARK: - Weekly XP (league)

    /// Your real XP earned in [weekStart, weekStart + 7d): logs + perfect-day
    /// bonuses whose dayKey falls inside the week.
    static func weeklyXP(logs: [PrayerLog], weekStart: Date, calendar: Calendar = .current) -> Int {
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return 0 }
        var dayKeys: Set<String> = []
        var day = weekStart
        while day < weekEnd {
            dayKeys.insert(AppClock.dayKey(for: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return dayKeys.reduce(0) { total, key in
            let dayLogs = logs.filter { $0.dayKey == key }
            guard !dayLogs.isEmpty else { return total }
            return total + xp(forDay: key, logs: logs)
        }
    }
}
