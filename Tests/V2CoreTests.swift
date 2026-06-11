import XCTest
@testable import SalahBuddy

/// v2 core tests: qada/jamaat accounting, excused days, BuddySimulator
/// determinism + visibility, ChallengeEngine logic, v1-JSON migration.
final class V2CoreTests: XCTestCase {

    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    private func log(_ prayer: Prayer, _ tier: LogTier, dayKey: String,
                     loggedAt: Date = Date(timeIntervalSince1970: 0),
                     xp: Int? = nil, jamaat: Bool = false) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                  loggedAt: loggedAt, tier: tier, xp: xp ?? tier.xp, jamaat: jamaat)
    }

    private func fullDay(dayKey: String, tier: LogTier = .onTime) -> [PrayerLog] {
        Prayer.allCases.map { log($0, tier, dayKey: dayKey) }
    }

    /// Synthetic schedule: 5 90-minute windows through the day.
    private func schedule(dayKey: String, dayStart: Date) -> DaySchedule {
        let hours: [Double] = [5.5, 13.0, 16.5, 19.5, 21.0]
        let windows = zip(Prayer.allCases, hours).map { prayer, hour in
            PrayerWindow(prayer: prayer,
                         start: dayStart.addingTimeInterval(hour * 3600),
                         end: dayStart.addingTimeInterval(hour * 3600 + 90 * 60))
        }
        return DaySchedule(dayKey: dayKey, dayStart: dayStart, windows: windows)
    }

    // MARK: - v2 XP rules

    func testQadaXPIsTen() {
        XCTAssertEqual(LogTier.qada.xp, 10)
    }

    func testJamaatBonusAccounting() {
        XCTAssertEqual(GameEngine.jamaatBonus, 5)
        // A jamaat onTime log carries 35 XP; day XP sums stored values.
        let dayKey = "2026-06-10"
        var logs = fullDay(dayKey: dayKey, tier: .onTime)
        logs[0] = log(.fajr, .onTime, dayKey: dayKey,
                      xp: LogTier.onTime.xp + GameEngine.jamaatBonus, jamaat: true)
        XCTAssertEqual(GameEngine.xp(forDay: dayKey, logs: logs), 5 * 30 + 5 + 25)
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey),
                      "jamaat doesn't affect perfect-day detection")
    }

    // MARK: - Excused days

    func testExcusedDayPreservesStreakAndFreezes() {
        var profile = UserProfile.fresh(now: Date(timeIntervalSince1970: 0))
        for day in 1...7 {
            profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-\(day)")
        }
        XCTAssertEqual(profile.streak, 7)
        XCTAssertEqual(profile.streakFreezes, 1)

        // Excused incomplete day → skipped: streak intact, NO freeze consumed.
        profile = GameEngine.reconcile(profile: profile,
                                       elapsedDays: [("day-8", false)],
                                       excusedDayKeys: ["day-8"])
        XCTAssertEqual(profile.streak, 7)
        XCTAssertEqual(profile.streakFreezes, 1)
        XCTAssertEqual(profile.lastReconciledDayKey, "day-8")

        // Streak survives an excused gap and keeps growing afterwards.
        profile = GameEngine.applyStreakIncrement(to: profile, dayKey: "day-9")
        XCTAssertEqual(profile.streak, 8)

        // A non-excused incomplete day still behaves as before.
        profile = GameEngine.reconcile(profile: profile,
                                       elapsedDays: [("day-10", false)],
                                       excusedDayKeys: ["day-8"])
        XCTAssertEqual(profile.streakFreezes, 0, "non-excused miss consumes the freeze")
        XCTAssertEqual(profile.streak, 8)
    }

    func testExcusedMonthlyCapCounting() {
        var excused: Set<String> = []
        for day in 1...10 { excused.insert(String(format: "2026-06-%02d", day)) }
        excused.insert("2026-05-30")   // previous month — must not count

        XCTAssertEqual(GameEngine.excusedCount(in: excused, monthOf: "2026-06-15"), 10)
        XCTAssertEqual(GameEngine.excusedCount(in: excused, monthOf: "2026-05-15"), 1)
        XCTAssertFalse(GameEngine.canExcuse(dayKey: "2026-06-15", excusedDayKeys: excused),
                       "cap reached in June")
        // Calendar-month rollover: July starts fresh.
        XCTAssertEqual(GameEngine.excusedCount(in: excused, monthOf: "2026-07-01"), 0)
        XCTAssertTrue(GameEngine.canExcuse(dayKey: "2026-07-01", excusedDayKeys: excused))
        XCTAssertEqual(GameEngine.maxExcusedPerMonth, 10)
    }

    func testExcusedDayCannotBePerfect() {
        let dayKey = "2026-06-10"
        let logs = fullDay(dayKey: dayKey, tier: .onTime)
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey))
        XCTAssertFalse(GameEngine.isPerfectDay(logs: logs, dayKey: dayKey,
                                               excusedDayKeys: [dayKey]))
        // No perfect bonus on an excused day; logs keep their XP.
        XCTAssertEqual(GameEngine.xp(forDay: dayKey, logs: logs, excusedDayKeys: [dayKey]), 150)
    }

    func testMissedOutXP() {
        let dayStart = cal.startOfDay(for: date(2026, 6, 10))
        let dayKey = AppClock.dayKey(for: dayStart)
        let sched = schedule(dayKey: dayKey, dayStart: dayStart)
        let evening = dayStart.addingTimeInterval(18 * 3600)   // fajr/dhuhr/asr windows passed

        // Nothing logged: 3 fully-passed windows × 30 foregone.
        XCTAssertEqual(GameEngine.missedOutXP(logs: [], schedule: sched, now: evening,
                                              isExcused: false), 90)
        // Qada recovers 10 of one window's 30.
        let qadaLog = [log(.fajr, .qada, dayKey: dayKey)]
        XCTAssertEqual(GameEngine.missedOutXP(logs: qadaLog, schedule: sched, now: evening,
                                              isExcused: false), 80)
        // An in-window log forgoes nothing, even at lastCall.
        let lastCall = [log(.fajr, .lastCall, dayKey: dayKey),
                        log(.dhuhr, .onTime, dayKey: dayKey),
                        log(.asr, .onTime, dayKey: dayKey)]
        XCTAssertEqual(GameEngine.missedOutXP(logs: lastCall, schedule: sched, now: evening,
                                              isExcused: false), 0)
        // Excused day forgoes nothing.
        XCTAssertEqual(GameEngine.missedOutXP(logs: [], schedule: sched, now: evening,
                                              isExcused: true), 0)
    }

    // MARK: - BuddySimulator

    func testBuddyOutcomeDeterminism() {
        let dayStart = cal.startOfDay(for: date(2026, 6, 10))
        let dayKey = AppClock.dayKey(for: dayStart)
        let sched = schedule(dayKey: dayKey, dayStart: dayStart)

        for buddy in BuddySimulator.buddies {
            for window in sched.windows {
                let a = BuddySimulator.outcome(for: buddy, dayKey: dayKey, window: window)
                let b = BuddySimulator.outcome(for: buddy, dayKey: dayKey, window: window)
                XCTAssertEqual(a, b, "\(buddy.name)/\(window.prayer): same inputs → same outcome")
            }
        }
        // Seeds differ across buddies, days, and prayers.
        XCTAssertNotEqual(BuddySimulator.seed(name: "Mina", dayKey: dayKey, prayer: .fajr),
                          BuddySimulator.seed(name: "Harun", dayKey: dayKey, prayer: .fajr))
        XCTAssertNotEqual(BuddySimulator.seed(name: "Mina", dayKey: "2026-06-10", prayer: .fajr),
                          BuddySimulator.seed(name: "Mina", dayKey: "2026-06-11", prayer: .fajr))
        XCTAssertNotEqual(BuddySimulator.seed(name: "Mina", dayKey: dayKey, prayer: .fajr),
                          BuddySimulator.seed(name: "Mina", dayKey: dayKey, prayer: .isha))
    }

    func testBuddyRoster() {
        XCTAssertEqual(BuddySimulator.buddies.map(\.name), ["Mina", "Harun", "Haifa"])
        XCTAssertEqual(BuddySimulator.buddies.map(\.consistency), [0.92, 0.75, 0.85])
        XCTAssertEqual(BuddySimulator.buddies.map(\.emoji), ["🌸", "🧢", "📚"])
    }

    func testBuddyPostsHiddenBeforeLoggedAtVisibleAfter() {
        let dayStart = cal.startOfDay(for: date(2026, 6, 10))
        let dayKey = AppClock.dayKey(for: dayStart)
        let sched = schedule(dayKey: dayKey, dayStart: dayStart)
        let days = [(dayKey: dayKey, schedule: sched)]

        for buddy in BuddySimulator.buddies {
            // Find a posted outcome to probe around.
            for window in sched.windows {
                guard let postLog = BuddySimulator.log(for: buddy, dayKey: dayKey, window: window)
                else { continue }
                let before = BuddySimulator.visibleLogs(for: buddy, days: days,
                                                        asOf: postLog.loggedAt.addingTimeInterval(-1))
                let after = BuddySimulator.visibleLogs(for: buddy, days: days,
                                                       asOf: postLog.loggedAt)
                XCTAssertFalse(before.contains { $0.prayer == window.prayer },
                               "\(buddy.name)/\(window.prayer): hidden before loggedAt")
                XCTAssertTrue(after.contains { $0.prayer == window.prayer },
                              "\(buddy.name)/\(window.prayer): visible at/after loggedAt")
            }
        }
    }

    func testBuddyWeeklyScoreEqualsSumOfVisibleOutcomes() {
        let monday = BuddySimulator.weekStart(for: date(2026, 6, 10, 12, 0))
        var days: [(dayKey: String, schedule: DaySchedule)] = []
        for offset in 0..<7 {
            let dayStart = cal.date(byAdding: .day, value: offset, to: monday)!
            let key = AppClock.dayKey(for: dayStart)
            days.append((key, schedule(dayKey: key, dayStart: dayStart)))
        }
        let asOf = monday.addingTimeInterval(3.5 * 86400)   // mid-week

        for buddy in BuddySimulator.buddies {
            let visible = BuddySimulator.visibleLogs(for: buddy, days: days, asOf: asOf)
            let expected = Set(visible.map(\.dayKey))
                .reduce(0) { $0 + GameEngine.xp(forDay: $1, logs: visible) }
            XCTAssertEqual(BuddySimulator.weeklyXP(for: buddy, days: days, asOf: asOf), expected,
                           "\(buddy.name): scoreboard must equal grid outcomes")
            // Monotonic over time.
            let later = BuddySimulator.weeklyXP(for: buddy, days: days, asOf: asOf.addingTimeInterval(86400))
            XCTAssertGreaterThanOrEqual(later, expected)
        }
    }

    // MARK: - ChallengeEngine

    private func member(_ id: String, isYou: Bool = false) -> CircleMember {
        CircleMember(id: id, name: id, emoji: "🙂", isYou: isYou)
    }

    private func context(myLogs: [PrayerLog] = [],
                         memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = [],
                         todayKey: String = "d07",
                         recentDayKeys: [String]? = nil,
                         weekDayKeys: [String] = ["d01", "d02", "d03", "d04", "d05", "d06", "d07"],
                         weekKey: String = "2026-W24",
                         hardestPrayer: Prayer? = nil,
                         completions: [String: Date] = [:]) -> ChallengeEngine.Context {
        let recent = recentDayKeys ?? (1...7).map { String(format: "d%02d", $0) }
        return ChallengeEngine.Context(myLogs: myLogs, memberWeekLogs: memberWeekLogs,
                                       todayKey: todayKey, recentDayKeys: recent,
                                       weekDayKeys: weekDayKeys, weekKey: weekKey,
                                       hardestPrayer: hardestPrayer, completions: completions)
    }

    func testFajr3ConsecutiveLogicWithGapReset() {
        let def = ChallengeEngine.definition(id: "fajr3")!

        // d05, d06, d07 (today) all have in-window fajr → run of 3.
        var logs = ["d05", "d06", "d07"].map { log(.fajr, .onTime, dayKey: $0) }
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: context(myLogs: logs)), 3)

        // Gap at d06 resets: only today counts.
        logs = ["d05", "d07"].map { log(.fajr, .onTime, dayKey: $0) }
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: context(myLogs: logs)), 1)

        // Qada fajr doesn't count as in-window.
        logs = [log(.fajr, .qada, dayKey: "d06"), log(.fajr, .onTime, dayKey: "d07")]
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: context(myLogs: logs)), 1)

        // Today pending → run ending yesterday still alive.
        logs = ["d05", "d06"].map { log(.fajr, .onTime, dayKey: $0) }
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: context(myLogs: logs)), 2)
    }

    func testFullDayAwardedWhenFifthPrayerIsAfterMidnightIsha() {
        let def = ChallengeEngine.definition(id: "fullday")!
        // All 5 in-window on d07; isha was posted after midnight, so todayKey
        // has already rolled to d08 while the log still carries d07 (§6.6).
        let fullYesterday = Prayer.allCases.map { log($0, .onTime, dayKey: "d07") }
        let ctx = context(myLogs: fullYesterday, todayKey: "d08",
                          recentDayKeys: (1...8).map { String(format: "d%02d", $0) })
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: ctx), 5,
                       "yesterday's completed full day must be visible at log time")
        XCTAssertTrue(ChallengeEngine.newlyCompleted(ctx).map(\.key).contains("fullday"))
    }

    func testGoal3OnlyWhenHardestPrayerSet() {
        let logs = ["d05", "d06", "d07"].map { log(.asr, .onTime, dayKey: $0) }
        let without = ChallengeEngine.progressList(context(myLogs: logs))
        XCTAssertFalse(without.contains { $0.id == "goal3" }, "hidden when hardestPrayer unset")

        let with = ChallengeEngine.progressList(context(myLogs: logs, hardestPrayer: .asr))
        let goal = with.first { $0.id == "goal3" }
        XCTAssertEqual(goal?.current, 3)
    }

    func testIsha3RequiresAllMembers() {
        let def = ChallengeEngine.definition(id: "isha3")!
        let a = member("a"), b = member("b"), you = member("you", isYou: true)

        func ishaLogs(_ days: [String]) -> [PrayerLog] {
            days.map { log(.isha, .prayed, dayKey: $0) }
        }

        // All three logged isha d05–d07 → run of 3.
        var ctx = context(memberWeekLogs: [(a, ishaLogs(["d05", "d06", "d07"])),
                                           (b, ishaLogs(["d05", "d06", "d07"])),
                                           (you, ishaLogs(["d05", "d06", "d07"]))])
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: ctx), 3)
        XCTAssertTrue(ChallengeEngine.isCompletedNow(def, ctx: ctx))

        // One member missing d06 breaks the run for EVERYONE.
        ctx = context(memberWeekLogs: [(a, ishaLogs(["d05", "d06", "d07"])),
                                       (b, ishaLogs(["d05", "d07"])),
                                       (you, ishaLogs(["d05", "d06", "d07"]))])
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: ctx), 1)
        XCTAssertFalse(ChallengeEngine.isCompletedNow(def, ctx: ctx))
    }

    func testRace300WinnerIdentification() {
        let t0 = date(2026, 6, 8, 6, 0)
        func burst(_ member: CircleMember, count: Int, startingAt: Date) -> (CircleMember, [PrayerLog]) {
            // count onTime logs (30 XP each), one per hour.
            let logs = (0..<count).map { i in
                log(.dhuhr, .onTime, dayKey: "d0\(1 + i / 5)",
                    loggedAt: startingAt.addingTimeInterval(Double(i) * 3600))
            }
            return (member, logs)
        }
        let a = member("a"), you = member("you", isYou: true)

        // A crosses 300 (10 × 30) before you do.
        let early = burst(a, count: 10, startingAt: t0)
        let late = burst(you, count: 10, startingAt: t0.addingTimeInterval(7200))
        XCTAssertEqual(ChallengeEngine.raceWinnerID(memberWeekLogs: [early, late]), "a")

        let def = ChallengeEngine.definition(id: "race300")!
        let lostCtx = context(memberWeekLogs: [early, late])
        XCTAssertFalse(ChallengeEngine.isCompletedNow(def, ctx: lostCtx),
                       "reaching 300 second doesn't win")

        // You first → you win.
        let youFirst = burst(you, count: 10, startingAt: t0)
        let aSecond = burst(a, count: 10, startingAt: t0.addingTimeInterval(7200))
        let wonCtx = context(memberWeekLogs: [aSecond, youFirst])
        XCTAssertEqual(ChallengeEngine.raceWinnerID(memberWeekLogs: [aSecond, youFirst]), "you")
        XCTAssertTrue(ChallengeEngine.isCompletedNow(def, ctx: wonCtx))

        // Nobody crossed → no winner.
        XCTAssertNil(ChallengeEngine.raceWinnerID(memberWeekLogs: [burst(a, count: 2, startingAt: t0)]))
    }

    func testCompletionAwardedOnceAndWeeklyRekeying() {
        let fullToday = Prayer.allCases.map { log($0, .onTime, dayKey: "d07") }
        let ctx = context(myLogs: fullToday)

        // fullday newly completed.
        var newly = ChallengeEngine.newlyCompleted(ctx).map(\.key)
        XCTAssertTrue(newly.contains("fullday"))

        // Once recorded, never re-awarded (personal = keyed by bare id).
        let done = context(myLogs: fullToday, completions: ["fullday": Date()])
        newly = ChallengeEngine.newlyCompleted(done).map(\.key)
        XCTAssertFalse(newly.contains("fullday"))

        // Group weeklies key by id|weekKey → completing last week re-arms this week.
        let a = member("a"), b = member("b"), you = member("you", isYou: true)
        let isha = ["d05", "d06", "d07"].map { log(.isha, .prayed, dayKey: $0) }
        let groupCtx = context(memberWeekLogs: [(a, isha), (b, isha), (you, isha)],
                               weekKey: "2026-W24",
                               completions: ["isha3|2026-W23": Date()])
        let keys = ChallengeEngine.newlyCompleted(groupCtx).map(\.key)
        XCTAssertTrue(keys.contains("isha3|2026-W24"), "last week's completion doesn't block this week")

        let blocked = context(memberWeekLogs: [(a, isha), (b, isha), (you, isha)],
                              weekKey: "2026-W24",
                              completions: ["isha3|2026-W24": Date()])
        XCTAssertFalse(ChallengeEngine.newlyCompleted(blocked).map(\.key).contains("isha3|2026-W24"))
    }

    func testAllEightDefinitionsExist() {
        XCTAssertEqual(ChallengeEngine.definitions.map(\.id),
                       ["fullday", "fajr3", "week7", "jamaat3", "goal3",
                        "isha3", "race300", "circleperfect"])
        XCTAssertEqual(ChallengeEngine.definitions.filter(\.isGroup).map(\.id),
                       ["isha3", "race300", "circleperfect"])
        let rewards = Dictionary(uniqueKeysWithValues: ChallengeEngine.definitions.map { ($0.id, $0.rewardXP) })
        XCTAssertEqual(rewards["fullday"], 20)
        XCTAssertEqual(rewards["fajr3"], 30)
        XCTAssertEqual(rewards["week7"], 100)
        XCTAssertEqual(rewards["jamaat3"], 30)
        XCTAssertEqual(rewards["goal3"], 40)
        XCTAssertEqual(rewards["isha3"], 50)
        XCTAssertEqual(rewards["race300"], 30)
        XCTAssertEqual(rewards["circleperfect"], 50)
    }

    // MARK: - v1 → v2 migration

    func testV1PrayerLogJSONStillDecodes() throws {
        // v1-shaped log: no photoFilename, no jamaat. Old qada keeps xp 5.
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "prayer":"isha","dayKey":"2026-05-30",
          "loggedAt":"2026-05-31T06:45:00Z","tier":"qada","xp":5}]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let logs = try decoder.decode([PrayerLog].self, from: json)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].tier, .qada)
        XCTAssertEqual(logs[0].xp, 5, "old persisted qada logs keep their stored xp")
        XCTAssertNil(logs[0].photoFilename)
        XCTAssertFalse(logs[0].jamaat)
        XCTAssertNil(logs[0].placeTag, "v3 place fields default nil for old logs")
        XCTAssertNil(logs[0].placeName)
    }

    func testV2LogWithoutPlaceFieldsStillDecodes() throws {
        // v2-shaped log: photo + jamaat present, no placeTag/placeName.
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "prayer":"fajr","dayKey":"2026-06-09",
          "loggedAt":"2026-06-09T11:20:00Z","tier":"onTime","xp":35,
          "photoFilename":"2026-06-09-fajr.jpg","jamaat":true}]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let logs = try decoder.decode([PrayerLog].self, from: json)
        XCTAssertEqual(logs[0].photoFilename, "2026-06-09-fajr.jpg")
        XCTAssertTrue(logs[0].jamaat)
        XCTAssertNil(logs[0].placeTag)
    }

    func testBuddyPlaceTagIsDeterministicAndDistributed() {
        XCTAssertEqual(BuddySimulator.placeTag(seed: 7), BuddySimulator.placeTag(seed: 7))
        // All four tags reachable across seeds.
        let tags = Set((0..<200).compactMap { BuddySimulator.placeTag(seed: UInt64($0)) })
        XCTAssertEqual(tags, Set(PlaceTag.allCases))
    }

    func testV1ProfileJSONStillDecodes() throws {
        let json = """
        {"name":"Haashim","totalXP":1234,"streak":4,"longestStreak":9,
         "streakFreezes":1,"lastStreakDayKey":"2026-05-30",
         "lastReconciledDayKey":"2026-05-30",
         "earnedBadges":{"streak3":"2026-05-20T12:00:00Z"},
         "perfectDayCount":2,"joinedAt":"2026-05-01T12:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(UserProfile.self, from: json)
        XCTAssertEqual(profile.totalXP, 1234)
        XCTAssertEqual(profile.streak, 4)
        XCTAssertTrue(profile.excusedDayKeys.isEmpty)
        XCTAssertTrue(profile.challengeCompletions.isEmpty)
    }

    func testV1SettingsJSONStillDecodes() throws {
        let json = """
        {"calcMethod":"northAmerica","madhab":"shafi","useDeviceLocation":true,
         "fixedLatitude":47.6062,"fixedLongitude":-122.3321,"locationName":"Seattle",
         "notificationsEnabled":true,"dailyGoal":100,"hasOnboarded":true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.hasOnboarded)
        XCTAssertNil(settings.hardestPrayer)
    }

    func testV2RoundTripPersistsNewFields() throws {
        let original = PrayerLog(id: UUID(), prayer: .fajr, dayKey: "2026-06-10",
                                 loggedAt: date(2026, 6, 10, 5, 45), tier: .onTime,
                                 xp: 35, photoFilename: "2026-06-10_fajr_abc.jpg", jamaat: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PrayerLog.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }
}
