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

    private func log(_ prayer: Prayer, _ tier: LogTier, dayKey: String) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                  loggedAt: Date(timeIntervalSince1970: 0), tier: tier, xp: tier.xp)
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
        XCTAssertEqual(LogTier.qada.xp, 10)
        // In-window must always beat making up later.
        XCTAssertGreaterThan(LogTier.closeCall.xp, LogTier.qada.xp)
    }

    func testJummaBonus() {
        // 2026-06-12 is a Friday.
        let friday = date(2026, 6, 12, 13, 0)
        let thursday = date(2026, 6, 11, 13, 0)
        XCTAssertTrue(GameEngine.isJumma(prayer: .dhuhr, date: friday))
        XCTAssertFalse(GameEngine.isJumma(prayer: .asr, date: friday))
        XCTAssertFalse(GameEngine.isJumma(prayer: .dhuhr, date: thursday))
        XCTAssertEqual(GameEngine.congregationBonus(prayer: .dhuhr, date: friday), GameEngine.jummaBonus)
        XCTAssertEqual(GameEngine.congregationBonus(prayer: .dhuhr, date: thursday), GameEngine.jamaatBonus)
        XCTAssertEqual(GameEngine.congregationBonus(prayer: .isha, date: friday), GameEngine.jamaatBonus)
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
        XCTAssertEqual(GameEngine.xp(forDay: dayKey, logs: imperfect), 10 + 4 * 30)
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
}
