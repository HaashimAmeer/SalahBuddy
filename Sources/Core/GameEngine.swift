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
    ///
    /// `joinedAt` windows are skipped entirely: XP that was foregone before
    /// the account existed was never on offer, so counting it would greet a
    /// brand-new user with a bill for a day they were not present for.
    ///
    /// v4 — IDENTITY, not grouping, and `currentOffset` is why. `schedule` is
    /// the CURRENT zone's windows for the day the device is standing in, so
    /// "did I pray this one?" has to be asked of the current zone's prayer.
    /// A traveller who prayed fajr in Mumbai and then landed in Seattle after
    /// Seattle's fajr closed really did forgo Seattle's fajr — answering by
    /// `dayKey` alone would report zero foregone XP for a window nobody prayed,
    /// and contradict the make-up row the Today screen is offering right next
    /// to this number. Only ever called for TODAY (`AppState.missedOutXPToday`);
    /// a past day has no comparable zone and must not be asked this.
    static func missedOutXP(logs: [PrayerLog], schedule: DaySchedule, now: Date,
                            isExcused: Bool, joinedAt: Date = .distantPast,
                            currentOffset: Int) -> Int {
        guard !isExcused else { return 0 }
        var total = 0
        for window in schedule.windows where now >= window.end && window.end > joinedAt {
            let log = loggedInstance(prayer: window.prayer, dayKey: schedule.dayKey,
                                     currentOffset: currentOffset, in: logs)
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
    ///
    /// Every 7th day banks a freeze, up to two — and the increment RECORDS
    /// whether it actually banked one, because at the cap it banks nothing and
    /// nothing downstream can tell that from the profile alone. See
    /// `reverseStreakIncrement`, which is the reason the receipt exists.
    static func applyStreakIncrement(to profile: UserProfile, dayKey: String) -> UserProfile {
        guard profile.lastStreakDayKey != dayKey else { return profile }
        var p = profile
        p.streak += 1
        p.longestStreak = max(p.longestStreak, p.streak)
        p.lastStreakDayKey = dayKey
        let banksFreeze = p.streak > 0 && p.streak % 7 == 0 && p.streakFreezes < maxStreakFreezes
        if banksFreeze { p.streakFreezes += 1 }
        p.lastStreakFreezeDayKey = banksFreeze ? dayKey : nil
        return p
    }

    /// Reverse a streak increment (undo path). Only acts if `dayKey` was the
    /// day that most recently extended the streak.
    ///
    /// It gives back the freeze ONLY if this increment is the one that banked
    /// it. `streak % 7 == 0` used to stand in for that question and is not the
    /// same question: freezes cap at two, so a day-21 increment for somebody
    /// already holding two banks nothing at all, and undoing it charged them a
    /// freeze they had earned on day 7 and were entitled to keep. Both cases
    /// end at "streak 21, two freezes", which is exactly why the forward step
    /// leaves a receipt instead of letting undo infer one.
    static func reverseStreakIncrement(on profile: UserProfile, dayKey: String) -> UserProfile {
        guard profile.lastStreakDayKey == dayKey else { return profile }
        var p = profile
        if p.lastStreakFreezeDayKey == dayKey, p.streakFreezes > 0 {
            p.streakFreezes -= 1   // give back the freeze THIS increment earned
        }
        p.lastStreakFreezeDayKey = nil
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
    /// v4: `travelDayKeys` are skipped on exactly the same terms as excused
    /// days — a day the device crossed several timezones was not a whole day,
    /// and a walk that cannot tell the difference will break a streak for
    /// boarding a plane.
    static func reconcile(profile: UserProfile,
                          elapsedDays: [(dayKey: String, isComplete: Bool)],
                          excusedDayKeys: Set<String> = [],
                          travelDayKeys: Set<String> = []) -> UserProfile {
        var p = profile
        for day in elapsedDays {
            if excusedDayKeys.contains(day.dayKey) || travelDayKeys.contains(day.dayKey) {
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

    // MARK: - Travel

    /// How far the device's UTC offset must move before a day stops counting
    /// as a whole day. Three hours, and the number is doing real work at both
    /// ends.
    ///
    /// Below it: a DST jump is exactly one hour and must NEVER trip this, or
    /// twice a year every user in the country would silently bank a free day.
    /// Nudging into a neighbouring zone is one hour too, and a one-hour day is
    /// still a day you can pray five times in.
    ///
    /// At or above it: the shift is long-haul, the local day genuinely
    /// compresses (Seattle → Mumbai loses about twelve hours of it), and
    /// reaching five becomes a matter of geography rather than intent.
    static let travelOffsetThreshold = 3 * 3600

    /// Whether a change in UTC offset is big enough to call the day a travel
    /// day. Pure; `nil` previous means this device has never looked, which is
    /// not a change.
    static func isTravelShift(from previous: Int?, to current: Int) -> Bool {
        guard let previous else { return false }
        return abs(current - previous) >= travelOffsetThreshold
    }

    /// Whether a stored log is the SAME prayer instance the device is living in
    /// right now — the answer to "have I already prayed this one?".
    ///
    /// `dayKey` alone used to answer that, and it was doing two jobs: labelling
    /// a calendar day AND identifying a prayer. They agree for everyone who
    /// stays put and part company on a long-haul flight. Mumbai's fajr and
    /// Seattle's fajr on 2026-08-22 are two genuinely different prayers, hours
    /// apart, sharing one calendar date; asking `dayKey` says they are one, and
    /// the second — really prayed — could not be logged. So identity is
    /// `(prayer, dayKey, zone)`, and this is the zone half.
    ///
    /// TOLERANCE, NOT EQUALITY, and the same three hours `isTravelShift` uses:
    /// a DST shift is exactly one hour and must never re-open a prayer already
    /// prayed, and a device whose offset moved an hour is still standing in the
    /// same day. Below the threshold it is the same prayer; at or above it, the
    /// day itself has been truncated (which is what `isTravelShift` says) and
    /// the prayer on the other side is a new one. The two questions share a
    /// threshold because they are the same question asked twice.
    ///
    /// `nil` — every log written before v4 captured the offset — matches
    /// ANYTHING, deliberately. Old data has no zone to compare, and the
    /// conservative reading is "already prayed": history can lose a duplicate
    /// it should have been allowed, but can never gain one it should not.
    ///
    /// Note this is NOT the identity of a DAY. `dayKey` remains the grouping
    /// key everywhere — `isDayComplete`, `isPerfectDay`, `xp(forDay:)`,
    /// `weeklyXP`, the streak walk and the grids are untouched by this, and a
    /// six-prayer travel day is still one day with one streak increment.
    static func isSamePrayerInstance(storedOffset: Int?, currentOffset: Int) -> Bool {
        !isTravelShift(from: storedOffset, to: currentOffset)
    }

    /// How far a stored log's zone is from the one the device is standing in,
    /// for RANKING two logs that both match. `nil` — a pre-v4 log with no zone
    /// recorded — is the least specific answer there is and therefore ranks
    /// last, so a real zone match always beats "matches anything".
    ///
    /// Only meaningful for logs `isSamePrayerInstance` already accepted; it is
    /// a tie-break, not a second gate.
    private static func zoneDistance(storedOffset: Int?, currentOffset: Int) -> Int {
        guard let storedOffset else { return Int.max }
        return abs(currentOffset - storedOffset)
    }

    /// Index of the log that IS this prayer instance, if it has already been
    /// prayed — the identity lookup `AppState` runs before offering to log
    /// anything, and the SAME one `undoLog` runs before taking one back.
    ///
    /// `dayKeys` is a set because undo has to consider yesterday's key too: an
    /// isha logged after midnight carries YESTERDAY's dayKey (§6.8).
    ///
    /// MORE THAN ONE LOG CAN MATCH, and this is the single place that decides
    /// which. Tolerance is not equality, so two logs three to six hours of zone
    /// apart can both sit within three hours of where the device is now — fajr
    /// in Seattle and fajr in New York, asked from Chicago. Every caller must
    /// get the SAME answer or the Today tile renders one log while Undo deletes
    /// the other, so the choice is made once, here:
    ///
    ///   1. the closest zone wins — it is the prayer you are standing nearest;
    ///   2. a real zone beats a zoneless legacy log, which matches everything
    ///      and therefore distinguishes nothing;
    ///   3. ties go to the LAST log in the array, i.e. the most recently
    ///      appended. Undo means "take back what I just did", and for status it
    ///      cannot matter: a tie means the two logs are the same prayer in the
    ///      same zone, which nothing in the app is allowed to create.
    ///
    /// Pure, and the current offset is an argument rather than a clock read, so
    /// the whole "is this the same prayer?" question is testable without a
    /// device that can fly.
    /// `preferredDayKey` outranks zone distance, and that ordering is the whole
    /// point of the parameter. Undo hands this a SET — for isha it holds the
    /// target day, today and yesterday, because an isha logged past midnight
    /// carries yesterday's key. Ranking that set by zone distance alone let a
    /// far-away day win: log today's isha at one offset, move three hours or
    /// more, tap Undo, and yesterday's isha — logged nearer the new offset —
    /// scored better and was the one deleted, taking its XP and possibly a
    /// streak increment with it. Probably unreachable through today's UI, since
    /// `status(of:)` would stop reporting `.logged` and hide the affordance,
    /// but "the button is currently hidden" is not where this rule should live.
    static func loggedInstanceIndex(prayer: Prayer, dayKeys: Set<String>, currentOffset: Int,
                                    preferredDayKey: String? = nil,
                                    in logs: [PrayerLog]) -> Int? {
        // A preference has to be applied BEFORE the identity filter, not as a
        // ranking after it — which is the mistake a first attempt made, and a
        // test caught. Today's isha logged in Mumbai does not survive the
        // identity guard once the device is in Seattle, so it is not a
        // candidate at all and no amount of ranking can prefer it; yesterday's
        // Seattle isha then wins by default and Undo eats a day that was
        // already banked. Once the preferred day holds a log for this prayer,
        // the other days stop being candidates at all — the fall-through to
        // `previousDayKey` exists for "today has no isha YET", not for "today's
        // isha is not the one you are standing in".
        let searchKeys: Set<String>
        if let preferredDayKey,
           logs.contains(where: { $0.prayer == prayer && $0.dayKey == preferredDayKey }) {
            searchKeys = [preferredDayKey]
        } else {
            searchKeys = dayKeys
        }

        var best: Int? = nil
        var bestDistance: Int = Int.max
        for (index, log) in logs.enumerated() {
            guard log.prayer == prayer, searchKeys.contains(log.dayKey),
                  isSamePrayerInstance(storedOffset: log.utcOffset,
                                       currentOffset: currentOffset) else { continue }
            let distance: Int = zoneDistance(storedOffset: log.utcOffset,
                                             currentOffset: currentOffset)
            // `<=` is the tie-break: a later log at the same distance wins.
            if best == nil || distance <= bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// The log that IS this prayer instance, if it has already been prayed.
    /// See `loggedInstanceIndex` — this is the same decision, dereferenced.
    static func loggedInstance(prayer: Prayer, dayKey: String, currentOffset: Int,
                               in logs: [PrayerLog]) -> PrayerLog? {
        loggedInstanceIndex(prayer: prayer, dayKeys: [dayKey],
                            currentOffset: currentOffset, in: logs).map { logs[$0] }
    }

    /// The log a SQUARE draws for `(prayer, dayKey)` — a Today grid tile, a
    /// week-grid cell, a day sheet.
    ///
    /// `isLiveDay` is the whole decision, and it is the caller's to make: TRUE
    /// for the day the device is standing in (today, and — before fajr —
    /// yesterday's still-open isha), FALSE for history.
    ///
    /// A LIVE day answers by IDENTITY, so the square sitting next to the camera
    /// CTA gives the same answer `status(of:)` does. It used to answer by
    /// dayKey alone, and the two contradicted each other the moment somebody
    /// flew: a traveller who prayed fajr in Mumbai and landed in Seattle after
    /// Seattle's fajr had closed was offered "Make up Fajr" by one part of the
    /// screen while another drew a photo for it, and the inline make-up button
    /// was hidden by a cell that disagreed with the row above it.
    ///
    /// A PAST day answers by GROUPING. The zone the device is in today has
    /// nothing to say about the zone Monday was lived in, and asking would
    /// repaint a whole travelled week as missed.
    static func cellLog(prayer: Prayer, dayKey: String, isLiveDay: Bool,
                        currentOffset: Int, in logs: [PrayerLog]) -> PrayerLog? {
        guard isLiveDay else { return latestLog(prayer: prayer, dayKey: dayKey, in: logs) }
        return loggedInstance(prayer: prayer, dayKey: dayKey,
                              currentOffset: currentOffset, in: logs)
    }

    /// The profile after ONE log is taken back — the whole of undo's
    /// arithmetic, in the one place scoring is allowed to live.
    ///
    /// `remainingLogs` is the array with `removed` already gone; the day as it
    /// stood before is reconstructed from the two, so the caller cannot get the
    /// order wrong.
    ///
    /// THE BONUSES COME OFF ONLY ON A TRUE -> FALSE TRANSITION. This used to
    /// read the day BEFORE the removal and assume the removal broke it, which
    /// held exactly as long as `(prayer, dayKey)` was unique — and v4 ended
    /// that on purpose. A traveller with all five prayers banked who logs a
    /// sixth on the other side of a flight and then undoes it still has a
    /// perfect, complete day: charging them 25 XP, a perfect day and a streak
    /// increment for tidying up is a bug that nothing later puts right, because
    /// `reconcile` never increments and the bonus is only ever awarded at log
    /// time. Undo it twice and the 25 comes off twice.
    ///
    /// Badges are deliberately NOT revoked.
    static func profileAfterUndo(of removed: PrayerLog, from profile: UserProfile,
                                 remainingLogs: [PrayerLog],
                                 excusedDayKeys: Set<String> = []) -> UserProfile {
        let dayKey: String = removed.dayKey
        let before: [PrayerLog] = remainingLogs + [removed]

        let lostPerfect: Bool =
            isPerfectDay(logs: before, dayKey: dayKey, excusedDayKeys: excusedDayKeys)
            && !isPerfectDay(logs: remainingLogs, dayKey: dayKey, excusedDayKeys: excusedDayKeys)
        let lostCompletion: Bool =
            isDayComplete(logs: before, dayKey: dayKey)
            && !isDayComplete(logs: remainingLogs, dayKey: dayKey)

        var next: UserProfile = profile
        next.totalXP = max(0, next.totalXP - removed.xp)      // includes any jamaat bonus
        if lostPerfect {
            next.totalXP = max(0, next.totalXP - perfectDayBonus)
            next.perfectDayCount = max(0, next.perfectDayCount - 1)
        }
        if lostCompletion {
            next = reverseStreakIncrement(on: next, dayKey: dayKey)
        }
        return next
    }

    // MARK: - Photo retention (v4.1)

    /// Is the JPEG named `filename` spoken for by nothing at all?
    ///
    /// The one rule that decides whether a file in `PhotoStore` may go, and it
    /// is deliberately about the LOGS rather than about the disk — which is
    /// what makes it pure, and what lets the two ends of a photo's life ask the
    /// identical question:
    ///
    /// - **Undo**, after removing a log. A travel-combined pair is two logs
    ///   sharing ONE photo (see `mirrorLogged`), so taking back the follow
    ///   prayer must leave the picture the lead still draws exactly where it is.
    /// - **The camera flow**, after writing one. The confirm screen can sit open
    ///   across the end of the window, and by the time "Post" is tapped the log
    ///   may be refused outright, or land as qada — which drops the photo on
    ///   purpose (`buildLog`). Either way the JPEG is already on disk with
    ///   nothing pointing at it, and nothing later would ever come looking.
    ///
    /// nil and "" are not orphans, they are absences: `PhotoStore.save` returns
    /// "" when the write failed, and there is no file to take back.
    static func isPhotoOrphaned(_ filename: String?, in logs: [PrayerLog]) -> Bool {
        guard let filename, !filename.isEmpty else { return false }
        return !logs.contains { $0.photoFilename == filename }
    }

    /// The log that REPRESENTS `(prayer, dayKey)` in a view of a PAST day — a
    /// week-grid cell, a memory, a day sheet.
    ///
    /// Identity is unusable there: the zone the device is standing in today has
    /// nothing to do with the zone Monday was lived in, and comparing them
    /// would repaint a whole travelled week as missed. So this is grouping, and
    /// all it has to do is be TOTAL and DETERMINISTIC — a travel day can hold
    /// two logs for one prayer, and a cell that picked `first` would flip to
    /// the other one the moment anything reordered the array.
    ///
    /// The latest prayer wins, by `loggedAt` and then by id so the order never
    /// depends on the array's.
    static func latestLog(prayer: Prayer, dayKey: String, in logs: [PrayerLog]) -> PrayerLog? {
        logs.lazy
            .filter { $0.prayer == prayer && $0.dayKey == dayKey }
            .max { a, b in
                a.loggedAt == b.loggedAt ? a.id.uuidString < b.id.uuidString
                                         : a.loggedAt < b.loggedAt
            }
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

    // MARK: - The race (v4.1)

    /// The XP the crown race is run in — ONE definition, behind both the
    /// progress a member watches climb and the decision about who won.
    ///
    /// Prayer XP plus the perfect-day bonus, and no recovery XP. That is the
    /// line SCORING.md draws: "the race stays prayer-only" separates praying
    /// from the opaque weekly dhikr total, not a log from the bonus a day of
    /// logs earns — and the perfect-day bonus is bought with exactly what the
    /// race exists to reward, all five in their windows. It is also the number
    /// the weekly scoreboard shows, minus that opaque total.
    ///
    /// It used to be two definitions that disagreed. The progress bar summed
    /// `xp(forDay:)` (bonus included) while the winner walked raw `log.xp`
    /// (bonus excluded), so the bar could read 300/300 with the crown still
    /// unclaimed — and worse, hand the crown to whoever the bonus-free total
    /// happened to favour. At 25 XP the bonus is worth most of a prayer; it
    /// changes orderings, not just totals.
    static func raceXP(logs: [PrayerLog]) -> Int {
        Set(logs.map(\.dayKey)).reduce(0) { $0 + xp(forDay: $1, logs: logs) }
    }

    /// The instant `logs` first reached `threshold` under `raceXP`, or nil if
    /// they never did.
    ///
    /// A running sum of `log.xp` cannot answer this, because the perfect-day
    /// bonus is not carried by any one log: it lands when a day's fifth
    /// in-window prayer does, and a later qada on the same day takes it away
    /// again (a travel day can hold six). So the week is REPLAYED in log order
    /// and the day each log belongs to is re-scored — by `xp(forDay:)`, the
    /// same function `raceXP` sums — after every step. Re-scoring one day
    /// rather than the whole prefix keeps it linear in the week AND keeps the
    /// arithmetic identical to the total; a hand-rolled running version of the
    /// perfect-day rule would be a second definition, which is the bug.
    static func raceCrossing(logs: [PrayerLog], threshold: Int) -> Date? {
        let ordered = logs.sorted { a, b in
            a.loggedAt == b.loggedAt ? a.id.uuidString < b.id.uuidString
                                     : a.loggedAt < b.loggedAt
        }
        var logsByDay: [String: [PrayerLog]] = [:]
        var xpByDay: [String: Int] = [:]
        var total = 0
        for entry in ordered {
            logsByDay[entry.dayKey, default: []].append(entry)
            let scored = xp(forDay: entry.dayKey, logs: logsByDay[entry.dayKey] ?? [])
            total += scored - (xpByDay[entry.dayKey] ?? 0)
            xpByDay[entry.dayKey] = scored
            if total >= threshold { return entry.loggedAt }
        }
        return nil
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
