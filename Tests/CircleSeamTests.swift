import XCTest
@testable import SalahBuddy

/// v4 Phase B2: the `CircleDataSource` seam.
///
/// These are PARITY tests — the whole point of the refactor is that moving the
/// circle logic out of `AppState` changed nothing. Every answer
/// `SimulatedCircleDataSource` gives is checked against `BuddySimulator`
/// directly, across all three outcomes (posted / qada / missed) and around the
/// "not visible yet" reveal. Plus the two new v4 guards: `circleMode` defaults
/// to `.demo`, and a real circle pins the developer clock.
final class CircleSeamTests: XCTestCase {

    private let cal = Calendar.current

    /// The demo roster the seam is exercised over. On 2026-06-10 these eight
    /// derive 29 posted, 5 qada and 6 missed outcomes — every branch covered,
    /// deterministically (the counters below assert it stays that way).
    private let roster: [BuddySimulator.Buddy] = BuddySimulator.buddies

    private var source: SimulatedCircleDataSource {
        SimulatedCircleDataSource(buddies: roster)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    /// Synthetic schedule: 5 90-minute windows through the day — the same
    /// shape V2CoreTests uses, so both files agree on what a day looks like.
    private func schedule(dayKey: String, dayStart: Date) -> DaySchedule {
        let hours: [Double] = [5.5, 13.0, 16.5, 19.5, 21.0]
        let windows = zip(Prayer.allCases, hours).map { prayer, hour in
            PrayerWindow(prayer: prayer,
                         start: dayStart.addingTimeInterval(hour * 3600),
                         end: dayStart.addingTimeInterval(hour * 3600 + 90 * 60))
        }
        return DaySchedule(dayKey: dayKey, dayStart: dayStart, windows: windows)
    }

    /// The fixed probe day.
    private func fixedDay() -> (dayKey: String, schedule: DaySchedule) {
        let dayStart = cal.startOfDay(for: date(2026, 6, 10))
        let key = AppClock.dayKey(for: dayStart)
        return (key, schedule(dayKey: key, dayStart: dayStart))
    }

    /// The Mon-start week of 2026-06-08 as (dayKey, schedule) pairs.
    private func weekDays() -> [(dayKey: String, schedule: DaySchedule)] {
        let monday = cal.startOfDay(for: date(2026, 6, 8))
        var days: [(dayKey: String, schedule: DaySchedule)] = []
        for offset in 0..<7 {
            let dayStart = cal.date(byAdding: .day, value: offset, to: monday)!
            let key = AppClock.dayKey(for: dayStart)
            days.append((key, schedule(dayKey: key, dayStart: dayStart)))
        }
        return days
    }

    private func memberID(_ buddy: BuddySimulator.Buddy) -> String {
        BuddySimulator.member(for: buddy).id
    }

    // MARK: - Roster

    func testMembersMirrorTheSimulatedCircle() {
        XCTAssertEqual(source.members, roster.map { BuddySimulator.member(for: $0) },
                       "the seam hands back exactly the simulator's members, in order")
        XCTAssertEqual(source.members.map(\.id), roster.map { "buddy.\($0.name)" })
        XCTAssertFalse(source.members.contains { $0.isYou },
                       "the source answers for OTHER members; AppState appends you")
        XCTAssertEqual(source.maxMembers, BuddySimulator.maxFriends)

        // A solo account's circle is an empty source — that's what isSoloMode reads.
        XCTAssertTrue(SimulatedCircleDataSource(buddies: []).members.isEmpty)
    }

    // MARK: - Grid parity

    func testEntryMatchesTheSimulatorOutcomeIncludingTheRevealMoment() {
        let day = fixedDay()
        let src = source
        var postedCount = 0
        var qadaCount = 0
        var missedCount = 0

        for buddy in roster {
            let id = memberID(buddy)
            for window in day.schedule.windows {
                switch BuddySimulator.outcome(for: buddy, dayKey: day.dayKey, window: window) {
                case .inWindow(let tier, let loggedAt, let seed):
                    postedCount += 1
                    // Not visible yet: a beat before loggedAt the square waits.
                    let before = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                           window: window, now: loggedAt.addingTimeInterval(-1))
                    XCTAssertEqual(before.state, .waiting,
                                   "\(buddy.name)/\(window.prayer): hidden before loggedAt")
                    XCTAssertNil(before.placeLabel, "no place pill before the post lands")

                    // At loggedAt exactly, the post appears with its illustration.
                    let after = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                          window: window, now: loggedAt)
                    XCTAssertEqual(after.state,
                                   .posted(.illustration(seed: seed), tier: tier, at: loggedAt),
                                   "\(buddy.name)/\(window.prayer): same post as the simulator")
                    let tag: PlaceTag? = BuddySimulator.placeTag(seed: seed)
                    XCTAssertEqual(after.placeLabel, tag.map { "\($0.emoji) \($0.displayName)" },
                                   "\(buddy.name)/\(window.prayer): same place pill")

                case .qada(let at):
                    qadaCount += 1
                    let before = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                           window: window, now: at.addingTimeInterval(-1))
                    XCTAssertEqual(before.state, .waiting,
                                   "\(buddy.name)/\(window.prayer): a make-up isn't visible early")
                    let after = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                          window: window, now: at)
                    XCTAssertEqual(after.state, .qada(at: at))
                    XCTAssertNil(after.placeLabel, "make-ups carry no place pill")

                case .missed:
                    missedCount += 1
                    let before = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                           window: window, now: window.end.addingTimeInterval(-1))
                    XCTAssertEqual(before.state, .waiting,
                                   "\(buddy.name)/\(window.prayer): still hopeful inside the window")
                    let after = src.entry(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                          window: window, now: window.end)
                    XCTAssertEqual(after.state, .missed)
                }
            }
        }

        XCTAssertGreaterThan(postedCount, 0)
        XCTAssertGreaterThan(qadaCount, 0, "the probe day must exercise the make-up branch")
        XCTAssertGreaterThan(missedCount, 0, "…and the missed branch")
    }

    func testEntryWithoutAScheduleWaits() {
        let day = fixedDay()
        let entry = source.entry(forMember: memberID(roster[0]), prayer: .fajr,
                                 dayKey: day.dayKey, window: nil,
                                 now: date(2026, 6, 10, 12))
        XCTAssertEqual(entry.state, .waiting, "no window for that day → nothing to show")
        XCTAssertNil(entry.placeLabel)
    }

    func testCellMatchesTheSimulatorOutcomeAcrossTheDay() {
        let day = fixedDay()
        let src = source

        for buddy in roster {
            let id = memberID(buddy)
            for window in day.schedule.windows {
                // Before the window opens nothing has happened yet.
                XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                        window: window,
                                        now: window.start.addingTimeInterval(-1)), .future,
                               "\(buddy.name)/\(window.prayer): future before the window opens")

                switch BuddySimulator.outcome(for: buddy, dayKey: day.dayKey, window: window) {
                case .inWindow(let tier, let loggedAt, _):
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window,
                                            now: loggedAt.addingTimeInterval(-1)), .future)
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window, now: loggedAt), .inWindow(tier))
                case .qada(let at):
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window,
                                            now: at.addingTimeInterval(-1)), .future)
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window, now: at), .qada)
                case .missed:
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window,
                                            now: window.end.addingTimeInterval(-1)), .future)
                    XCTAssertEqual(src.cell(forMember: id, prayer: window.prayer, dayKey: day.dayKey,
                                            window: window, now: window.end), .missed)
                }
            }
        }

        XCTAssertEqual(source.cell(forMember: memberID(roster[0]), prayer: .fajr,
                                   dayKey: day.dayKey, window: nil,
                                   now: date(2026, 6, 10, 12)), .future,
                       "no window → nothing decided")
    }

    // MARK: - Week parity

    func testWeekLogsAndWeeklyXPMatchTheSimulator() {
        let days = weekDays()
        let src = source
        // Mid-week, so part of the week is still invisible.
        let asOf = cal.startOfDay(for: date(2026, 6, 8)).addingTimeInterval(3.5 * 86400)

        for buddy in roster {
            let id = memberID(buddy)
            let expectedLogs = BuddySimulator.visibleLogs(for: buddy, days: days, asOf: asOf)
            XCTAssertEqual(src.weekLogs(forMember: id, days: days, asOf: asOf), expectedLogs,
                           "\(buddy.name): the seam's week is the simulator's week")
            XCTAssertEqual(src.weeklyXP(forMember: id, days: days, asOf: asOf),
                           BuddySimulator.weeklyXP(for: buddy, days: days, asOf: asOf),
                           "\(buddy.name): scoreboard XP is unchanged")
            XCTAssertTrue(expectedLogs.allSatisfy { $0.loggedAt <= asOf },
                          "\(buddy.name): nothing from the future leaks in")
        }

        // End of the week: everyone's full week is visible, so XP can only grow.
        let endOfWeek = cal.startOfDay(for: date(2026, 6, 15))
        for buddy in roster {
            XCTAssertGreaterThanOrEqual(src.weeklyXP(forMember: memberID(buddy), days: days, asOf: endOfWeek),
                                        src.weeklyXP(forMember: memberID(buddy), days: days, asOf: asOf))
        }
    }

    func testSimulatedBuddiesEarnNoRecoveryXP() {
        // v4: recovery XP is one opaque weekly total per member (SPEC-V4 §3).
        // Demo buddies never take a break, so the demo scoreboard is prayer XP
        // alone — exactly what v3.9 showed.
        for buddy in roster {
            XCTAssertEqual(source.recoveryXP(forMember: memberID(buddy),
                                             weekKeys: ["2026-W24", "2026-W25"]), 0)
        }
    }

    func testAnUnknownMemberAnswersEmpty() {
        // A stale id (a member removed between renders, or "you" by mistake)
        // must never fall through to another buddy's outcome.
        let day = fixedDay()
        let days = weekDays()
        let now = date(2026, 6, 10, 23)
        guard let window = day.schedule.window(for: .fajr) else {
            XCTFail("the probe day has a fajr window")
            return
        }

        let entry = source.entry(forMember: "you", prayer: .fajr, dayKey: day.dayKey,
                                 window: window, now: now)
        XCTAssertEqual(entry.state, .waiting)
        XCTAssertNil(entry.placeLabel)
        XCTAssertEqual(source.cell(forMember: "you", prayer: .fajr, dayKey: day.dayKey,
                                   window: window, now: now), .future)
        XCTAssertTrue(source.weekLogs(forMember: "buddy.Nobody", days: days, asOf: now).isEmpty)
        XCTAssertEqual(source.weeklyXP(forMember: "buddy.Nobody", days: days, asOf: now), 0)
    }

    func testAnEmptyRealCircleShowsNothingUntilPhaseB3() {
        let day = fixedDay()
        let days = weekDays()
        let now = date(2026, 6, 10, 23)
        let empty = EmptyCircleDataSource()

        XCTAssertTrue(empty.members.isEmpty, "a real circle renders solo until membership syncs")
        XCTAssertEqual(empty.entry(forMember: "anyone", prayer: .fajr, dayKey: day.dayKey,
                                   window: day.schedule.window(for: .fajr), now: now).state, .waiting)
        XCTAssertEqual(empty.cell(forMember: "anyone", prayer: .fajr, dayKey: day.dayKey,
                                  window: day.schedule.window(for: .fajr), now: now), .future)
        XCTAssertTrue(empty.weekLogs(forMember: "anyone", days: days, asOf: now).isEmpty)
        XCTAssertEqual(empty.weeklyXP(forMember: "anyone", days: days, asOf: now), 0)
        XCTAssertEqual(empty.recoveryXP(forMember: "anyone", weekKeys: ["2026-W24"]), 0)
    }

    // MARK: - Circle mode

    func testCircleModeAbsentDecodesToDemo() throws {
        // A pre-v4 settings file has no circleMode key — it must keep the demo
        // circle it has always had, or every existing install changes shape.
        let json = """
        {"calcMethod":"northAmerica","madhab":"shafi","useDeviceLocation":true,
         "fixedLatitude":47.6,"fixedLongitude":-122.3,"locationName":"Seattle",
         "notificationsEnabled":true,"dailyGoal":100,"hasOnboarded":true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.circleMode, .demo)
        XCTAssertEqual(AppSettings().circleMode, .demo, "and a fresh install starts there too")

        // Explicit values round-trip both ways.
        var real = settings
        real.circleMode = .real
        let data = try JSONEncoder().encode(real)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.circleMode, .real)
        XCTAssertEqual(CircleMode.real.rawValue, "real")
        XCTAssertEqual(CircleMode(rawValue: "demo"), .demo)
    }

    // MARK: - Time-travel guard (SPEC-V4 §3)

    func testTimeTravelIsPinnedWhileARealCircleIsActive() {
        let savedAllowed = AppClock.isTimeTravelAllowed
        let savedOffset = AppClock.offset
        defer {
            AppClock.isTimeTravelAllowed = savedAllowed
            AppClock.offset = savedOffset
        }

        // Demo mode: the developer clock moves as it always has.
        AppClock.isTimeTravelAllowed = true
        AppClock.offset = 0
        AppClock.offset = 3600
        XCTAssertEqual(AppClock.offset, 3600, "demo mode keeps full time travel")

        // Real circle: the clock refuses to move — posting fictional
        // timestamps to real friends is the one thing time travel can't do.
        AppClock.isTimeTravelAllowed = false
        AppClock.offset = 7200
        XCTAssertEqual(AppClock.offset, 3600, "a real circle pins the clock where it stands")

        // …but the reset to real time always lands, so entering a real circle
        // can always clear an offset that was already set.
        AppClock.offset = 0
        XCTAssertEqual(AppClock.offset, 0)
        AppClock.offset = 3600
        XCTAssertEqual(AppClock.offset, 0, "still pinned, now at real time")
    }
}
