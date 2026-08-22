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
        let length: TimeInterval = 90 * 60
        // Annotated and unrolled on purpose: an inferred `zip(...).map` whose
        // body does its own arithmetic is exactly the shape that blew the
        // type-checker budget once already (see BuddySimulator.stableUUID).
        var windows: [PrayerWindow] = []
        for (prayer, hour) in zip(Prayer.allCases, hours) {
            let start: Date = dayStart.addingTimeInterval(hour * 3600)
            windows.append(PrayerWindow(prayer: prayer, start: start,
                                        end: start.addingTimeInterval(length)))
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

        // v4: demo and real seat the SAME number of people. These were 9 and 8
        // through the beta, because both modes inherited one number and counted
        // it differently (friends-excluding-you vs. seats). This assertion is
        // what stops them drifting apart again — the two constants are declared
        // in different files and nothing else forces them to agree.
        XCTAssertEqual(BuddySimulator.maxFriends, RemoteCircle.maxFriends,
                       "a demo circle and a real one must hold the same headcount")
        XCTAssertEqual(RemoteCircle.maxMembers, 12, "mirrors public.circle_max_members()")

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
        XCTAssertEqual(empty.maxMembers, RemoteCircle.maxFriends,
                       "a circle with nobody in it still has REAL seats, not the demo's 8")
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

// MARK: - Remote circle (v4)

/// v4 Phase B2: `RemoteCircleDataSource` — the same seam, answered from a
/// synced `CircleSnapshot` instead of the simulator.
///
/// Everything here runs off a hand-built mirror and no network, because that
/// is the promise: a real circle draws from disk. The assertions are about the
/// three things that could quietly go wrong — the reveal rule (nothing shows
/// before its `loggedAt`), the scoring path (`GameEngine` and nothing else),
/// and the photo boundary (a buddy's photo is a Storage path, never a
/// `PhotoStore` filename).
final class RemoteCircleSourceTests: XCTestCase {

    private let cal = Calendar.current

    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let meID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private let amira = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let bilal = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let stranger = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    /// Same synthetic day shape the simulated-seam tests use: five 90-minute
    /// windows, so both halves of the seam are probed against one clock.
    private let prayerHours: [Prayer: Double] = [.fajr: 5.5, .dhuhr: 13.0, .asr: 16.5,
                                                 .maghrib: 19.5, .isha: 21.0]

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return cal.date(from: c)!
    }

    private func start(_ dayStart: Date, _ prayer: Prayer) -> Date {
        dayStart.addingTimeInterval((prayerHours[prayer] ?? 0) * 3600)
    }

    private func end(_ dayStart: Date, _ prayer: Prayer) -> Date {
        start(dayStart, prayer).addingTimeInterval(90 * 60)
    }

    private func schedule(dayKey: String, dayStart: Date) -> DaySchedule {
        var windows: [PrayerWindow] = []
        for prayer in Prayer.allCases {
            windows.append(PrayerWindow(prayer: prayer,
                                        start: start(dayStart, prayer),
                                        end: end(dayStart, prayer)))
        }
        return DaySchedule(dayKey: dayKey, dayStart: dayStart, windows: windows)
    }

    private var mondayStart: Date { cal.startOfDay(for: date(2026, 6, 8)) }
    private var tuesdayStart: Date { cal.startOfDay(for: date(2026, 6, 9)) }
    private var mondayKey: String { AppClock.dayKey(for: mondayStart) }
    private var tuesdayKey: String { AppClock.dayKey(for: tuesdayStart) }
    private var monday: DaySchedule { schedule(dayKey: mondayKey, dayStart: mondayStart) }
    private var tuesday: DaySchedule { schedule(dayKey: tuesdayKey, dayStart: tuesdayStart) }

    private func weekDays() -> [(dayKey: String, schedule: DaySchedule)] {
        var days: [(dayKey: String, schedule: DaySchedule)] = []
        days.append((mondayKey, monday))
        days.append((tuesdayKey, tuesday))
        return days
    }

    private var amiraPhotoPath: String {
        "\(circleID.uuidString)/\(amira.uuidString)/monday-fajr.jpg"
    }

    private func stamp(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private func post(user: UUID, dayKey: String, prayer: Prayer, tier: LogTier,
                      loggedAt: Date, jamaat: Bool = false,
                      placeLabel: String? = nil, photoPath: String? = nil) -> RemotePost {
        RemotePost(id: UUID(), userID: user, circleID: circleID, dayKey: dayKey,
                   prayer: prayer, tier: tier, loggedAt: loggedAt, jamaat: jamaat,
                   placeLabel: placeLabel, photoPath: photoPath)
    }

    /// The mirror under test: Amira prayed all of Monday and part of Tuesday;
    /// Bilal rested on Monday and logged one Tuesday Fajr. Tuesday's rows are
    /// inserted FIRST so `weekLogs`' ordering has real work to do.
    private func fixture() -> CircleSnapshot {
        let mon: Date = mondayStart
        let tue: Date = tuesdayStart
        var posts: [RemotePost] = []

        posts.append(post(user: amira, dayKey: tuesdayKey, prayer: .dhuhr, tier: .prayed,
                          loggedAt: start(tue, .dhuhr).addingTimeInterval(1800)))
        // A make-up, logged an hour after the window shut.
        posts.append(post(user: amira, dayKey: tuesdayKey, prayer: .fajr, tier: .qada,
                          loggedAt: end(tue, .fajr).addingTimeInterval(3600)))
        posts.append(post(user: bilal, dayKey: tuesdayKey, prayer: .fajr, tier: .prayed,
                          loggedAt: start(tue, .fajr).addingTimeInterval(1800)))

        posts.append(post(user: amira, dayKey: mondayKey, prayer: .fajr, tier: .onTime,
                          loggedAt: start(mon, .fajr).addingTimeInterval(600),
                          placeLabel: "🏠 Home", photoPath: amiraPhotoPath))
        // An empty place label is a column that came back blank, not a pill.
        posts.append(post(user: amira, dayKey: mondayKey, prayer: .dhuhr, tier: .onTime,
                          loggedAt: start(mon, .dhuhr).addingTimeInterval(600),
                          placeLabel: ""))
        posts.append(post(user: amira, dayKey: mondayKey, prayer: .asr, tier: .onTime,
                          loggedAt: start(mon, .asr).addingTimeInterval(600)))
        posts.append(post(user: amira, dayKey: mondayKey, prayer: .maghrib, tier: .lastCall,
                          loggedAt: start(mon, .maghrib).addingTimeInterval(4200), jamaat: true))
        // Retention cleared this one's photo — an empty path is no path.
        posts.append(post(user: amira, dayKey: mondayKey, prayer: .isha, tier: .onTime,
                          loggedAt: start(mon, .isha).addingTimeInterval(600),
                          photoPath: ""))

        let profiles: [RemoteProfile] = [
            RemoteProfile(id: amira, name: "Amira", avatarEmoji: "🌸",
                          avatarPath: "avatars/amira.jpg"),
            RemoteProfile(id: bilal, name: "Bilal", avatarEmoji: "🌙"),
            RemoteProfile(id: meID, name: "Haashim", avatarEmoji: "😄"),
        ]
        let members: [RemoteMember] = [
            RemoteMember(circleID: circleID, userID: amira, joinedAt: stamp(0)),
            RemoteMember(circleID: circleID, userID: bilal, joinedAt: stamp(60)),
            RemoteMember(circleID: circleID, userID: meID, joinedAt: stamp(120)),
        ]
        let excused: [RemoteExcusedDay] = [
            RemoteExcusedDay(userID: bilal, circleID: circleID, dayKey: mondayKey),
        ]
        let recovery: [RemoteRecoveryWeek] = [
            RemoteRecoveryWeek(userID: amira, circleID: circleID, weekKey: "2026-W24", xp: 40),
            RemoteRecoveryWeek(userID: amira, circleID: circleID, weekKey: "2026-W25", xp: 10),
        ]
        return CircleSnapshot(circle: RemoteCircle(id: circleID, code: "ABC234"),
                              me: meID, profiles: profiles, members: members,
                              posts: posts, excusedDays: excused, recoveryWeeks: recovery)
    }

    private func source() -> RemoteCircleDataSource {
        RemoteCircleDataSource(snapshot: fixture())
    }

    // MARK: - Roster

    func testRosterComesFromTheMirrorWithoutYou() {
        let src = source()
        XCTAssertEqual(src.members.map { $0.id }, [amira.uuidString, bilal.uuidString],
                       "join order, and you are not in it — AppState appends you")
        XCTAssertEqual(src.members.map { $0.name }, ["Amira", "Bilal"])
        XCTAssertEqual(src.members.first?.emoji, "🌸")
        XCTAssertFalse(src.members.contains { $0.isYou })
        XCTAssertTrue(src.members.allSatisfy { $0.avatarFilename == nil },
                      "a buddy's avatar is a Storage path, never a PhotoStore filename")
        XCTAssertEqual(src.avatarPath(forMember: amira.uuidString), "avatars/amira.jpg")
        XCTAssertNil(src.avatarPath(forMember: bilal.uuidString))

        // 8 seats in a circle means 7 FRIENDS — the off-by-one the invite copy
        // would otherwise get wrong.
        XCTAssertEqual(src.maxMembers, RemoteCircle.maxFriends)
        XCTAssertEqual(src.maxMembers, RemoteCircle.maxMembers - 1)
    }

    // MARK: - Grid

    func testASyncedDayDrawsTheSameStatesTheSimulatorWould() {
        let src = source()
        let id: String = amira.uuidString
        let fajrWindow = monday.window(for: .fajr)
        let loggedAt: Date = start(mondayStart, .fajr).addingTimeInterval(600)
        let seed: UInt64 = BuddySimulator.seed(name: id, dayKey: mondayKey, prayer: .fajr)

        let posted = src.entry(forMember: id, prayer: .fajr, dayKey: mondayKey,
                               window: fajrWindow, now: loggedAt)
        XCTAssertEqual(posted.state,
                       .posted(.illustration(seed: seed), tier: .onTime, at: loggedAt))
        XCTAssertEqual(posted.placeLabel, "🏠 Home")
        XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                window: fajrWindow, now: loggedAt), .inWindow(.onTime))

        // A blank place column is no pill at all.
        let noPill = src.entry(forMember: id, prayer: .dhuhr, dayKey: mondayKey,
                               window: monday.window(for: .dhuhr),
                               now: start(mondayStart, .dhuhr).addingTimeInterval(600))
        XCTAssertNil(noPill.placeLabel)

        // A make-up: the blue "made up" tile, no photo and no pill, ever.
        let qadaAt: Date = end(tuesdayStart, .fajr).addingTimeInterval(3600)
        let qadaWindow = tuesday.window(for: .fajr)
        let qada = src.entry(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                             window: qadaWindow, now: qadaAt)
        XCTAssertEqual(qada.state, .qada(at: qadaAt))
        XCTAssertNil(qada.placeLabel)
        XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                                window: qadaWindow, now: qadaAt), .qada)

        // Nothing logged: still hopeful inside the window, quietly missed after.
        let asrWindow = tuesday.window(for: .asr)
        let inside: Date = end(tuesdayStart, .asr).addingTimeInterval(-1)
        XCTAssertEqual(src.entry(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                 window: asrWindow, now: inside).state, .waiting)
        XCTAssertEqual(src.cell(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                window: asrWindow, now: inside), .future)
        let after: Date = end(tuesdayStart, .asr)
        XCTAssertEqual(src.entry(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                 window: asrWindow, now: after).state, .missed)
        XCTAssertEqual(src.cell(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                window: asrWindow, now: after), .missed)

        // No schedule for that day → nothing is decided either way.
        XCTAssertEqual(src.entry(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                 window: nil, now: after).state, .waiting)
        XCTAssertEqual(src.cell(forMember: id, prayer: .asr, dayKey: tuesdayKey,
                                window: nil, now: after), .future)
    }

    func testAPostIsInvisibleUntilItsLoggedAt() {
        let src = source()
        let id: String = bilal.uuidString
        let fajrWindow = tuesday.window(for: .fajr)
        let loggedAt: Date = start(tuesdayStart, .fajr).addingTimeInterval(1800)
        let justBefore: Date = loggedAt.addingTimeInterval(-1)

        let before = src.entry(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                               window: fajrWindow, now: justBefore)
        XCTAssertEqual(before.state, .waiting, "a post never shows before it was logged")
        XCTAssertNil(before.placeLabel)
        XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                                window: fajrWindow, now: justBefore), .future)

        let seed: UInt64 = BuddySimulator.seed(name: id, dayKey: tuesdayKey, prayer: .fajr)
        let after = src.entry(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                              window: fajrWindow, now: loggedAt)
        XCTAssertEqual(after.state,
                       .posted(.illustration(seed: seed), tier: .prayed, at: loggedAt))
        XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: tuesdayKey,
                                window: fajrWindow, now: loggedAt), .inWindow(.prayed))

        // The week agrees with the grid, so the scoreboard can't run ahead of it.
        let days = weekDays()
        XCTAssertTrue(src.weekLogs(forMember: id, days: days, asOf: justBefore).isEmpty)
        XCTAssertEqual(src.weeklyXP(forMember: id, days: days, asOf: justBefore), 0)
        XCTAssertEqual(src.weekLogs(forMember: id, days: days, asOf: loggedAt).count, 1)

        // A pending post whose window has ALREADY closed still waits — showing
        // "missed" and then correcting itself would be the worst of both.
        let pending: Date = end(tuesdayStart, .fajr).addingTimeInterval(60)
        XCTAssertEqual(src.entry(forMember: amira.uuidString, prayer: .fajr, dayKey: tuesdayKey,
                                 window: tuesday.window(for: .fajr), now: pending).state,
                       .waiting, "Amira's make-up lands later; the square holds until then")
        XCTAssertEqual(src.cell(forMember: amira.uuidString, prayer: .fajr, dayKey: tuesdayKey,
                                window: tuesday.window(for: .fajr), now: pending), .future)
    }

    func testAnExcusedDayRestsTheWholeRow() {
        let src = source()
        let id: String = bilal.uuidString

        for prayer in Prayer.allCases {
            let window = monday.window(for: prayer)
            // Before the window, inside it, and long after — a resting day
            // reads the same all day long.
            let probes: [Date] = [mondayStart,
                                  start(mondayStart, prayer).addingTimeInterval(60),
                                  end(mondayStart, prayer).addingTimeInterval(3600)]
            for now in probes {
                XCTAssertEqual(src.entry(forMember: id, prayer: prayer, dayKey: mondayKey,
                                         window: window, now: now).state, .excused,
                               "\(prayer.rawValue) at \(now)")
                XCTAssertEqual(src.cell(forMember: id, prayer: prayer, dayKey: mondayKey,
                                        window: window, now: now), .excused,
                               "\(prayer.rawValue) at \(now)")
            }
        }

        // The flag is per member — Amira wasn't resting.
        let amiraState = src.entry(forMember: amira.uuidString, prayer: .fajr, dayKey: mondayKey,
                                   window: monday.window(for: .fajr),
                                   now: end(mondayStart, .isha)).state
        XCTAssertNotEqual(amiraState, .excused)
    }

    // MARK: - Week

    func testWeeklyXPRunsGameEngineOverTheMirror() {
        let src = source()
        let days = weekDays()
        let asOf: Date = tuesdayStart.addingTimeInterval(86400)

        let logs: [PrayerLog] = src.weekLogs(forMember: amira.uuidString, days: days, asOf: asOf)
        XCTAssertEqual(logs.count, 7, "Amira's seven posts, and none of Bilal's")
        let expectedDays: [String] = [mondayKey, mondayKey, mondayKey, mondayKey, mondayKey,
                                      tuesdayKey, tuesdayKey]
        XCTAssertEqual(logs.map { $0.dayKey }, expectedDays, "day order, oldest first")
        let mondayPrayers: [Prayer] = logs.prefix(5).map { $0.prayer }
        XCTAssertEqual(mondayPrayers, Array(Prayer.allCases),
                       "then the canonical prayer order, like the simulator's week")
        XCTAssertNil(logs.first?.photoFilename, "no buddy photo ever reaches PhotoStore")

        // Monday: 4 × 30 on-time + a jamaat lastCall floored to 30 = 150, all
        // five in-window so +25 perfect-day = 175. Tuesday: qada 5 + prayed 20.
        XCTAssertEqual(GameEngine.xp(forDay: mondayKey, logs: logs), 175)
        XCTAssertEqual(GameEngine.xp(forDay: tuesdayKey, logs: logs), 25)
        XCTAssertEqual(src.weeklyXP(forMember: amira.uuidString, days: days, asOf: asOf), 200)
        XCTAssertEqual(src.weeklyXP(forMember: bilal.uuidString, days: days, asOf: asOf), 20,
                       "a rested Monday scores nothing, and scores no penalty either")
    }

    func testAnExcusedDayVoidsThePerfectDayBonusForABuddyToo() {
        var snapshot = fixture()
        snapshot.excusedDays.append(RemoteExcusedDay(userID: amira, circleID: circleID,
                                                     dayKey: mondayKey))
        let src = RemoteCircleDataSource(snapshot: snapshot)
        let asOf: Date = tuesdayStart.addingTimeInterval(86400)
        XCTAssertEqual(src.weeklyXP(forMember: amira.uuidString, days: weekDays(), asOf: asOf), 175,
                       "200 minus the 25 perfect-day bonus a resting day can't earn")
    }

    func testRecoveryXPIsTheOpaqueWeeklyTotal() {
        let src = source()
        let id: String = amira.uuidString
        XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: ["2026-W24"]), 40)
        XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: ["2026-W24", "2026-W25"]), 50)
        XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: ["2026-W30"]), 0)
        XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: []), 0)
        XCTAssertEqual(src.recoveryXP(forMember: bilal.uuidString, weekKeys: ["2026-W24"]), 0)
    }

    // MARK: - Photos (SPEC-V4 §4)

    func testASyncedPhotoIsAPathNotAPhotoStoreFilename() {
        let src = source()
        let id: String = amira.uuidString
        let loggedAt: Date = start(mondayStart, .fajr).addingTimeInterval(600)
        let entry = src.entry(forMember: id, prayer: .fajr, dayKey: mondayKey,
                              window: monday.window(for: .fajr), now: loggedAt)

        guard case .posted(let content, _, _) = entry.state else {
            XCTFail("Amira's Monday Fajr is a posted square")
            return
        }
        if case .photo = content {
            XCTFail("a Storage path must never be handed to PhotoStore as a filename")
        }
        let seed: UInt64 = BuddySimulator.seed(name: id, dayKey: mondayKey, prayer: .fajr)
        XCTAssertEqual(content, .illustration(seed: seed),
                       "the stand-in is seeded, so the same post looks the same on every phone")

        // The real path travels alongside, for Phase C's buddy-photo cache.
        XCTAssertEqual(src.photoPath(forMember: id, prayer: .fajr, dayKey: mondayKey),
                       amiraPhotoPath)
        // Retention cleared Isha's photo; Asr never had one; Tuesday's Asr has
        // no post at all.
        XCTAssertNil(src.photoPath(forMember: id, prayer: .isha, dayKey: mondayKey))
        XCTAssertNil(src.photoPath(forMember: id, prayer: .asr, dayKey: mondayKey))
        XCTAssertNil(src.photoPath(forMember: id, prayer: .asr, dayKey: tuesdayKey))
    }

    // MARK: - Offline safety

    func testAnEmptyMirrorIsAnEmptyCircleNotACrash() throws {
        let src = RemoteCircleDataSource(snapshot: .empty)
        let days = weekDays()
        let id: String = amira.uuidString
        let window = monday.window(for: .fajr)

        XCTAssertTrue(src.members.isEmpty, "no circle yet renders exactly like a solo account")
        XCTAssertFalse(src.snapshot.hasCircle)
        XCTAssertEqual(src.maxMembers, RemoteCircle.maxFriends)
        XCTAssertEqual(src.entry(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                 window: window, now: mondayStart).state, .waiting)
        XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                window: window, now: mondayStart), .future)
        XCTAssertTrue(src.weekLogs(forMember: id, days: days, asOf: mondayStart).isEmpty)
        XCTAssertEqual(src.weeklyXP(forMember: id, days: days, asOf: mondayStart), 0)
        XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: ["2026-W24"]), 0)
        XCTAssertNil(src.avatarPath(forMember: id))
        XCTAssertNil(src.photoPath(forMember: id, prayer: .fajr, dayKey: mondayKey))

        // An ABSENT circle.json decodes to exactly that mirror, so a first
        // launch and a wiped one behave identically.
        let blank = try JSONDecoder().decode(CircleSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(blank, CircleSnapshot.empty)
    }

    /// A mirror can hold a roster before it holds an identity: `circle.json`
    /// loads on launch, auth resolves after. Rendering it in between would put
    /// YOU in the buddy list — and `AppState` appends you on top of that, so
    /// the scoreboard, the week grid and the crown would all see you twice.
    func testAMirrorWithoutAnIdentityRendersNoCircleAtAll() {
        var snapshot: CircleSnapshot = fixture()
        snapshot.me = nil
        let src = RemoteCircleDataSource(snapshot: snapshot)

        XCTAssertTrue(snapshot.buddyMembers.isEmpty,
                      "no identity, no circle — never a circle that still contains you")
        XCTAssertTrue(src.members.isEmpty)

        // And it answers for nobody, so your own posts can't surface inside a
        // phantom buddy row either.
        let now: Date = end(mondayStart, .isha).addingTimeInterval(3600)
        let ids: [String] = [meID.uuidString, amira.uuidString]
        for id in ids {
            XCTAssertEqual(src.entry(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                     window: monday.window(for: .fajr), now: now).state,
                           .waiting, "id \(id)")
            XCTAssertEqual(src.weeklyXP(forMember: id, days: weekDays(), asOf: now), 0, "id \(id)")
            XCTAssertNil(src.avatarPath(forMember: id), "id \(id)")
        }
    }

    func testTheSourceNeverAnswersForYouOrAStranger() {
        let src = source()
        let days = weekDays()
        let window = monday.window(for: .fajr)
        // Long past every Monday window, so a wrongly-resolved id would answer
        // `.missed` rather than the `.waiting` an unknown member gets.
        let now: Date = end(mondayStart, .isha).addingTimeInterval(3600)
        let ids: [String] = [meID.uuidString, stranger.uuidString, "you", "buddy.Mina", ""]

        for id in ids {
            XCTAssertEqual(src.entry(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                     window: window, now: now).state, .waiting, "id \(id)")
            XCTAssertEqual(src.cell(forMember: id, prayer: .fajr, dayKey: mondayKey,
                                    window: window, now: now), .future, "id \(id)")
            XCTAssertTrue(src.weekLogs(forMember: id, days: days, asOf: now).isEmpty, "id \(id)")
            XCTAssertEqual(src.weeklyXP(forMember: id, days: days, asOf: now), 0, "id \(id)")
            XCTAssertEqual(src.recoveryXP(forMember: id, weekKeys: ["2026-W24"]), 0, "id \(id)")
            XCTAssertNil(src.avatarPath(forMember: id), "id \(id)")
        }
    }
}
