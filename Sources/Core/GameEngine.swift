import Foundation

/// Pure, testable game rules. No I/O, no singletons, no clock reads —
/// every function takes its inputs explicitly. `AppState` delegates here.
enum GameEngine {

    // MARK: - Tier math

    /// Tier earned if `prayer` is logged at `now` against its window.
    /// - nil        → window hasn't opened yet (can't log)
    /// - onTime     → first ¼ of the window (v3.2: quarters, was thirds)
    /// - prayed     → second ¼
    /// - lastCall   → third ¼
    /// - closeCall  → final ¼
    /// - qada       → at/after window end (caller enforces same-schedule-day rule)
    static func tier(for window: PrayerWindow, at now: Date) -> LogTier? {
        guard now >= window.start else { return nil }
        guard now < window.end else { return .qada }
        let duration = window.end.timeIntervalSince(window.start)
        let elapsed = now.timeIntervalSince(window.start)
        if elapsed < duration / 4 { return .onTime }
        if elapsed < duration / 2 { return .prayed }
        if elapsed < duration * 3 / 4 { return .lastCall }
        return .closeCall
    }

    // MARK: - Levels

    static let dailyGoalDefault = 100
    static let perfectDayBonus = 25
    static let maxStreakFreezes = 2
    static let jamaatBonus = 5            // v2: optional "prayed in jamaat" bonus
    static let jummaBonus = 10            // v3.2: Friday Dhuhr in congregation = Jumma
    // v3.5: dhikr/good-deeds while on a break. The ACT is unlimited (never
    // blocked); only XP is softly capped per day so it can't be farmed. All of
    // it is private — never on the circle scoreboard.
    static let dhikrXP = 1                // per tasbih tap
    static let deedXP = 10               // per good-deed prompt
    static let recoveryDailyXPCap = 40   // shared soft daily cap for dhikr + deeds
    static let maxExcusedPerMonth = 10    // legacy v2 cap — no longer enforced (excused is a mode now)

    /// v3.5: how much of `amount` can still be granted today given what's
    /// already been earned from dhikr+deeds, respecting the soft cap. Pure.
    static func recoveryGrant(amount: Int, earnedToday: Int) -> Int {
        max(0, min(amount, recoveryDailyXPCap - earnedToday))
    }

    /// Friday in the user's current calendar → the Dhuhr jamaat toggle becomes
    /// "Prayed Jumma" and earns the bigger bonus.
    static func isJumma(prayer: Prayer, date: Date, calendar: Calendar = .current) -> Bool {
        prayer == .dhuhr && calendar.component(.weekday, from: date) == 6
    }

    static func congregationBonus(prayer: Prayer, date: Date, calendar: Calendar = .current) -> Int {
        isJumma(prayer: prayer, date: date, calendar: calendar) ? jummaBonus : jamaatBonus
    }

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
    /// v2: an excused day can never be a perfect day.
    static func isPerfectDay(logs: [PrayerLog], dayKey: String,
                             excusedDayKeys: Set<String> = []) -> Bool {
        guard !excusedDayKeys.contains(dayKey) else { return false }
        let dayLogs = logs.filter { $0.dayKey == dayKey }
        guard Set(dayLogs.map(\.prayer)).count == Prayer.allCases.count else { return false }
        return dayLogs.allSatisfy { $0.tier.isInWindow }
    }

    /// Raw log XP + perfect-day bonus for one day.
    static func xp(forDay dayKey: String, logs: [PrayerLog],
                   excusedDayKeys: Set<String> = []) -> Int {
        let base = logs.lazy.filter { $0.dayKey == dayKey }.reduce(0) { $0 + $1.xp }
        let perfect = isPerfectDay(logs: logs, dayKey: dayKey, excusedDayKeys: excusedDayKeys)
        return base + (perfect ? perfectDayBonus : 0)
    }

    // MARK: - Excused days (v2)

    /// Excused days used in the calendar month of `dayKey` ("yyyy-MM-dd").
    static func excusedCount(in excusedDayKeys: Set<String>, monthOf dayKey: String) -> Int {
        let monthPrefix = String(dayKey.prefix(7))   // "yyyy-MM"
        return excusedDayKeys.filter { $0.hasPrefix(monthPrefix) }.count
    }

    /// Whether another day in `dayKey`'s month can still be excused (10/month cap).
    static func canExcuse(dayKey: String, excusedDayKeys: Set<String>) -> Bool {
        guard !excusedDayKeys.contains(dayKey) else { return true }   // already excused — no-op allowed
        return excusedCount(in: excusedDayKeys, monthOf: dayKey) < maxExcusedPerMonth
    }

    /// XP the user missed out on today: for every window that fully passed
    /// without an in-window log, the onTime XP was foregone (minus whatever a
    /// qada recovered). Positive-tone copy; excused days forgo nothing.
    static func missedOutXP(logs: [PrayerLog], schedule: DaySchedule, now: Date,
                            isExcused: Bool) -> Int {
        guard !isExcused else { return 0 }
        var total = 0
        for window in schedule.windows where now >= window.end {
            let log = logs.first { $0.dayKey == schedule.dayKey && $0.prayer == window.prayer }
            if let log {
                if !log.tier.isInWindow {
                    total += max(0, LogTier.onTime.xp - log.xp)   // qada recovered some
                }
            } else {
                total += LogTier.onTime.xp
            }
        }
        return total
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
    /// v2: excused days are SKIPPED entirely — streak preserved, no freeze
    /// consumed, no increment; the walk just advances past them.
    static func reconcile(profile: UserProfile,
                          elapsedDays: [(dayKey: String, isComplete: Bool)],
                          excusedDayKeys: Set<String> = []) -> UserProfile {
        var p = profile
        for day in elapsedDays {
            if excusedDayKeys.contains(day.dayKey) {
                p.lastReconciledDayKey = day.dayKey
                continue
            }
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

    // MARK: - Weekly XP (circle scoreboard)

    /// Your real XP earned in [weekStart, weekStart + 7d): logs + perfect-day
    /// bonuses whose dayKey falls inside the week.
    static func weeklyXP(logs: [PrayerLog], weekStart: Date, calendar: Calendar = .current,
                         excusedDayKeys: Set<String> = []) -> Int {
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
            return total + xp(forDay: key, logs: logs, excusedDayKeys: excusedDayKeys)
        }
    }
}
