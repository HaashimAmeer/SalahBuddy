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

    // v3.8: praying in a group is a FLOOR, not an additive bonus — it lifts a
    // prayer's XP up to the on-time value (30) if it was lower, and adds
    // nothing if you already prayed in the first quarter. Stops penalizing
    // people who reach the masjid late (Asr/Isha jamaat times run late).
    // Jumma (Friday Dhuhr in congregation) folds into the SAME floor — no
    // separate Friday bonus.
    static var jamaatFloorXP: Int { LogTier.onTime.xp }   // 30

    // v3.5/v3.8: dhikr + good-deeds. The ACT is unlimited (never blocked);
    // only the XP is capped per day. Caps now depend on whether you're on a
    // break (see recoveryDailyCap):
    static let dhikrXP = 1                // per tasbih tap
    static let deedXP = 10                // per good-deed prompt
    static let recoveryBreakCap = 200     // on a break: dhikr alone can reach a full day
    static let recoveryDayCeiling = 150   // not on a break: prayer + dhikr combined ≤ this
    static let maxExcusedPerMonth = 10    // legacy v2 cap — no longer enforced (excused is a mode now)

    /// v3.8: today's recovery (dhikr+deeds) XP ceiling.
    /// - On a break: a flat 200, so someone who genuinely can't pray can still
    ///   reach a full day and isn't disadvantaged by the Monday weekly reset.
    /// - Otherwise: only enough to top a prayed-but-imperfect day up to 150 —
    ///   never a perfect-prayer day (~175), so praying early always wins.
    static func recoveryDailyCap(onBreak: Bool, prayerXPToday: Int) -> Int {
        onBreak ? recoveryBreakCap : max(0, recoveryDayCeiling - prayerXPToday)
    }

    /// How much of `amount` can still be granted today given the state-aware
    /// cap and what's already been earned from dhikr+deeds. Pure.
    static func recoveryGrant(amount: Int, earnedToday: Int,
                              onBreak: Bool, prayerXPToday: Int) -> Int {
        let cap = recoveryDailyCap(onBreak: onBreak, prayerXPToday: prayerXPToday)
        return max(0, min(amount, cap - earnedToday))
    }

    /// What the day's recovery XP becomes when one dhikr/deed action is undone.
    /// Pure.
    ///
    /// A naive `earned -= deedXP` is wrong in both directions. Grants clamp to
    /// a daily cap, so an action performed once the cap was already spent
    /// earned NOTHING and undoing it must take nothing back — subtracting 10
    /// there invents a debt. And it cannot simply be recomputed against the
    /// cap either, because the cap SHRINKS as prayer XP arrives: someone who
    /// earned 150 from dhikr in the morning and then prayed all five has a
    /// current cap of 0 and 150 legitimately banked, so a recompute would
    /// strip XP they properly hold.
    ///
    /// What is true in every case is that a day's recovery XP never exceeds
    /// the raw worth of the actions still standing. Clamping to that is exact
    /// whenever the cap held steady, and refuses to strip banked XP when it
    /// did not.
    ///
    /// - Parameters:
    ///   - earnedToday: recovery XP actually granted so far today.
    ///   - remainingRawTotal: uncapped worth of the actions that REMAIN
    ///     (dhikr taps x dhikrXP + deeds x deedXP), the undone one excluded.
    static func recoveryEarnedAfterUndo(earnedToday: Int, remainingRawTotal: Int) -> Int {
        max(0, min(earnedToday, remainingRawTotal))
    }

    /// XP a logged prayer is worth given its tier and whether it was in jamaat
    /// (the floor). The single source of truth for prayer XP.
    static func prayerXP(tier: LogTier, jamaat: Bool) -> Int {
        guard tier.isInWindow else { return tier.xp }    // qada never floors
        return jamaat ? max(tier.xp, jamaatFloorXP) : tier.xp
    }

    /// Friday in the user's current calendar → the Dhuhr congregation toggle is
    /// labelled "Prayed Jumma" (same 30 floor, just nicer copy).
    static func isJumma(prayer: Prayer, date: Date, calendar: Calendar = .current) -> Bool {
        prayer == .dhuhr && calendar.component(.weekday, from: date) == 6
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

    /// v3.6 (design session): tapping a title shows what it means.
    static func titleDescription(_ title: String) -> String {
        switch title {
        case "Seeker": return "Levels 1–5 · Every journey starts with a single sajdah — you're finding your rhythm."
        case "Committed": return "Levels 6–10 · You keep showing up, day after day."
        case "Consistent": return "Levels 11–15 · All five are becoming second nature."
        case "Devoted": return "Levels 16–20 · Prayer anchors your whole day."
        case "Steadfast": return "Levels 21–25 · Unshakeable, even on the busy days."
        case "Radiant": return "Levels 26–30 · Your light pulls the whole circle up."
        case "Luminous": return "Level 31+ · MashaAllah. Keep shining."
        default: return "Keep praying — every level tells a story."
        }
    }

    /// v3.6: XP for retroactively marking a past prayer as made up (Journey
    /// edit). Within `gracedDays` of today it still earns qada XP; older edits
    /// are record-keeping only — the incentive stays on logging same-day.
    static let lateEditGraceDays = 2

    static func lateEditXP(dayKey: String, todayKey: String,
                           calendar: Calendar = .current) -> Int {
        guard let day = AppClock.date(fromDayKey: dayKey),
              let today = AppClock.date(fromDayKey: todayKey) else { return 0 }
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? .max
        return daysAgo <= lateEditGraceDays ? LogTier.qada.xp : 0
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

    // MARK: - Weekly recap (v3.9)

    /// How many photo highlights the "Your week" card shows.
    static let weeklyRecapPhotoCap = 6

    /// v3.9: Journey's "Your week" card for one finished week. Pure — the
    /// caller supplies the week's dayKeys (Mon-first) and today's excused set;
    /// no clock reads here. nil when the week holds none of the user's logs,
    /// which is how the card stays hidden for a brand-new account.
    static func weeklyRecap(logs: [PrayerLog], weekDayKeys: [String],
                            excusedDayKeys: Set<String> = [],
                            photoLimit: Int = weeklyRecapPhotoCap) -> WeeklyRecap? {
        guard let firstKey = weekDayKeys.first, let lastKey = weekDayKeys.last else { return nil }
        let keySet = Set(weekDayKeys)
        let weekLogs = logs.filter { keySet.contains($0.dayKey) }
        guard !weekLogs.isEmpty else { return nil }

        var totalXP = 0
        var daysWithAllFive = 0
        var bestDay: WeeklyRecap.BestDay?
        for key in weekDayKeys {
            let dayXP = xp(forDay: key, logs: weekLogs, excusedDayKeys: excusedDayKeys)
            totalXP += dayXP
            if isDayComplete(logs: weekLogs, dayKey: key) { daysWithAllFive += 1 }
            if dayXP > 0, dayXP > (bestDay?.xp ?? 0) {
                bestDay = WeeklyRecap.BestDay(dayKey: key, xp: dayXP)
            }
        }

        // Highlights are spread evenly across the week's photos rather than
        // clipped to the first few, so a heavy Monday can't fill the strip.
        // v3.3: a travel-combined pair is TWO logs sharing ONE photo, so the same
        // filename can land here twice — de-dupe (first occurrence wins) before
        // the cap, or the strip repeats a photo and ForEach gets duplicate ids.
        var seenPhotos = Set<String>()
        let allPhotos = weekLogs.sorted { $0.loggedAt < $1.loggedAt }
            .compactMap(\.photoFilename)
            .filter { seenPhotos.insert($0).inserted }
        let limit = max(0, photoLimit)
        let photos = allPhotos.count <= limit
            ? allPhotos
            : (0..<limit).map { allPhotos[$0 * allPhotos.count / limit] }

        return WeeklyRecap(weekStartDayKey: firstKey, weekEndDayKey: lastKey,
                           totalXP: totalXP, prayersLogged: weekLogs.count,
                           daysWithAllFive: daysWithAllFive, bestDay: bestDay,
                           photoFilenames: photos)
    }
}
