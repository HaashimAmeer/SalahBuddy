import XCTest
@testable import SalahBuddy

final class GameEngineTests: XCTestCase {

    // MARK: - Helpers

    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    /// `at` defaults to the epoch, which is what every day-scoped fixture in
    /// this file wants (nothing here cares WHEN a log landed). The race does —
    /// `raceCrossing` walks the week in `loggedAt` order — so it says so.
    private func log(_ prayer: Prayer, _ tier: LogTier, dayKey: String,
                     offset: Int? = nil, photo: String? = nil,
                     at loggedAt: Date = Date(timeIntervalSince1970: 0)) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                  loggedAt: loggedAt, tier: tier, xp: tier.xp,
                  photoFilename: photo, utcOffset: offset)
    }

    private func fullDay(dayKey: String, tier: LogTier = .onTime) -> [PrayerLog] {
        Prayer.allCases.map { log($0, tier, dayKey: dayKey) }
    }

    // MARK: - Tier boundaries

    func testTierBoundaries() {
        let start = date(2026, 6, 10, 12, 0)
        let window = PrayerWindow(prayer: .dhuhr, start: start,
                                  end: start.addingTimeInterval(120 * 60)) // 120 min → quarters of 30 min

        // Before start → nil (can't log).
        XCTAssertNil(GameEngine.tier(for: window, at: start.addingTimeInterval(-1)))
        // Exactly at start → onTime.
        XCTAssertEqual(GameEngine.tier(for: window, at: start), .onTime)
        // Just inside first quarter.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(30 * 60 - 1)), .onTime)
        // Exactly at ¼ boundary → second tier.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(30 * 60)), .prayed)
        // Just inside second quarter.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(60 * 60 - 1)), .prayed)
        // Exactly at ½ boundary → lastCall.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(60 * 60)), .lastCall)
        // Just inside third quarter.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(90 * 60 - 1)), .lastCall)
        // Exactly at ¾ boundary → closeCall.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(90 * 60)), .closeCall)
        // Just before end → closeCall.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(120 * 60 - 1)), .closeCall)
        // At/after end → qada.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(120 * 60)), .qada)
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(5 * 3600)), .qada)
    }

    func testTierXPValues() {
        XCTAssertEqual(LogTier.onTime.xp, 30)
        XCTAssertEqual(LogTier.prayed.xp, 20)
        XCTAssertEqual(LogTier.lastCall.xp, 15)
        XCTAssertEqual(LogTier.closeCall.xp, 12)
        XCTAssertEqual(LogTier.qada.xp, 5)   // v3.7: dropped from 10
        // In-window must always beat making up later.
        XCTAssertGreaterThan(LogTier.closeCall.xp, LogTier.qada.xp)
    }

    func testJummaLabel() {
        // 2026-06-12 is a Friday — Jumma is just a Friday-Dhuhr label now;
        // the XP effect is the shared 30 floor (no separate bonus).
        let friday = date(2026, 6, 12, 13, 0)
        let thursday = date(2026, 6, 11, 13, 0)
        XCTAssertTrue(GameEngine.isJumma(prayer: .dhuhr, date: friday))
        XCTAssertFalse(GameEngine.isJumma(prayer: .asr, date: friday))
        XCTAssertFalse(GameEngine.isJumma(prayer: .dhuhr, date: thursday))
    }

    func testJamaatIsAFloorTo30() {
        // v3.8: jamaat lifts a prayer up to 30 (on-time), never additive.
        XCTAssertEqual(GameEngine.jamaatFloorXP, 30)
        XCTAssertEqual(GameEngine.prayerXP(tier: .onTime, jamaat: true), 30)   // already 30
        XCTAssertEqual(GameEngine.prayerXP(tier: .prayed, jamaat: true), 30)   // 20 → 30
        XCTAssertEqual(GameEngine.prayerXP(tier: .lastCall, jamaat: true), 30) // 15 → 30
        XCTAssertEqual(GameEngine.prayerXP(tier: .closeCall, jamaat: true), 30)// 12 → 30
        // Without jamaat the tier stands.
        XCTAssertEqual(GameEngine.prayerXP(tier: .lastCall, jamaat: false), 15)
        // Qada never floors (out of window).
        XCTAssertEqual(GameEngine.prayerXP(tier: .qada, jamaat: true), 5)
    }

    // MARK: - Levels

    func testLevelFormula() {
        // Cost from level n → n+1 is 100 + (n-1)*25.
        XCTAssertEqual(GameEngine.xpToAdvance(from: 1), 100)
        XCTAssertEqual(GameEngine.xpToAdvance(from: 2), 125)
        XCTAssertEqual(GameEngine.xpToAdvance(from: 5), 200)

        XCTAssertEqual(GameEngine.level(forTotalXP: 0), 1)
        XCTAssertEqual(GameEngine.level(forTotalXP: 99), 1)
        XCTAssertEqual(GameEngine.level(forTotalXP: 100), 2)
        XCTAssertEqual(GameEngine.level(forTotalXP: 224), 2)   // 100 + 125 = 225
        XCTAssertEqual(GameEngine.level(forTotalXP: 225), 3)
        XCTAssertEqual(GameEngine.level(forTotalXP: 375), 4)   // +150

        XCTAssertEqual(GameEngine.xpIntoLevel(forTotalXP: 0), 0)
        XCTAssertEqual(GameEngine.xpIntoLevel(forTotalXP: 99), 99)
        XCTAssertEqual(GameEngine.xpIntoLevel(forTotalXP: 100), 0)
        XCTAssertEqual(GameEngine.xpIntoLevel(forTotalXP: 230), 5)
    }

    func testLevelMonotonicAndTitles() {
        var lastLevel = 0
        for xp in stride(from: 0, through: 20_000, by: 250) {
            let level = GameEngine.level(forTotalXP: xp)
            XCTAssertGreaterThanOrEqual(level, lastLevel, "level must never decrease as XP grows")
            lastLevel = level
        }

        XCTAssertEqual(GameEngine.title(forLevel: 1), "Seeker")
        XCTAssertEqual(GameEngine.title(forLevel: 5), "Seeker")
        XCTAssertEqual(GameEngine.title(forLevel: 6), "Committed")
        XCTAssertEqual(GameEngine.title(forLevel: 11), "Consistent")
        XCTAssertEqual(GameEngine.title(forLevel: 16), "Devoted")
        XCTAssertEqual(GameEngine.title(forLevel: 21), "Steadfast")
        XCTAssertEqual(GameEngine.title(forLevel: 26), "Radiant")
        XCTAssertEqual(GameEngine.title(forLevel: 31), "Luminous")
        XCTAssertEqual(GameEngine.title(forLevel: 99), "Luminous", "title clamps at the end")

        // Titles only move forward through the list.
        var lastIndex = 0
        for level in 1...60 {
            let index = GameEngine.levelTitles.firstIndex(of: GameEngine.title(forLevel: level))!
            XCTAssertGreaterThanOrEqual(index, lastIndex)
            lastIndex = index
        }
    }

    // MARK: - Streak

    func testStreakIncrementOnFifthLog() {
        let dayKey = "2026-06-10"
        var logs: [PrayerLog] = []
        for prayer in [Prayer.fajr, .dhuhr, .asr, .maghrib] {
            logs.append(log(prayer, .onTime, dayKey: dayKey))
            XCTAssertFalse(GameEngine.isDayComplete(logs: logs, dayKey: dayKey))
        }
        logs.append(log(.isha, .qada, dayKey: dayKey))  // qada still counts for streak
        XCTAssertTrue(GameEngine.isDayComplete(logs: logs, dayKey: dayKey))

        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: dayKey)
        XCTAssertEqual(profile.streak, 1)
        XCTAssertEqual(profile.longestStreak, 1)
        XCTAssertEqual(profile.lastStreakDayKey, dayKey)

        // Same day again is a no-op.
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: dayKey)
        XCTAssertEqual(profile.streak, 1)
    }

    func testFreezeEarnedAtMultiplesOfSevenCappedAtTwo() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...21 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        XCTAssertEqual(profile.streak, 21)
        XCTAssertEqual(profile.streakFreezes, 2, "freezes earned at 7/14/21 but capped at 2")
        XCTAssertEqual(profile.longestStreak, 21)
    }

    func testReconcileConsumesFreezesThenResets() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...7 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        XCTAssertEqual(profile.streak, 7)
        XCTAssertEqual(profile.streakFreezes, 1)

        // One missed day → freeze consumed, streak survives.
        profile = GameEngine.reconcile(profile: profile, elapsedDays: [("day-8", false)])
        XCTAssertEqual(profile.streak, 7)
        XCTAssertEqual(profile.streakFreezes, 0)
        XCTAssertEqual(profile.lastReconciledDayKey, "day-8")

        // Next missed day with no freezes → reset to 0.
        profile = GameEngine.reconcile(profile: profile, elapsedDays: [("day-9", false)])
        XCTAssertEqual(profile.streak, 0)
        XCTAssertEqual(profile.lastReconciledDayKey, "day-9")

        // Complete days never consume anything.
        profile.streakFreezes = 2
        profile = GameEngine.reconcile(profile: profile,
                                       elapsedDays: [("day-10", true), ("day-11", true)])
        XCTAssertEqual(profile.streakFreezes, 2)
        XCTAssertEqual(profile.lastReconciledDayKey, "day-11")

        // longestStreak survives resets.
        XCTAssertEqual(profile.longestStreak, 7)
    }

    func testReverseStreakIncrement() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "2026-06-10")
        profile = GameEngine.reverseStreakIncrement(on: profile, dayKey: "2026-06-10")
        XCTAssertEqual(profile.streak, 0)
        XCTAssertNil(profile.lastStreakDayKey)

        // Reversing a day that didn't extend the streak is a no-op.
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "2026-06-11")
        let before = profile
        profile = GameEngine.reverseStreakIncrement(on: profile, dayKey: "2026-06-10")
        XCTAssertEqual(profile.streak, before.streak)
    }

    // MARK: - Undo gives back the freeze it granted, and only that one (v4.1)

    /// Below the cap, day 14 really does bank the second freeze — so undoing
    /// day 14 must hand exactly that one back, leaving the day-7 freeze alone.
    func testUndoingAFreezeEarningDayReturnsTheStreakToItsPriorFreezeCount() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...13 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        XCTAssertEqual(profile.streakFreezes, 1, "day 7 banked one; day 14 hasn't landed yet")

        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-14")
        XCTAssertEqual(profile.streakFreezes, 2)
        XCTAssertEqual(profile.lastStreakFreezeDayKey, "day-14")

        profile = GameEngine.reverseStreakIncrement(on: profile, dayKey: "day-14")
        XCTAssertEqual(profile.streak, 13)
        XCTAssertEqual(profile.streakFreezes, 1, "the freeze day 14 banked, and only that one")
        XCTAssertNil(profile.lastStreakFreezeDayKey)
        XCTAssertNil(profile.lastStreakDayKey)
    }

    /// At the cap, day 21 banks NOTHING — and undoing it must therefore take
    /// nothing. The old reversal read `streak % 7 == 0` and spent a freeze
    /// earned two weeks earlier: log the fifth prayer, tap undo, and a freeze
    /// you had banked and never used was gone.
    func testUndoingASeventhDayAtTheFreezeCapCannotStealABankedFreeze() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...20 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        XCTAssertEqual(profile.streakFreezes, 2, "days 7 and 14 filled the bank")

        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-21")
        XCTAssertEqual(profile.streak, 21)
        XCTAssertEqual(profile.streakFreezes, 2, "capped — day 21 banked nothing")
        XCTAssertNil(profile.lastStreakFreezeDayKey, "and the increment says so")

        profile = GameEngine.reverseStreakIncrement(on: profile, dayKey: "day-21")
        XCTAssertEqual(profile.streak, 20)
        XCTAssertEqual(profile.streakFreezes, 2,
                       "undo takes back what the increment gave — which was nothing")
    }

    /// The same thing through the door undo actually uses: take back the fifth
    /// prayer of a day-21 completion and the freezes must not move.
    func testUndoOfTheFifthPrayerAtTheFreezeCapKeepsBothFreezes() {
        let dayKey = "2026-06-30"
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...20 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        let logs = fullDay(dayKey: dayKey)
        profile.totalXP = logs.reduce(0) { $0 + $1.xp } + GameEngine.perfectDayBonus
        profile.perfectDayCount = 1
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: dayKey)
        XCTAssertEqual(profile.streakFreezes, 2)

        let undone = GameEngine.profileAfterUndo(of: logs[4], from: profile,
                                                 remainingLogs: Array(logs.prefix(4)))
        XCTAssertEqual(undone.streak, 20, "the day is no longer complete")
        XCTAssertEqual(undone.perfectDayCount, 0)
        XCTAssertEqual(undone.streakFreezes, 2, "and the two banked freezes survive the undo")
    }

    // MARK: - Perfect day

    func testPerfectDayDetection() {
        let dayKey = "2026-06-10"

        // All 5 in-window → perfect.
        var logs = fullDay(dayKey: dayKey, tier: .onTime)
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey))

        // Mixed in-window tiers still perfect.
        logs = [log(.fajr, .onTime, dayKey: dayKey), log(.dhuhr, .prayed, dayKey: dayKey),
                log(.asr, .lastCall, dayKey: dayKey), log(.maghrib, .onTime, dayKey: dayKey),
                log(.isha, .prayed, dayKey: dayKey)]
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey))

        // A qada disqualifies even with the other four on time.
        logs = [log(.fajr, .qada, dayKey: dayKey), log(.dhuhr, .onTime, dayKey: dayKey),
                log(.asr, .onTime, dayKey: dayKey), log(.maghrib, .onTime, dayKey: dayKey),
                log(.isha, .onTime, dayKey: dayKey)]
        XCTAssertFalse(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey))
        XCTAssertTrue(GameEngine.isDayComplete(logs: logs, dayKey: dayKey), "qada day still complete for streak")

        // Only 4 logged → not perfect.
        logs = Array(fullDay(dayKey: dayKey).dropLast())
        XCTAssertFalse(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey))

        // Other days' logs don't bleed in.
        XCTAssertFalse(GameEngine.isPerfectDay(logs: fullDay(dayKey: "2026-06-09"), dayKey: dayKey))
    }

    func testDayXPIncludesPerfectBonus() {
        let dayKey = "2026-06-10"
        let logs = fullDay(dayKey: dayKey, tier: .onTime)
        XCTAssertEqual(GameEngine.xp(forDay: dayKey, logs: logs), 5 * 30 + 25)

        var imperfect = logs
        imperfect[0] = log(.fajr, .qada, dayKey: dayKey)
        XCTAssertEqual(GameEngine.xp(forDay: dayKey, logs: imperfect), 5 + 4 * 30)
    }

    // MARK: - A break day earns no bonus in the race either (v4.2)

    /// Monday 2026-06-08, 06:00 — the hour every race fixture counts from.
    private var raceT0: Date { date(2026, 6, 8, 6, 0) }

    /// The same three-day climb `V2CoreTests` races with, built here so the
    /// pure engine can be questioned without a circle around it:
    ///
    /// * `2026-06-08` — four in-window and a qada isha. Complete, but the qada
    ///   disqualifies the day: 125, no bonus, ever.
    /// * `2026-06-09` — all five in-window, one an hour, finishing at `t0+9h`.
    ///   175 when the day counts, 150 when it was a break day.
    /// * `2026-06-10` — one more fajr at `t0+10h`.
    ///
    /// So the 25 XP of the middle day's bonus is the ONLY difference between
    /// the two readings, and it lands exactly on the 300 mark.
    private func raceWeek() -> [PrayerLog] {
        var logs: [PrayerLog] = []
        for (i, prayer) in Prayer.allCases.enumerated() {
            let tier: LogTier = (prayer == .isha) ? .qada : .onTime
            logs.append(log(prayer, tier, dayKey: "2026-06-08",
                            at: raceT0.addingTimeInterval(Double(i) * 3600)))
        }
        for (i, prayer) in Prayer.allCases.enumerated() {
            logs.append(log(prayer, .onTime, dayKey: "2026-06-09",
                            at: raceT0.addingTimeInterval(Double(5 + i) * 3600)))
        }
        logs.append(log(.fajr, .onTime, dayKey: "2026-06-10",
                        at: raceT0.addingTimeInterval(10 * 3600)))
        return logs
    }

    /// Five prayers, all in their windows, on a day you were excused from: 150,
    /// not 175. `isPerfectDay` has said so since v2 and every other total has
    /// asked it — the race arrived a release late and asked nobody.
    func testRaceXPGivesAnExcusedDayNoPerfectBonus() {
        let week = raceWeek()
        XCTAssertEqual(GameEngine.raceXP(logs: week, excusedDayKeys: []), 125 + 175 + 30,
                       "no break days: the middle day is perfect and pays 25")
        XCTAssertEqual(GameEngine.raceXP(logs: week, excusedDayKeys: ["2026-06-09"]),
                       125 + 150 + 30,
                       "a break day: the five prayers still count, the bonus does not")

        // The middle day alone, so the 175/150 is unmistakably that day's.
        let midweek = week.filter { $0.dayKey == "2026-06-09" }
        XCTAssertEqual(GameEngine.raceXP(logs: midweek, excusedDayKeys: []), 175)
        XCTAssertEqual(GameEngine.raceXP(logs: midweek, excusedDayKeys: ["2026-06-09"]), 150)

        // Somebody else's break day is not yours: an unrelated key changes nothing.
        XCTAssertEqual(GameEngine.raceXP(logs: week, excusedDayKeys: ["2026-06-11"]),
                       GameEngine.raceXP(logs: week, excusedDayKeys: []))
    }

    /// And the crossing agrees with the total, which is the whole point of
    /// v4.1: the bar and the crown may not read different numbers. Excused, the
    /// week reaches 300 an hour later — at the next day's fajr, not on the
    /// prayer that would have completed a "perfect" rest day.
    func testRaceCrossingGivesAnExcusedDayNoPerfectBonus() {
        let week = raceWeek()
        XCTAssertEqual(GameEngine.raceCrossing(logs: week, threshold: 300, excusedDayKeys: []),
                       raceT0.addingTimeInterval(9 * 3600),
                       "the bonus lands with the fifth in-window prayer, at 300 exactly")
        XCTAssertEqual(GameEngine.raceCrossing(logs: week, threshold: 300,
                                               excusedDayKeys: ["2026-06-09"]),
                       raceT0.addingTimeInterval(10 * 3600),
                       "without the bonus the week is 275 there, and crosses an hour later")

        // 275 IS reached at t0+9h either way — the excused day loses the bonus,
        // never the prayers.
        XCTAssertEqual(GameEngine.raceCrossing(logs: week, threshold: 275,
                                               excusedDayKeys: ["2026-06-09"]),
                       raceT0.addingTimeInterval(9 * 3600))

        // Stop before the last day and the excused week never crosses at all.
        let throughMidweek = week.filter { $0.dayKey != "2026-06-10" }
        XCTAssertNotNil(GameEngine.raceCrossing(logs: throughMidweek, threshold: 300,
                                                excusedDayKeys: []))
        XCTAssertNil(GameEngine.raceCrossing(logs: throughMidweek, threshold: 300,
                                             excusedDayKeys: ["2026-06-09"]),
                     "275 is not 300 — a break day cannot carry you over the line")
    }

    /// The crown is FIRST PAST THE POST, and this pins the half that surprises
    /// people: a make-up logged onto a day that was perfect voids its 25-XP
    /// bonus (and pays 5), so the week's total drops back BELOW the target —
    /// and the crossing stands, because it happened hours earlier. The progress
    /// bar reading 280/300 under a standing crown is the intended behaviour of
    /// a race to a target, not a bug to be tidied away.
    func testACrossingSurvivesAMakeUpThatVoidsTheBonusItWasWonWith() {
        var week = raceWeek().filter { $0.dayKey != "2026-06-10" }   // 125 + 175 = 300
        XCTAssertEqual(GameEngine.raceXP(logs: week, excusedDayKeys: []), 300)
        let wonAt = GameEngine.raceCrossing(logs: week, threshold: 300, excusedDayKeys: [])
        XCTAssertEqual(wonAt, raceT0.addingTimeInterval(9 * 3600))

        // A travel day can hold six: a make-up lands on the perfect day, a day
        // later, and takes the bonus back with it.
        week.append(log(.dhuhr, .qada, dayKey: "2026-06-09",
                        at: raceT0.addingTimeInterval(30 * 3600)))
        XCTAssertEqual(GameEngine.raceXP(logs: week, excusedDayKeys: []), 280,
                       "the bar falls under the target — 25 gone, 5 paid")
        XCTAssertEqual(GameEngine.raceCrossing(logs: week, threshold: 300, excusedDayKeys: []),
                       wonAt,
                       "the crown was won at t0+9h and stays won: first past the post")

        // The other half of the same rule: nothing is banked, so deleting the
        // logs that did the crossing gives the crown back.
        let undone = week.filter { !($0.dayKey == "2026-06-09" && $0.prayer == .isha) }
        XCTAssertNil(GameEngine.raceCrossing(logs: undone, threshold: 300, excusedDayKeys: []),
                     "a crown falls with its basis — it is recomputed, never remembered")
    }

    // MARK: - Week math (BuddySimulator)

    func testWeekMath() {
        let wed = date(2026, 6, 10, 15, 0)
        let start = BuddySimulator.weekStart(for: wed)
        let weekday = Calendar.current.component(.weekday, from: start)
        XCTAssertEqual(weekday, 2, "week starts on Monday")
        XCTAssertEqual(Calendar.current.startOfDay(for: start), start, "week starts at 00:00")
        XCTAssertEqual(BuddySimulator.weekEnd(for: wed).timeIntervalSince(start), 7 * 86400, accuracy: 3700)
        XCTAssertTrue(start <= wed && wed < BuddySimulator.weekEnd(for: wed))

        let keys = BuddySimulator.weekDayKeys(for: wed)
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(keys.first, AppClock.dayKey(for: start), "Mon-first")

        // Different weeks → different week keys.
        XCTAssertNotEqual(BuddySimulator.weekKey(for: wed),
                          BuddySimulator.weekKey(for: date(2026, 6, 17, 15, 0)))
    }

    func testWeeklyXPFromRealLogs() {
        let wed = date(2026, 6, 10, 12, 0)
        let weekStart = BuddySimulator.weekStart(for: wed)
        let inWeekKey = AppClock.dayKey(for: weekStart.addingTimeInterval(2 * 86400 + 3600))
        let beforeWeekKey = AppClock.dayKey(for: weekStart.addingTimeInterval(-86400))

        var logs = fullDay(dayKey: inWeekKey, tier: .onTime)         // 150 + 25 perfect
        logs += [log(.fajr, .onTime, dayKey: beforeWeekKey)]         // outside week, ignored
        XCTAssertEqual(GameEngine.weeklyXP(logs: logs, weekStart: weekStart), 175)
    }

    // MARK: - Undoing a recovery action (v4: un-tick a good deed)

    func testUndoingADeedTakesBackExactlyWhatItGranted() {
        // Nothing near the cap: 3 deeds = 30 earned, drop one and 20 stands.
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: 30,
                                                          remainingRawTotal: 20), 20)
    }

    func testUndoingADeedThatEarnedNothingTakesBackNothing() {
        // The cap was already spent when this one was ticked, so it granted 0.
        // Subtracting deedXP here would invent a debt: 4 deeds are worth 40
        // raw but only 25 was ever granted, and 3 deeds are still worth more
        // than 25, so the total must not move.
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: 25,
                                                          remainingRawTotal: 30), 25)
    }

    func testUndoNeverStripsXPBankedBeforeTheCapShrank() {
        // The pathological case, and the reason this is not a recompute:
        // 150 earned from dhikr in the morning (cap was 150, no prayer XP),
        // then all five prayers land and the cap drops to 0. The 150 is
        // legitimately banked. Undoing one deed may take back that deed and
        // nothing more.
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: 150,
                                                          remainingRawTotal: 140), 140)
    }

    func testUndoingTheOnlyActionClearsTheDay() {
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: 10,
                                                          remainingRawTotal: 0), 0)
    }

    func testUndoNeverReturnsANegative() {
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: 0,
                                                          remainingRawTotal: 0), 0)
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: -5,
                                                          remainingRawTotal: 20), 0)
    }

    func testCompleteThenUndoIsAClosedLoop() {
        // Grant and reverse with the SAME pure pieces the app uses, so the
        // pair cannot drift apart: 2 deeds granted under a roomy cap, then
        // one taken back, must land exactly on one deed's worth.
        let first = GameEngine.recoveryGrant(amount: GameEngine.deedXP, earnedToday: 0,
                                             onBreak: true, prayerXPToday: 0)
        let second = GameEngine.recoveryGrant(amount: GameEngine.deedXP, earnedToday: first,
                                              onBreak: true, prayerXPToday: 0)
        let earned = first + second
        XCTAssertEqual(earned, 2 * GameEngine.deedXP)
        XCTAssertEqual(GameEngine.recoveryEarnedAfterUndo(earnedToday: earned,
                                                          remainingRawTotal: GameEngine.deedXP),
                       GameEngine.deedXP)
    }

    // MARK: - Travel (v4: a day spent crossing timezones is not a whole day)

    func testDSTNeverCountsAsTravel() {
        // The single most important case here. A DST jump is exactly one hour
        // and happens to EVERY user in a region on the same night; if it
        // tripped the travel threshold, the entire user base would silently
        // bank a free day twice a year.
        XCTAssertFalse(GameEngine.isTravelShift(from: -8 * 3600, to: -7 * 3600))
        XCTAssertFalse(GameEngine.isTravelShift(from: -7 * 3600, to: -8 * 3600))
    }

    func testANeighbouringTimezoneIsNotTravel() {
        // A one-hour day is still a day you can pray five times in.
        XCTAssertFalse(GameEngine.isTravelShift(from: 0, to: 3600))
        // Two hours is still under the bar.
        XCTAssertFalse(GameEngine.isTravelShift(from: 0, to: 2 * 3600))
    }

    func testLongHaulCountsAsTravel() {
        // Seattle (-7) to Mumbai (+5:30) — the case that motivated all of this.
        XCTAssertTrue(GameEngine.isTravelShift(from: -7 * 3600, to: 5 * 3600 + 1800))
        // And back again.
        XCTAssertTrue(GameEngine.isTravelShift(from: 5 * 3600 + 1800, to: -7 * 3600))
        // The boundary is inclusive: exactly three hours counts.
        XCTAssertTrue(GameEngine.isTravelShift(from: 0, to: GameEngine.travelOffsetThreshold))
    }

    func testFirstEverObservationIsNotAChange() {
        // A device that has never looked has not moved.
        XCTAssertFalse(GameEngine.isTravelShift(from: nil, to: 5 * 3600 + 1800))
    }

    func testReconcileSkipsTravelDaysWithoutSpendingAFreeze() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.streak = 12
        profile.streakFreezes = 2
        profile.lastReconciledDayKey = "2026-08-20"

        // An incomplete day spent in the air. The streak survives AND no
        // freeze is spent — a freeze is for a day you could have prayed.
        let reconciled = GameEngine.reconcile(
            profile: profile,
            elapsedDays: [("2026-08-21", false)],
            travelDayKeys: ["2026-08-21"])

        XCTAssertEqual(reconciled.streak, 12, "crossing timezones must not break a streak")
        XCTAssertEqual(reconciled.streakFreezes, 2, "and must not cost a freeze either")
        XCTAssertEqual(reconciled.lastReconciledDayKey, "2026-08-21", "the walk still advances")
    }

    func testAnOrdinaryIncompleteDayStillCostsAFreeze() {
        // The control: without the travel mark, nothing about the above holds.
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.streak = 12
        profile.streakFreezes = 2
        profile.lastReconciledDayKey = "2026-08-20"

        let reconciled = GameEngine.reconcile(profile: profile,
                                              elapsedDays: [("2026-08-21", false)])
        XCTAssertEqual(reconciled.streak, 12)
        XCTAssertEqual(reconciled.streakFreezes, 1, "an ordinary miss spends a freeze")
    }

    func testTravelAndExcusedAreIndependentReasonsToSkip() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.streak = 5
        profile.streakFreezes = 0     // nothing to absorb a real miss
        profile.lastReconciledDayKey = "2026-08-19"

        let reconciled = GameEngine.reconcile(
            profile: profile,
            elapsedDays: [("2026-08-20", false), ("2026-08-21", false)],
            excusedDayKeys: ["2026-08-20"],
            travelDayKeys: ["2026-08-21"])
        XCTAssertEqual(reconciled.streak, 5, "one excused, one travelled, neither breaks it")
    }

    // MARK: - Prayer identity (v4: dayKey groups a DAY, it does not name a PRAYER)

    // The zones the whole feature is about. Seattle in August is UTC-7;
    // Mumbai is UTC+5:30, twelve and a half hours away.
    private var seattle: Int { -7 * 3600 }
    private var mumbai: Int { 5 * 3600 + 1800 }

    /// Row 1 of the table: same zone, delta 0. The overwhelmingly common case,
    /// and the one that must not move a millimetre — a prayer logged where you
    /// are standing is logged, and asking again gets the same answer.
    func testSameZoneIsTheSamePrayerAndCannotBeDoubleLogged() {
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: seattle,
                                                      currentOffset: seattle))

        let logs = [log(.fajr, .onTime, dayKey: "2026-08-22", offset: seattle)]
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .fajr, dayKey: "2026-08-22",
                                                  currentOffset: seattle, in: logs),
                        "logging fajr twice at home is still a no-op")
    }

    /// Row 2: a calc-method or madhab change moves the WINDOW without moving
    /// the zone, so identity must not be keyed on the window.
    ///
    /// The assertion has two halves on purpose. The first proves the premise is
    /// real — switching to Hanafi genuinely shifts Asr by the better part of an
    /// hour — and the second proves the identity rule is blind to it. Had we
    /// used window-start as the identity, every Asr ever logged would have read
    /// as unlogged the moment somebody changed a setting in Settings.
    func testAMadhabChangeMovesTheWindowButNotThePrayer() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = date(2026, 8, 22, 12, 0)

        let shafi = try XCTUnwrap(PrayerTimeService.schedule(for: day, latitude: 47.6062,
                                                             longitude: -122.3321,
                                                             method: .northAmerica, madhab: .shafi,
                                                             calendar: calendar))
        let hanafi = try XCTUnwrap(PrayerTimeService.schedule(for: day, latitude: 47.6062,
                                                              longitude: -122.3321,
                                                              method: .northAmerica, madhab: .hanafi,
                                                              calendar: calendar))
        let shafiAsr = try XCTUnwrap(shafi.window(for: .asr)).start
        let hanafiAsr = try XCTUnwrap(hanafi.window(for: .asr)).start
        XCTAssertGreaterThan(hanafiAsr.timeIntervalSince(shafiAsr), 30 * 60,
                             "premise: the madhab really does move Asr by most of an hour")

        // The zone did not move, so the prayer did not change.
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: seattle,
                                                      currentOffset: seattle))
        let logs = [log(.asr, .onTime, dayKey: "2026-08-22", offset: seattle)]
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .asr, dayKey: "2026-08-22",
                                                  currentOffset: seattle, in: logs),
                        "a settings change must never un-log a prayer somebody prayed")
    }

    /// Row 3: DST. Exactly one hour, mid-window, to every user in a region at
    /// once. Tolerance rather than equality exists for this: on an equality
    /// rule the clocks going back would re-open every prayer logged that day
    /// and hand out a second helping of XP nationwide.
    func testADSTShiftLeavesThePrayerLogged() {
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: -8 * 3600,
                                                      currentOffset: -7 * 3600))
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: -7 * 3600,
                                                      currentOffset: -8 * 3600))

        let logs = [log(.maghrib, .onTime, dayKey: "2026-11-01", offset: -7 * 3600)]
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .maghrib, dayKey: "2026-11-01",
                                                  currentOffset: -8 * 3600, in: logs))
    }

    /// Row 4: the case the whole change exists for. Mumbai's fajr and Seattle's
    /// fajr on 2026-08-22 share a calendar date and are two different prayers,
    /// prayed hours apart. The second one must be loggable.
    func testALongHaulFlightMakesTheSecondFajrANewPrayer() {
        XCTAssertFalse(GameEngine.isSamePrayerInstance(storedOffset: mumbai,
                                                       currentOffset: seattle))
        XCTAssertFalse(GameEngine.isSamePrayerInstance(storedOffset: seattle,
                                                       currentOffset: mumbai))

        let logs = [log(.fajr, .onTime, dayKey: "2026-08-22", offset: mumbai)]
        XCTAssertNil(GameEngine.loggedInstance(prayer: .fajr, dayKey: "2026-08-22",
                                               currentOffset: seattle, in: logs),
                     "landed in Seattle, fajr came round again, and it must be loggable")
        // ...while the prayer you actually prayed in Mumbai is still found from
        // Mumbai. Neither zone erases the other.
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .fajr, dayKey: "2026-08-22",
                                                  currentOffset: mumbai, in: logs))
    }

    /// The boundary, shared with `isTravelShift` and deliberately so. Under
    /// three hours is the same prayer; three hours exactly is a new one.
    func testTheIdentityThresholdIsTheTravelThreshold() {
        let below = GameEngine.travelOffsetThreshold - 1
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: 0, currentOffset: below))
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: 0, currentOffset: -below))
        XCTAssertFalse(GameEngine.isSamePrayerInstance(storedOffset: 0,
                                                       currentOffset: GameEngine.travelOffsetThreshold))
        XCTAssertFalse(GameEngine.isSamePrayerInstance(storedOffset: 0,
                                                       currentOffset: -GameEngine.travelOffsetThreshold))
    }

    /// Row 5: every log written before v4 has no offset. Those match ANYTHING,
    /// which is the conservative direction — old history can lose a duplicate
    /// it should have been allowed, but it can never GAIN one it should not.
    func testALegacyLogWithNoOffsetMatchesEveryZone() {
        for zone in [seattle, mumbai, 0, 14 * 3600] {
            XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: nil, currentOffset: zone),
                          "a pre-v4 log has no zone to disagree with")
        }
        let legacy = [log(.isha, .prayed, dayKey: "2026-01-04")]     // helper defaults to nil
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .isha, dayKey: "2026-01-04",
                                                  currentOffset: mumbai, in: legacy))
        XCTAssertNotNil(GameEngine.loggedInstance(prayer: .isha, dayKey: "2026-01-04",
                                                  currentOffset: seattle, in: legacy))
    }

    /// The property that matters more than any of the above: for somebody who
    /// never changes zone, identity answers EXACTLY what the old dayKey-only
    /// lookup answered — for every prayer, on a full day, with offsets present
    /// and with the nil offsets of a pre-v4 save.
    func testStayingPutBehavesExactlyAsBefore() {
        for offset: Int? in [nil, seattle, mumbai, 0] {
            let logs: [PrayerLog] = Prayer.allCases.map {
                log($0, .onTime, dayKey: "2026-08-22", offset: offset)
            }
            let current: Int = offset ?? seattle
            for prayer in Prayer.allCases {
                let identity = GameEngine.loggedInstance(prayer: prayer, dayKey: "2026-08-22",
                                                         currentOffset: current, in: logs)
                let dayKeyOnly = logs.first { $0.prayer == prayer && $0.dayKey == "2026-08-22" }
                XCTAssertEqual(identity?.id, dayKeyOnly?.id,
                               "same zone: identity must be the old lookup, exactly")
                XCTAssertNil(GameEngine.loggedInstance(prayer: prayer, dayKey: "2026-08-21",
                                                       currentOffset: current, in: logs),
                             "and it must not reach into another day")
            }
        }
    }

    /// A six-prayer day: two fajrs on one calendar date, because the flight
    /// landed before the second one. dayKey stays the GROUPING key, so all six
    /// belong to one day — one completion, one streak increment, and XP summed
    /// over every one of them.
    func testASixPrayerTravelDayIsStillOneDay() {
        let key = "2026-08-22"
        var logs: [PrayerLog] = [log(.fajr, .onTime, dayKey: key, offset: mumbai)]
        logs.append(log(.fajr, .onTime, dayKey: key, offset: seattle))
        for prayer in Prayer.allCases where prayer != .fajr {
            logs.append(log(prayer, .onTime, dayKey: key, offset: seattle))
        }
        XCTAssertEqual(logs.count, 6)

        // ONE day, and a complete one — grouping is untouched by the extra log.
        XCTAssertTrue(GameEngine.isDayComplete(logs: logs, dayKey: key))
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: key))

        // XP counts all six prayers, plus the single perfect-day bonus. The
        // sixth prayer was really prayed; it is not a duplicate to be swallowed.
        XCTAssertEqual(GameEngine.xp(forDay: key, logs: logs),
                       6 * LogTier.onTime.xp + GameEngine.perfectDayBonus)

        // ONE streak increment, no matter how many times completion is noticed.
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.streak = 4
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: key)
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: key)
        XCTAssertEqual(profile.streak, 5, "six prayers, one day, one increment")

        // And the identity rule keeps the two fajrs apart: each zone sees its own.
        let fromMumbai = GameEngine.loggedInstance(prayer: .fajr, dayKey: key,
                                                   currentOffset: mumbai, in: logs)
        let fromSeattle = GameEngine.loggedInstance(prayer: .fajr, dayKey: key,
                                                    currentOffset: seattle, in: logs)
        XCTAssertNotNil(fromMumbai)
        XCTAssertNotNil(fromSeattle)
        XCTAssertNotEqual(fromMumbai?.id, fromSeattle?.id)
    }

    // MARK: - One log, one answer (the resolver every caller shares)

    /// Two logs can match at once, and every caller must be told the SAME one.
    ///
    /// Tolerance is not equality, so two logs three to six hours of zone apart
    /// can BOTH sit within three hours of where the device is standing now:
    /// fajr in Seattle (-07:00) and fajr in New York (-04:00), asked from
    /// Chicago (-05:00). Before this, `status(of:)` took `first` and `undoLog`
    /// took `lastIndex` — the tile rendered Seattle's onTime while Undo deleted
    /// New York's qada, so the button looked dead, a friend's post vanished,
    /// and 5 XP came off a tile that was advertising 30.
    func testTwoMatchingLogsResolveToOneAndTheSameLog() {
        let key = "2026-08-22"
        let chicago = -5 * 3600
        let seattleFajr = log(.fajr, .onTime, dayKey: key, offset: -7 * 3600)
        let newYorkFajr = log(.fajr, .qada, dayKey: key, offset: -4 * 3600)
        let logs = [seattleFajr, newYorkFajr]

        // Premise: both really do match. If this stops being true the test
        // below is proving nothing.
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: seattleFajr.utcOffset,
                                                      currentOffset: chicago))
        XCTAssertTrue(GameEngine.isSamePrayerInstance(storedOffset: newYorkFajr.utcOffset,
                                                      currentOffset: chicago))

        // The closest zone wins — 1h away beats 2h away.
        let shown = GameEngine.loggedInstance(prayer: .fajr, dayKey: key,
                                              currentOffset: chicago, in: logs)
        XCTAssertEqual(shown?.id, newYorkFajr.id)

        // And undo's index resolves to that very log, not to whichever the
        // array happens to end with.
        let index = GameEngine.loggedInstanceIndex(prayer: .fajr, dayKeys: [key],
                                                   currentOffset: chicago, in: logs)
        XCTAssertEqual(index.map { logs[$0].id }, shown?.id,
                       "what the tile shows is what Undo takes back")

        // Reversing the array must not change either answer.
        let reversed: [PrayerLog] = logs.reversed()
        XCTAssertEqual(GameEngine.loggedInstance(prayer: .fajr, dayKey: key,
                                                 currentOffset: chicago, in: reversed)?.id,
                       newYorkFajr.id)
    }

    /// A real zone beats a zoneless legacy log. "Matches anything"
    /// distinguishes nothing, so it can only ever be the fallback.
    func testARealZoneOutranksAZonelessLegacyLog() {
        let key = "2026-08-22"
        let legacy = log(.asr, .qada, dayKey: key)                    // no offset
        let here = log(.asr, .onTime, dayKey: key, offset: seattle)
        for order in [[legacy, here], [here, legacy]] {
            XCTAssertEqual(GameEngine.loggedInstance(prayer: .asr, dayKey: key,
                                                     currentOffset: seattle, in: order)?.id,
                           here.id, "the log that knows where it was wins")
        }
        // On its own, the legacy log is still the answer — it matches anything.
        XCTAssertEqual(GameEngine.loggedInstance(prayer: .asr, dayKey: key,
                                                 currentOffset: mumbai, in: [legacy])?.id,
                       legacy.id)
    }

    /// Undo reaches yesterday's key for a late isha (§6.8), and it has to do so
    /// through the same resolver — that is the only reason `dayKeys` is a set.
    func testUndoResolvesAnAfterMidnightIshaOnYesterdaysKey() {
        let yesterday = "2026-08-21"
        let entry = log(.isha, .onTime, dayKey: yesterday, offset: seattle)
        let index = GameEngine.loggedInstanceIndex(prayer: .isha,
                                                   dayKeys: [yesterday, "2026-08-22"],
                                                   currentOffset: seattle, in: [entry])
        XCTAssertEqual(index, 0)
        // ...and a zone half a world away is somebody else's isha.
        XCTAssertNil(GameEngine.loggedInstanceIndex(prayer: .isha,
                                                    dayKeys: [yesterday, "2026-08-22"],
                                                    currentOffset: mumbai, in: [entry]))
    }

    // MARK: - Undo (bonuses come off on a transition, not on a removal)

    /// The traveller's six-prayer day, undone. All five prayers were logged in
    /// window and the perfect day is banked; a sixth (the other side of a
    /// flight) is logged and then taken back. The day is STILL perfect and
    /// STILL complete, so nothing but that log's own XP may come off.
    func testUndoingADuplicateLeavesAStillPerfectDayIntact() {
        let key = "2026-08-22"
        var logs: [PrayerLog] = Prayer.allCases.map {
            log($0, .onTime, dayKey: key, offset: seattle)
        }
        let duplicate = log(.dhuhr, .onTime, dayKey: key, offset: -4 * 3600)
        logs.append(duplicate)

        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.totalXP = 6 * LogTier.onTime.xp + GameEngine.perfectDayBonus
        profile.perfectDayCount = 1
        profile.streak = 5
        profile.longestStreak = 5
        profile.lastStreakDayKey = key

        let remaining: [PrayerLog] = logs.filter { $0.id != duplicate.id }
        let after = GameEngine.profileAfterUndo(of: duplicate, from: profile,
                                                remainingLogs: remaining)

        XCTAssertEqual(after.totalXP, 5 * LogTier.onTime.xp + GameEngine.perfectDayBonus,
                       "only the undone prayer's own XP comes off")
        XCTAssertEqual(after.perfectDayCount, 1, "the day is still perfect")
        XCTAssertEqual(after.streak, 5, "the day is still complete")
        XCTAssertEqual(after.lastStreakDayKey, key)
    }

    /// The other half: undoing the prayer that really does break the day still
    /// costs the bonus and reverses the increment, exactly once.
    func testUndoingTheLastCopyOfAPrayerStillBreaksTheDay() throws {
        let key = "2026-08-22"
        let full: [PrayerLog] = Prayer.allCases.map {
            log($0, .onTime, dayKey: key, offset: seattle)
        }
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.totalXP = 5 * LogTier.onTime.xp + GameEngine.perfectDayBonus
        profile.perfectDayCount = 1
        profile.streak = 5
        profile.longestStreak = 5
        profile.lastStreakDayKey = key

        let dhuhr = try XCTUnwrap(full.first { $0.prayer == .dhuhr })
        let after = GameEngine.profileAfterUndo(of: dhuhr, from: profile,
                                                remainingLogs: full.filter { $0.id != dhuhr.id })
        XCTAssertEqual(after.totalXP, 4 * LogTier.onTime.xp)
        XCTAssertEqual(after.perfectDayCount, 0)
        XCTAssertEqual(after.streak, 4)
        XCTAssertNil(after.lastStreakDayKey)
    }

    /// Undoing BOTH copies charges the perfect day once, not twice — the
    /// regression that the old "was perfect before the removal" reading
    /// produced the moment a day could hold two logs for one prayer.
    func testUndoingBothCopiesChargesThePerfectDayOnlyOnce() throws {
        let key = "2026-08-22"
        var logs: [PrayerLog] = Prayer.allCases.map {
            log($0, .onTime, dayKey: key, offset: seattle)
        }
        let duplicate = log(.dhuhr, .onTime, dayKey: key, offset: -4 * 3600)
        logs.append(duplicate)

        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.totalXP = 6 * LogTier.onTime.xp + GameEngine.perfectDayBonus
        profile.perfectDayCount = 1
        profile.streak = 5
        profile.lastStreakDayKey = key

        logs.removeAll { $0.id == duplicate.id }
        profile = GameEngine.profileAfterUndo(of: duplicate, from: profile, remainingLogs: logs)

        let original = try XCTUnwrap(logs.first { $0.prayer == .dhuhr })
        logs.removeAll { $0.id == original.id }
        profile = GameEngine.profileAfterUndo(of: original, from: profile, remainingLogs: logs)

        XCTAssertEqual(profile.totalXP, 4 * LogTier.onTime.xp,
                       "two undos, four prayers left, one perfect-day bonus reversed")
        XCTAssertEqual(profile.perfectDayCount, 0)
        XCTAssertEqual(profile.streak, 4)
    }

    /// Undo can never take the total below zero, and a day that was never
    /// perfect never had a bonus to lose.
    func testUndoingAnOrdinaryLogTouchesNothingElse() {
        let key = "2026-08-22"
        let entry = log(.fajr, .qada, dayKey: key, offset: seattle)
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        profile.totalXP = 2
        profile.streak = 3
        profile.lastStreakDayKey = "2026-08-21"

        let after = GameEngine.profileAfterUndo(of: entry, from: profile, remainingLogs: [])
        XCTAssertEqual(after.totalXP, 0, "clamped, never negative")
        XCTAssertEqual(after.streak, 3)
        XCTAssertEqual(after.lastStreakDayKey, "2026-08-21")
        XCTAssertEqual(after.perfectDayCount, 0)
    }

    // MARK: - Photo retention (a JPEG lives exactly as long as a log wants it)

    /// The plain case, from both ends: the log took the photo, so the file
    /// stays; nothing took it, so the file goes.
    func testAPhotoIsAnOrphanExactlyWhenNoLogPointsAtIt() {
        let key = "2026-08-22"
        let kept = log(.fajr, .onTime, dayKey: key, photo: "fajr.jpg")

        XCTAssertFalse(GameEngine.isPhotoOrphaned("fajr.jpg", in: [kept]),
                       "the log that was just written is holding it")
        XCTAssertTrue(GameEngine.isPhotoOrphaned("fajr.jpg", in: []),
                      "no logs at all — nothing will ever come looking")
        XCTAssertTrue(GameEngine.isPhotoOrphaned("fajr.jpg", in: [log(.asr, .onTime, dayKey: key,
                                                                     photo: "asr.jpg")]),
                      "someone else's photo is no reason to keep this one")
    }

    /// THE BUG. The confirm screen sat open across the end of the window, so by
    /// the time "Post" was tapped the tier was qada — the log lands, and
    /// `buildLog` drops the photo on purpose because a qada carries none. The
    /// JPEG is already on the disk, and nothing in the accepted log points at
    /// it.
    ///
    /// The two halves are asserted together on purpose: the lapse is what makes
    /// the tier qada, and the qada is what makes the file an orphan.
    func testALapsedWindowLeavesTheJustWrittenPhotoBehind() {
        let start = date(2026, 8, 22, 12, 0)
        let window = PrayerWindow(prayer: .dhuhr, start: start,
                                  end: start.addingTimeInterval(120 * 60))

        // Confirm screen opened inside the window, posted after it closed.
        XCTAssertEqual(GameEngine.tier(for: window, at: start.addingTimeInterval(60)), .onTime)
        let lapsed = GameEngine.tier(for: window, at: window.end)
        XCTAssertEqual(lapsed, .qada, "the window closed while the sheet was open")
        XCTAssertFalse(LogTier.qada.isInWindow, "which is why the log drops the photo")

        // What `log` actually appended: a qada, no photo.
        let landed = log(.dhuhr, .qada, dayKey: "2026-08-22", photo: nil)
        XCTAssertTrue(GameEngine.isPhotoOrphaned("2026-08-22_dhuhr_ab12cd34.jpg", in: [landed]),
                      "the accepted log took no photo, so the file must not survive it")
    }

    /// A refusal leaves the same mess by a different route: `log` no-ops when
    /// the prayer is already logged, and the second post's JPEG is left over
    /// while the FIRST one's is still rightfully in use.
    func testARefusedSecondPostLosesItsOwnPhotoAndOnlyItsOwn() {
        let key = "2026-08-22"
        let first = log(.maghrib, .onTime, dayKey: key, photo: "first.jpg")

        XCTAssertTrue(GameEngine.isPhotoOrphaned("second.jpg", in: [first]),
                      "the double-log was refused — its photo is nobody's")
        XCTAssertFalse(GameEngine.isPhotoOrphaned("first.jpg", in: [first]),
                       "and the post that DID land keeps its own")
    }

    /// v3.3, and it must not regress: a travel-combined pair is TWO logs
    /// sharing ONE photo. Undoing one side may not delete the picture the other
    /// side still draws — only undoing both frees the file.
    func testATravelPairSharesOnePhotoUntilBothSidesAreGone() {
        let key = "2026-08-22"
        let shared = "pair.jpg"
        let lead = log(.dhuhr, .onTime, dayKey: key, photo: shared)
        let follow = log(.asr, .onTime, dayKey: key, photo: shared)

        XCTAssertFalse(GameEngine.isPhotoOrphaned(shared, in: [lead, follow]),
                       "both sides posted — plainly in use")
        XCTAssertFalse(GameEngine.isPhotoOrphaned(shared, in: [lead]),
                       "asr undone, dhuhr still shows it")
        XCTAssertFalse(GameEngine.isPhotoOrphaned(shared, in: [follow]),
                       "and the same the other way round")
        XCTAssertTrue(GameEngine.isPhotoOrphaned(shared, in: []),
                      "only once neither side is left")
    }

    /// A combined post that landed is the same question the camera flow asks
    /// straight after `logCombined` — the file it just wrote is spoken for
    /// twice over, and the success path must not touch it.
    func testACombinedPostKeepsItsPhotoAlongsideAnUnrelatedDay() {
        let shared = "pair.jpg"
        let logs: [PrayerLog] = [
            log(.fajr, .onTime, dayKey: "2026-08-21", photo: "yesterday.jpg"),
            log(.dhuhr, .onTime, dayKey: "2026-08-22", photo: shared),
            log(.asr, .onTime, dayKey: "2026-08-22", photo: shared),
            log(.isha, .qada, dayKey: "2026-08-22")
        ]
        XCTAssertFalse(GameEngine.isPhotoOrphaned(shared, in: logs))
        XCTAssertFalse(GameEngine.isPhotoOrphaned("yesterday.jpg", in: logs))
        XCTAssertTrue(GameEngine.isPhotoOrphaned("never-written.jpg", in: logs))
    }

    /// nil and "" are absences, not orphans. "" is what `PhotoStore.save`
    /// returns when the disk write failed — there is no file to take back, and
    /// the prayer was logged without one, exactly as intended.
    func testAFailedWriteIsNothingToCleanUp() {
        let logs: [PrayerLog] = [log(.fajr, .onTime, dayKey: "2026-08-22")]
        XCTAssertFalse(GameEngine.isPhotoOrphaned(nil, in: logs))
        XCTAssertFalse(GameEngine.isPhotoOrphaned("", in: logs))
        XCTAssertFalse(GameEngine.isPhotoOrphaned(nil, in: []))
        XCTAssertFalse(GameEngine.isPhotoOrphaned("", in: []))
    }

    // MARK: - The confirm screen's deadline (warn before, and after)

    /// The boundary that matters, from both sides of it. `lapseNotice` and
    /// `tier` have to agree to the SECOND about where the window ends, because
    /// the notice is a promise about what the very next tap will do: one second
    /// before the end the tap still earns in-window XP and the screen counts
    /// down to it, and AT the end it books a make-up and the screen must say so
    /// instead of showing "0s left".
    func testTheNoticeFlipsAtExactlyTheInstantTheTierDoes() {
        let start = date(2026, 8, 22, 12, 0)
        let window = PrayerWindow(prayer: .dhuhr, start: start,
                                  end: start.addingTimeInterval(120 * 60))
        let end = window.end

        // Just before: still in the window, still counting down.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-1)),
                       .closingSoon)
        XCTAssertEqual(GameEngine.tier(for: window, at: end.addingTimeInterval(-1)), .closeCall)

        // Exactly at the end: closed, and the tap would book a qada.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end), .closed)
        XCTAssertEqual(GameEngine.tier(for: window, at: end), .qada)

        // After: still closed, no matter how long after.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(1)),
                       .closed)
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(5 * 3600)),
                       .closed)
    }

    /// The other boundary: when the notice APPEARS. Silence for the whole
    /// window until the lead time, then the countdown — an ordinary post must
    /// never see this thing.
    func testTheNoticeStaysSilentUntilTheLeadTime() {
        let end = date(2026, 8, 22, 14, 0)
        let lead = GameEngine.lapseWarningLead

        XCTAssertEqual(GameEngine.lapseWarningLead, 120, "two minutes — the shipped threshold")

        // A whole window earlier, and a second before the lead: nothing.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-3600)),
                       .none)
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-lead - 1)),
                       .none)
        // Exactly at the lead time it starts speaking.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-lead)),
                       .closingSoon)
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-30)),
                       .closingSoon)

        // The lead is a parameter, and a caller that passes its own is obeyed.
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-90),
                                              lead: 60),
                       .none)
        XCTAssertEqual(GameEngine.lapseNotice(windowEnd: end, now: end.addingTimeInterval(-60),
                                              lead: 60),
                       .closingSoon)
    }

    /// THE SILENCE, and what breaks it. The confirm screen sat open past the
    /// end of the window, so the log `AppState.log` appended is a qada — 5 XP
    /// where the screen was promising 30, and no photo. The flow started while
    /// the window was open, so that is a lapse and it gets explained.
    func testAQadaOutOfAnInWindowFlowIsALapse() {
        let landed = [log(.dhuhr, .qada, dayKey: "2026-08-22")]
        XCTAssertTrue(GameEngine.lapsedIntoQada(added: landed, startedInWindow: true))
    }

    /// A deliberate make-up is a choice, not an accident. Same log, same tier —
    /// only the intent differs, and it is the intent that decides.
    func testADeliberateMakeUpIsNeverApologisedFor() {
        let landed = [log(.dhuhr, .qada, dayKey: "2026-08-22")]
        XCTAssertFalse(GameEngine.lapsedIntoQada(added: landed, startedInWindow: false),
                       "the flow set out to record a make-up — nothing went wrong")
    }

    /// The success path, which must stay exactly as silent as it is today: a
    /// log that landed in-window has nothing to explain, at any tier — including
    /// `closeCall`, which is the tier of someone who only just made it and is
    /// precisely who a false notice would insult.
    func testAnInWindowLandingSaysNothing() {
        for tier in [LogTier.onTime, .prayed, .lastCall, .closeCall] {
            XCTAssertFalse(GameEngine.lapsedIntoQada(added: [log(.asr, tier, dayKey: "2026-08-22")],
                                                     startedInWindow: true),
                           "\(tier) is in the window — the post did what it promised")
        }
    }

    /// A REFUSAL is the other silence and not this one. `log` reports "no" by
    /// appending nothing (no target window, already logged, window not open
    /// yet), and an empty `added` must not be mistaken for a lapse — there is
    /// no make-up to apologise for because there is no log at all.
    func testARefusalIsNotALapse() {
        XCTAssertFalse(GameEngine.lapsedIntoQada(added: [], startedInWindow: true))
        XCTAssertFalse(GameEngine.lapsedIntoQada(added: [], startedInWindow: false))
    }

    /// v3.3 travel: one tap, two logs, and the window that lapsed was the
    /// PAIR's. Both sides land as make-ups, so the notice is owed once and the
    /// XP it names is the pair's 10 — not 5.
    func testATravelPairLapsesTogether() {
        let key = "2026-08-22"
        let added = [log(.dhuhr, .qada, dayKey: key), log(.asr, .qada, dayKey: key)]

        XCTAssertTrue(GameEngine.lapsedIntoQada(added: added, startedInWindow: true))
        XCTAssertEqual(added.reduce(0) { $0 + $1.xp }, 2 * LogTier.qada.xp,
                       "what the notice tells them they earned")
    }

    // MARK: - What a square draws

    /// The Today grid and `status(of:)` must never contradict each other. On
    /// the day you are standing in, the square IS the identity lookup.
    ///
    /// The §7.2 re-lived day: fajr prayed in Mumbai, an 18-hour flight, and
    /// Seattle's fajr window has already closed on the same dayKey. Seattle's
    /// fajr really was not prayed — so the square says missed (nil log), the
    /// "Make up" row is offered, and the inline button beside the square is no
    /// longer hidden by a cell that disagreed with it.
    func testALiveDaysSquareAnswersTheSameQuestionStatusDoes() {
        let key = "2026-08-22"
        let logs = [log(.fajr, .onTime, dayKey: key, offset: mumbai)]

        XCTAssertNil(GameEngine.cellLog(prayer: .fajr, dayKey: key, isLiveDay: true,
                                        currentOffset: seattle, in: logs),
                     "Seattle's fajr was not prayed, and the square must not claim it was")
        XCTAssertEqual(GameEngine.cellLog(prayer: .fajr, dayKey: key, isLiveDay: true,
                                          currentOffset: seattle, in: logs)?.id,
                       GameEngine.loggedInstance(prayer: .fajr, dayKey: key,
                                                 currentOffset: seattle, in: logs)?.id,
                       "the square and the status are one function on a live day")

        // Still in Mumbai, it is drawn — nothing changes for staying put.
        XCTAssertEqual(GameEngine.cellLog(prayer: .fajr, dayKey: key, isLiveDay: true,
                                          currentOffset: mumbai, in: logs)?.id, logs[0].id)
    }

    /// ...and the foregone-XP line agrees with the square beside it. Reporting
    /// zero for a window nobody prayed is what made the two contradict.
    func testMissedOutXPChargesAWindowTheTravellerDidNotPray() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let noon = date(2026, 8, 22, 12, 0)
        let schedule = try XCTUnwrap(PrayerTimeService.schedule(for: noon, latitude: 47.6062,
                                                                longitude: -122.3321,
                                                                method: .northAmerica,
                                                                madhab: .shafi,
                                                                calendar: calendar))
        let fajrEnd = try XCTUnwrap(schedule.window(for: .fajr)).end
        let justAfterFajr = fajrEnd.addingTimeInterval(60)
        let mumbaiFajr = [PrayerLog(id: UUID(), prayer: .fajr, dayKey: schedule.dayKey,
                                    loggedAt: fajrEnd.addingTimeInterval(-20 * 3600),
                                    tier: .onTime, xp: LogTier.onTime.xp, utcOffset: mumbai)]

        XCTAssertEqual(GameEngine.missedOutXP(logs: mumbaiFajr, schedule: schedule,
                                              now: justAfterFajr, isExcused: false,
                                              currentOffset: seattle),
                       LogTier.onTime.xp,
                       "Seattle's fajr window passed unprayed — that XP really was foregone")

        // The same log, asked from Mumbai, forgoes nothing.
        XCTAssertEqual(GameEngine.missedOutXP(logs: mumbaiFajr, schedule: schedule,
                                              now: justAfterFajr, isExcused: false,
                                              currentOffset: mumbai), 0)
    }

    /// A PAST day is grouping, and it has to be: the zone the device is in
    /// today says nothing about the zone Monday was lived in. Asking by
    /// identity there would repaint a whole travelled week as missed.
    func testAPastDaysSquareIsNotJudgedByTodaysZone() {
        let monday = "2026-08-17"
        let logs: [PrayerLog] = Prayer.allCases.map {
            log($0, .onTime, dayKey: monday, offset: mumbai)
        }
        for prayer in Prayer.allCases {
            XCTAssertNotNil(GameEngine.cellLog(prayer: prayer, dayKey: monday, isLiveDay: false,
                                               currentOffset: seattle, in: logs),
                            "flying home must not erase the week you prayed abroad")
        }
    }

    /// A past day that holds two logs for one prayer picks one DETERMINISTICALLY
    /// — the latest prayer — so a cell never flips because the array reordered.
    func testAPastDaysSquarePicksTheLatestPrayerWhicheverOrderItArrivesIn() {
        let key = "2026-08-22"
        let early = PrayerLog(id: UUID(), prayer: .maghrib, dayKey: key,
                              loggedAt: date(2026, 8, 22, 20, 0), tier: .onTime,
                              xp: LogTier.onTime.xp, utcOffset: 3600)
        let late = PrayerLog(id: UUID(), prayer: .maghrib, dayKey: key,
                             loggedAt: date(2026, 8, 23, 1, 45), tier: .lastCall,
                             xp: LogTier.lastCall.xp, utcOffset: -4 * 3600)
        for order in [[early, late], [late, early]] {
            XCTAssertEqual(GameEngine.cellLog(prayer: .maghrib, dayKey: key, isLiveDay: false,
                                              currentOffset: seattle, in: order)?.id,
                           late.id)
            XCTAssertEqual(GameEngine.latestLog(prayer: .maghrib, dayKey: key, in: order)?.id,
                           late.id)
        }
    }

    /// The week's arithmetic is grouping too, and a travel day must not be
    /// double-counted as two days or collapsed into fewer prayers.
    func testWeeklyXPCountsATravelDayOnce() {
        let monday = date(2026, 8, 17)
        let key = AppClock.dayKey(for: monday)
        var logs: [PrayerLog] = Prayer.allCases.map { log($0, .onTime, dayKey: key, offset: mumbai) }
        let single: Int = GameEngine.weeklyXP(logs: logs, weekStart: monday)

        logs.append(log(.fajr, .onTime, dayKey: key, offset: seattle))
        XCTAssertEqual(GameEngine.weeklyXP(logs: logs, weekStart: monday),
                       single + LogTier.onTime.xp,
                       "one extra prayer is one extra prayer's XP — not an extra day")
    }

    // MARK: - Undo picks the day you are on, not the nearest zone

    func testUndoPrefersTheLiveDayOverACloserZone() {
        // Today's isha logged in Mumbai (+5:30); yesterday's isha logged in
        // Seattle (-7). The device is now back in Seattle, so YESTERDAY's log
        // is the zone-nearest match — but undo must still take today's.
        let mumbai = 5 * 3600 + 1800
        let seattle = -7 * 3600
        let logs = [
            PrayerLog(id: UUID(), prayer: .isha, dayKey: "2026-08-21",
                      loggedAt: Date(timeIntervalSince1970: 0), tier: .onTime, xp: 30,
                      utcOffset: seattle),
            PrayerLog(id: UUID(), prayer: .isha, dayKey: "2026-08-22",
                      loggedAt: Date(timeIntervalSince1970: 1), tier: .onTime, xp: 30,
                      utcOffset: mumbai),
        ]
        // Today's Mumbai isha does not survive the identity guard from Seattle,
        // so it is not a candidate. The point is what happens NEXT: without the
        // preference, yesterday's Seattle isha wins by default and Undo deletes
        // a day that was already banked, taking its XP and possibly a streak
        // increment. Nothing to undo is the correct answer.
        let index = GameEngine.loggedInstanceIndex(
            prayer: .isha, dayKeys: ["2026-08-21", "2026-08-22"],
            currentOffset: seattle, preferredDayKey: "2026-08-22", in: logs)
        XCTAssertNil(index, "undo must never reach past today into a banked day")

        // Same inputs without the preference: this is the bug, preserved so the
        // test says what it is protecting against.
        XCTAssertEqual(GameEngine.loggedInstanceIndex(
            prayer: .isha, dayKeys: ["2026-08-21", "2026-08-22"],
            currentOffset: seattle, in: logs), 0)
    }

    func testUndoStillFallsBackWhenThePreferredDayHasNoMatch() {
        // Pre-fajr: the live isha carries YESTERDAY's dayKey, so the preferred
        // key (today) matches nothing and the resolver must not come back nil.
        let seattle = -7 * 3600
        let logs = [
            PrayerLog(id: UUID(), prayer: .isha, dayKey: "2026-08-21",
                      loggedAt: Date(timeIntervalSince1970: 0), tier: .onTime, xp: 30,
                      utcOffset: seattle),
        ]
        let index = GameEngine.loggedInstanceIndex(
            prayer: .isha, dayKeys: ["2026-08-21", "2026-08-22"],
            currentOffset: seattle, preferredDayKey: "2026-08-22", in: logs)
        XCTAssertEqual(index, 0, "a preference is a ranking, not a filter")
    }

    func testOmittingThePreferenceKeepsTheOldRanking() {
        let seattle = -7 * 3600
        let logs = [
            PrayerLog(id: UUID(), prayer: .fajr, dayKey: "2026-08-22",
                      loggedAt: Date(timeIntervalSince1970: 0), tier: .onTime, xp: 30,
                      utcOffset: seattle),
        ]
        XCTAssertEqual(GameEngine.loggedInstanceIndex(prayer: .fajr, dayKeys: ["2026-08-22"],
                                                      currentOffset: seattle, in: logs), 0)
    }

    // MARK: - A week-grid cell is a DAY question, for everyone

    func testTheWeekGridReadsATravelDayTheSameWayForEveryone() {
        // Two fajrs on one date: Mumbai then Seattle. A buddy's row resolves
        // through CircleSnapshot.post, which keys on dayKey alone, so YOUR row
        // must reach the same verdict — latestLog, not the identity lookup.
        // With identity, standing in Seattle after logging only Mumbai's fajr
        // rendered your own cell `.missed` while weeklyXP counted its 30 XP.
        let mumbai = 5 * 3600 + 1800
        let seattle = -7 * 3600
        let logs = [
            PrayerLog(id: UUID(), prayer: .fajr, dayKey: "2026-08-22",
                      loggedAt: Date(timeIntervalSince1970: 0), tier: .onTime, xp: 30,
                      utcOffset: mumbai),
        ]
        XCTAssertNotNil(GameEngine.latestLog(prayer: .fajr, dayKey: "2026-08-22", in: logs),
                        "the day holds a fajr, whatever zone it was prayed in")
        // The identity lookup deliberately DISagrees — that is its job on the
        // Today screen, where the question is "can I log this one now".
        XCTAssertNil(GameEngine.loggedInstance(prayer: .fajr, dayKey: "2026-08-22",
                                               currentOffset: seattle, in: logs),
                     "Seattle's fajr is a different prayer and is still unlogged")
    }
}
