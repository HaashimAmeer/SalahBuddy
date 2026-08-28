import Foundation
import XCTest
@testable import SalahBuddy

/// v4 Phase D: the circle page of the weekly recap (§5), and the local hide
/// behind "Report this photo" (§4).
///
/// Both are exercised through their PURE surfaces. `AppState` is orchestration
/// and isn't unit-tested anywhere in this repo, and here there is a second
/// reason: a real circle pins the developer clock to real time (§3), so a test
/// could not time-travel to a fixed finished week to reach the instance method
/// at all. `AppState.circleRecap(mode:mirror:weekDayKeys:now:you:)` takes the
/// mode, the mirror and the clock as arguments precisely so this file can.
/// A server failure with no SQLSTATE and no `URLError` — a 502, a proxy, a
/// body that would not decode.
private struct ReportFailure: Error {}

@MainActor
final class CircleRecapTests: XCTestCase {

    // MARK: - Fixtures

    private let me = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let amina = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
    private let yusuf = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
    private let circleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    private let cal = Calendar.current

    /// 2026-06-08 is a Monday — the week every other suite uses.
    private let week = ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11",
                        "2026-06-12", "2026-06-13", "2026-06-14"]
    /// The Monday AFTER the recapped week: anything here must be invisible.
    private let nextMonday = "2026-06-15"

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }

    /// Well after the week closed, so every post below is visible.
    private var asOf: Date { date(2026, 6, 15, 12) }

    /// A distinct, increasing stamp per (day, prayer) so the crown race has an
    /// unambiguous order to walk.
    private func stamp(dayKey: String, prayer: Prayer) -> Date {
        let dayStart: Date = AppClock.date(fromDayKey: dayKey) ?? date(2026, 6, 8)
        let slot: Int = Prayer.allCases.firstIndex(of: prayer) ?? 0
        return dayStart.addingTimeInterval(Double(5 + slot * 3) * 3600)
    }

    private func post(_ user: UUID, _ prayer: Prayer, _ dayKey: String,
                      tier: LogTier = .onTime, photoPath: String? = nil) -> RemotePost {
        RemotePost(id: UUID(), userID: user, circleID: circleID, dayKey: dayKey,
                   prayer: prayer, tier: tier, loggedAt: stamp(dayKey: dayKey, prayer: prayer),
                   photoPath: photoPath)
    }

    /// All five prayers of one day, same tier — a "perfect day" when the tier
    /// is in-window and the day isn't excused.
    private func fullDay(_ user: UUID, _ dayKey: String, tier: LogTier = .onTime) -> [RemotePost] {
        Prayer.allCases.map { post(user, $0, dayKey, tier: tier) }
    }

    private func log(_ prayer: Prayer, _ dayKey: String, tier: LogTier = .onTime) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                  loggedAt: stamp(dayKey: dayKey, prayer: prayer), tier: tier,
                  xp: GameEngine.prayerXP(tier: tier, jamaat: false))
    }

    private func myFullDay(_ dayKey: String, tier: LogTier = .onTime) -> [PrayerLog] {
        Prayer.allCases.map { log($0, dayKey, tier: tier) }
    }

    private func member(_ id: UUID, joinedHoursIn: Int) -> RemoteMember {
        RemoteMember(circleID: circleID, userID: id,
                     joinedAt: date(2026, 6, 1).addingTimeInterval(Double(joinedHoursIn) * 3600))
    }

    /// The mirror as a pull would leave it: me plus two friends, in a fixed
    /// join order so the roster (and therefore every tie-break below) is
    /// deterministic.
    private func mirror(posts: [RemotePost],
                        excused: [RemoteExcusedDay] = [],
                        recovery: [RemoteRecoveryWeek] = []) -> CircleSnapshot {
        CircleSnapshot(circle: RemoteCircle(id: circleID, code: "ABC234",
                                            name: "Test", emoji: "🤝"),
                       me: me,
                       profiles: [RemoteProfile(id: me, name: "Haashim"),
                                  RemoteProfile(id: amina, name: "Amina"),
                                  RemoteProfile(id: yusuf, name: "Yusuf")],
                       members: [member(me, joinedHoursIn: 0),
                                 member(amina, joinedHoursIn: 1),
                                 member(yusuf, joinedHoursIn: 2)],
                       posts: posts, excusedDays: excused, recoveryWeeks: recovery)
    }

    /// The same mirror with a roster the test chooses, for the questions that
    /// are about WHEN somebody joined rather than what they prayed.
    private func mirror(posts: [RemotePost], members: [RemoteMember]) -> CircleSnapshot {
        CircleSnapshot(circle: RemoteCircle(id: circleID, code: "ABC234",
                                            name: "Test", emoji: "🤝"),
                       me: me,
                       profiles: [RemoteProfile(id: me, name: "Haashim"),
                                  RemoteProfile(id: amina, name: "Amina")],
                       members: members, posts: posts)
    }

    private func youEntry(logs: [PrayerLog],
                          excused: Set<String> = [],
                          recoveryXP: Int = 0) -> AppState.CircleWeekEntry {
        AppState.CircleWeekEntry(member: CircleMember(id: "you", name: "Haashim", emoji: "😄",
                                                      isYou: true),
                                 logs: logs, excusedDayKeys: excused, recoveryXP: recoveryXP)
    }

    /// The scenario the assertions below share.
    ///
    /// * **Amina** — a perfect Monday (175), a strong Tuesday (160), then one
    ///   fajr on Wednesday. Her running total crosses 300 at Wednesday fajr.
    /// * **You** — three complete days at the second-quarter tier (125 each).
    ///   The most XP of anyone, but the 300th point doesn't land until
    ///   Wednesday's isha — hours after Amina's.
    /// * **Yusuf** — three prayers on Thursday, and a big private dhikr week.
    ///
    /// So the crown and the top of the table are DIFFERENT people, which is the
    /// whole point of a race.
    private func scenarioMirror() -> CircleSnapshot {
        var posts: [RemotePost] = []
        posts += fullDay(amina, week[0])
        for prayer in Prayer.allCases {
            let tier: LogTier = (prayer == .isha) ? .lastCall : .onTime
            posts.append(post(amina, prayer, week[1], tier: tier))
        }
        posts.append(post(amina, .fajr, week[2]))
        posts += [post(yusuf, .fajr, week[3]),
                  post(yusuf, .dhuhr, week[3]),
                  post(yusuf, .asr, week[3])]
        let recovery = [RemoteRecoveryWeek(userID: yusuf, circleID: circleID,
                                           weekKey: BuddySimulator.weekKey(for: date(2026, 6, 8)),
                                           xp: 200)]
        return mirror(posts: posts, recovery: recovery)
    }

    private func scenarioYou() -> AppState.CircleWeekEntry {
        var mine: [PrayerLog] = []
        mine += myFullDay(week[0], tier: .prayed)
        mine += myFullDay(week[1], tier: .prayed)
        mine += myFullDay(week[2], tier: .prayed)
        return youEntry(logs: mine)
    }

    private func scenarioRecap() throws -> AppState.CircleWeekRecap {
        let recap = AppState.circleRecap(mode: .real, mirror: scenarioMirror(),
                                         weekDayKeys: week, now: asOf, you: scenarioYou())
        return try XCTUnwrap(recap)
    }

    // MARK: - The week it recaps

    func testTheRecapIsLabelledWithTheWeekItWasGiven() throws {
        let recap = try scenarioRecap()
        XCTAssertEqual(recap.weekStartDayKey, week[0])
        XCTAssertEqual(recap.weekEndDayKey, week[6])
    }

    /// The recap covers ONE finished week. Posts from the week that started
    /// afterwards belong to the live scoreboard, not to this card — if they
    /// leaked in, the "best day" would keep changing after the week it
    /// describes had ended.
    func testPostsFromTheFollowingWeekAreNotCounted() throws {
        let quiet = try scenarioRecap()

        var withNextWeek: CircleSnapshot = scenarioMirror()
        // A monster Monday for Yusuf — but in the NEXT week.
        withNextWeek.posts += fullDay(yusuf, nextMonday)

        let loud = try XCTUnwrap(AppState.circleRecap(mode: .real, mirror: withNextWeek,
                                                      weekDayKeys: week, now: asOf,
                                                      you: scenarioYou()))
        XCTAssertEqual(loud.bestDay?.dayKey, quiet.bestDay?.dayKey)
        XCTAssertEqual(loud.standings.map(\.xp), quiet.standings.map(\.xp))
    }

    /// Your own logs are handed in whole (the caller filters, and so does the
    /// recap) — belt and braces, because your row is the one built from local
    /// history rather than from the mirror.
    func testYourOwnLogsOutsideTheWeekAreNotCounted() throws {
        let tight = try scenarioRecap()
        var loose: [PrayerLog] = scenarioYou().logs
        loose += myFullDay(nextMonday)
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real, mirror: scenarioMirror(),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: loose)))
        XCTAssertEqual(recap.standings.map(\.xp), tight.standings.map(\.xp))
    }

    /// A post stamped in the future — a friend's device with a wrong clock —
    /// cannot win anything before its time. Same reveal rule the grid uses.
    func testAPostStampedAfterNowIsNotCounted() throws {
        let future = RemotePost(id: UUID(), userID: yusuf, circleID: circleID,
                                dayKey: week[6], prayer: .fajr, tier: .onTime,
                                loggedAt: asOf.addingTimeInterval(3600))
        var posts: [RemotePost] = scenarioMirror().posts
        posts.append(future)

        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real, mirror: mirror(posts: posts),
                                                       weekDayKeys: week, now: asOf,
                                                       you: scenarioYou()))
        let his = try XCTUnwrap(recap.standings.first { $0.member.name == "Yusuf" })
        // 3 prayers on Thursday (90) — the future fajr adds nothing. No
        // recovery row in this mirror, so 90 is the whole number.
        XCTAssertEqual(his.xp, 90)
    }

    // MARK: - Best day in the circle

    func testBestDayIsTheHighestScoringDayAnyoneHad() throws {
        let recap = try scenarioRecap()
        let best = try XCTUnwrap(recap.bestDay)
        XCTAssertEqual(best.member.name, "Amina")
        XCTAssertEqual(best.dayKey, week[0])
        // Five in-window prayers (150) plus the perfect-day bonus (25).
        XCTAssertEqual(best.xp, GameEngine.perfectDayBonus + 5 * LogTier.onTime.xp)
    }

    /// The best day can be yours, and the card says so.
    func testYourOwnDayCanBeTheBestInTheCircle() throws {
        let posts: [RemotePost] = [post(yusuf, .fajr, week[3]),
                                   post(yusuf, .dhuhr, week[3]),
                                   post(yusuf, .asr, week[3])]
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real, mirror: mirror(posts: posts),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: myFullDay(week[4]))))
        let best = try XCTUnwrap(recap.bestDay)
        XCTAssertTrue(best.member.isYou)
        XCTAssertEqual(best.dayKey, week[4])
        XCTAssertEqual(best.xp, GameEngine.perfectDayBonus + 5 * LogTier.onTime.xp)
    }

    /// Two identical days have to resolve the same way on every phone in the
    /// circle, or two friends see two different "best days" for one week.
    ///
    /// v4 Phase D FIX: this used to be "strictly greater, walked in roster
    /// order, then you" — and that order is different on every device, because
    /// every device puts ITSELF last. On your phone the walk is
    /// [Amina, Yusuf, you]; on Amina's it is [you, Yusuf, Amina]. Equal perfect
    /// days are the common case, not an edge, so two members of one circle read
    /// two different "best day in the circle" for the same week. The order is
    /// now a property of the data: more XP, else the earlier day, else the lower
    /// name.
    func testATieForTheBestDayIsBrokenTheSameWayEverywhere() throws {
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real,
                                                       mirror: mirror(posts: fullDay(amina, week[0])),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: myFullDay(week[0]))))
        let best = try XCTUnwrap(recap.bestDay)
        XCTAssertEqual(best.member.name, "Amina")
        XCTAssertEqual(best.dayKey, week[0])
    }

    /// The same tie, seen from the OTHER phone: the pure function is handed the
    /// same three members in the order that device would build them (itself
    /// last). The answer has to be identical, or the circle disagrees with
    /// itself about one week.
    func testTheBestDayIsTheSameWhicheverMemberIsLooking() throws {
        let aminaEntry = AppState.CircleWeekEntry(
            member: CircleMember(id: amina.uuidString, name: "Amina", emoji: "🌙", isYou: false),
            logs: Prayer.allCases.map { log($0, week[0]) },
            excusedDayKeys: [], recoveryXP: 0)
        let yourEntry: AppState.CircleWeekEntry = youEntry(logs: myFullDay(week[0]))
        let yusufEntry = AppState.CircleWeekEntry(
            member: CircleMember(id: yusuf.uuidString, name: "Yusuf", emoji: "⭐️", isYou: false),
            logs: [log(.fajr, week[2])], excusedDayKeys: [], recoveryXP: 0)

        // Your phone: buddies in roster order, you last.
        let mine = try XCTUnwrap(AppState.circleRecap(
            weekDayKeys: week, entries: [aminaEntry, yusufEntry, yourEntry]))
        // Amina's phone: the same roster, with HER last.
        let hers = try XCTUnwrap(AppState.circleRecap(
            weekDayKeys: week, entries: [yourEntry, yusufEntry, aminaEntry]))

        XCTAssertEqual(mine.bestDay?.member.name, hers.bestDay?.member.name)
        XCTAssertEqual(mine.bestDay?.dayKey, hers.bestDay?.dayKey)
        XCTAssertEqual(mine.bestDay?.xp, hers.bestDay?.xp)
    }

    /// An equal-XP tie across two DIFFERENT days goes to the earlier day — a
    /// rule about the week, not about who is holding the phone.
    func testAnEqualDayTieGoesToTheEarlierDay() throws {
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real,
                                                       mirror: mirror(posts: fullDay(amina, week[3])),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: myFullDay(week[1]))))
        let best = try XCTUnwrap(recap.bestDay)
        XCTAssertTrue(best.member.isYou)
        XCTAssertEqual(best.dayKey, week[1])
    }

    /// A rest day is gentle for a buddy exactly as it is for you: it voids the
    /// perfect-day bonus rather than scoring five prayers as a triumph.
    func testAnExcusedDayLosesThePerfectDayBonus() throws {
        let posts: [RemotePost] = fullDay(amina, week[0])
        let excused = [RemoteExcusedDay(userID: amina, circleID: circleID, dayKey: week[0])]
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real,
                                                       mirror: mirror(posts: posts, excused: excused),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: myFullDay(week[3],
                                                                                     tier: .lastCall))))
        let best = try XCTUnwrap(recap.bestDay)
        XCTAssertEqual(best.member.name, "Amina")
        XCTAssertEqual(best.xp, 5 * LogTier.onTime.xp, "the bonus is voided, the prayers still count")
    }

    // MARK: - The crown

    func testCrownGoesToWhoeverReachedTheTargetFirstNotToTheTopScorer() throws {
        let recap = try scenarioRecap()
        let crown = try XCTUnwrap(recap.crownHolder)
        XCTAssertEqual(crown.name, "Amina")
        XCTAssertFalse(crown.isYou)

        let top = try XCTUnwrap(recap.topScorer)
        XCTAssertTrue(top.isYou, "you scored the most; Amina got there first")
        XCTAssertNotEqual(top.id, crown.id)
    }

    /// The crown is decided by the same function the live scoreboard uses, so
    /// the recap can never crown somebody the Circle tab never did.
    ///
    /// v4.2: "the same logs" now includes the same rest days — each runner's
    /// own, off the mirror for a friend and out of the entry for you.
    func testCrownMatchesTheLiveRaceOverTheSameLogs() throws {
        let recap = try scenarioRecap()
        let snapshot: CircleSnapshot = scenarioMirror()
        var memberWeekLogs: [ChallengeEngine.MemberWeek] = []
        for buddy in snapshot.buddyMembers {
            guard let id = UUID(uuidString: buddy.id) else { continue }
            memberWeekLogs.append((buddy, snapshot.prayerLogs(userID: id, dayKeys: week),
                                   snapshot.excusedDayKeys(userID: id)))
        }
        memberWeekLogs.append((scenarioYou().member, scenarioYou().logs,
                               scenarioYou().excusedDayKeys))
        XCTAssertEqual(recap.crownHolderID,
                       ChallengeEngine.raceWinnerID(memberWeekLogs: memberWeekLogs))
    }

    /// A rest day voids the perfect-day bonus in the RACE as well as in the
    /// standings — the half v4.1 left out when it gave the race its own walk of
    /// the week.
    ///
    /// Amina's Monday is perfect and her crossing lands on Wednesday's fajr
    /// (175 + 160 + 30 = 365, past 300 exactly there). Mark that Monday a rest
    /// day and she is 25 short: her fajr leaves her on 340 — still over — so
    /// the crown is checked where it actually moves, against a week trimmed to
    /// Monday and Tuesday, which is 335 whole and 310 rested… and a target of
    /// 325 that only the bonus can reach.
    func testAnExcusedDayCannotCarryARunnerOverTheTarget() throws {
        var posts: [RemotePost] = fullDay(amina, week[0])
        for prayer in Prayer.allCases {
            let tier: LogTier = (prayer == .isha) ? .lastCall : .onTime
            posts.append(post(amina, prayer, week[1], tier: tier))
        }
        let logs: [PrayerLog] = mirror(posts: posts).prayerLogs(userID: amina, dayKeys: week)
        XCTAssertEqual(GameEngine.raceXP(logs: logs, excusedDayKeys: []), 175 + 160)
        XCTAssertEqual(GameEngine.raceXP(logs: logs, excusedDayKeys: [week[0]]), 150 + 160)

        let her = CircleMember(id: amina.uuidString, name: "Amina", emoji: "🌸", isYou: false)
        XCTAssertNotNil(ChallengeEngine.raceWinnerID(memberWeekLogs: [(her, logs, [])],
                                                     threshold: 325),
                        "her perfect Monday carries her over 325")
        XCTAssertNil(ChallengeEngine.raceWinnerID(memberWeekLogs: [(her, logs, [week[0]])],
                                                  threshold: 325),
                     "a rest day pays its five prayers and not the bonus — 310, no crown")
    }

    /// Nobody reaching the target is an ordinary week, not an empty card.
    func testNoCrownWhenNobodyReachedTheTarget() throws {
        let posts: [RemotePost] = [post(amina, .fajr, week[0]), post(amina, .dhuhr, week[0])]
        let recap = try XCTUnwrap(AppState.circleRecap(mode: .real, mirror: mirror(posts: posts),
                                                       weekDayKeys: week, now: asOf,
                                                       you: youEntry(logs: [log(.fajr, week[1])])))
        XCTAssertNil(recap.crownHolderID)
        XCTAssertNil(recap.crownHolder)
        XCTAssertNotNil(recap.bestDay, "the week still had a best day")
    }

    /// §3: dhikr/deeds count on the scoreboard as an opaque weekly total — and
    /// the recap's standings are the scoreboard's numbers. The crown race stays
    /// prayer-only, which is what keeps a big dhikr week from buying one.
    func testRecoveryXPCountsInTheStandingsButNotInTheRace() throws {
        let recap = try scenarioRecap()
        let his = try XCTUnwrap(recap.standings.first { $0.member.name == "Yusuf" })
        XCTAssertEqual(his.xp, 90 + 200)
        XCTAssertNotEqual(recap.crownHolderID, his.member.id)
    }

    func testStandingsAreSortedHighestFirst() throws {
        let recap = try scenarioRecap()
        let scores: [Int] = recap.standings.map(\.xp)
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertEqual(recap.standings.count, 3)
    }

    // MARK: - Solo and demo have no circle page

    /// Demo mode has no mirror — only a deterministic function of a buddy's
    /// name — so crowning a simulated friend would be a trophy for nobody.
    /// v3.9's Journey renders exactly as it always did.
    func testDemoModeHasNoCirclePage() {
        XCTAssertNil(AppState.circleRecap(mode: .demo, mirror: scenarioMirror(),
                                          weekDayKeys: week, now: asOf, you: scenarioYou()))
    }

    func testASoloAccountHasNoCirclePage() {
        XCTAssertNil(AppState.circleRecap(mode: .real, mirror: .empty,
                                          weekDayKeys: week, now: asOf, you: scenarioYou()))
    }

    /// Signed in, in a circle, but the only member so far. A race of one is not
    /// a race — the same rule the live crown follows.
    func testACircleOfJustYouHasNoCirclePage() {
        let alone = CircleSnapshot(circle: RemoteCircle(id: circleID, code: "ABC234",
                                                        name: "Test", emoji: "🤝"),
                                   me: me,
                                   members: [member(me, joinedHoursIn: 0)])
        XCTAssertNil(AppState.circleRecap(mode: .real, mirror: alone,
                                          weekDayKeys: week, now: asOf, you: scenarioYou()))
    }

    /// A circle where nobody logged anything all week gets no card either —
    /// the same rule the personal recap follows for an empty week.
    func testAWeekWithNoLogsAtAllHasNoCirclePage() {
        XCTAssertNil(AppState.circleRecap(mode: .real, mirror: mirror(posts: []),
                                          weekDayKeys: week, now: asOf,
                                          you: youEntry(logs: [])))
    }

    // MARK: - A week the circle was not there for

    /// v4 Phase D FIX: membership was never compared to the recapped week.
    ///
    /// Create a circle on Tuesday and two friends join. The mirror holds only
    /// the current week's backfill (§2), so for LAST week every buddy scores 0
    /// while your own row comes from full local logs — `anyLogs` is true because
    /// of YOUR logs, the race crosses the target on your logs alone, and the
    /// card said "You wore the crown 👑 / First in the circle to the weekly
    /// target" for a week your friends were not in the circle.
    func testAWeekTheCircleDidNotExistForHasNoCirclePage() {
        let joinedAfterwards: [RemoteMember] = [
            RemoteMember(circleID: circleID, userID: me, joinedAt: date(2026, 6, 15, 9)),
            RemoteMember(circleID: circleID, userID: amina, joinedAt: date(2026, 6, 15, 10))]
        XCTAssertNil(AppState.circleRecap(mode: .real,
                                          mirror: mirror(posts: [], members: joinedAfterwards),
                                          weekDayKeys: week, now: asOf,
                                          you: youEntry(logs: myFullDay(week[0]))))
    }

    /// The same question about YOU: a circle you joined this week has no last
    /// week to recap, however full your own logs are.
    func testAWeekBeforeYouJoinedHasNoCirclePage() {
        let members: [RemoteMember] = [
            RemoteMember(circleID: circleID, userID: me, joinedAt: date(2026, 6, 15, 9)),
            RemoteMember(circleID: circleID, userID: amina, joinedAt: date(2026, 6, 1))]
        XCTAssertNil(AppState.circleRecap(mode: .real,
                                          mirror: mirror(posts: fullDay(amina, week[0]),
                                                         members: members),
                                          weekDayKeys: week, now: asOf,
                                          you: youEntry(logs: myFullDay(week[1]))))
    }

    /// Joining mid-week DOES count — the join backfill publishes that week's
    /// prayers (§2), so a member who joined on the Sunday really did have a
    /// week in the circle.
    func testAMemberWhoJoinedDuringTheWeekIsStillInTheRecap() throws {
        let members: [RemoteMember] = [
            RemoteMember(circleID: circleID, userID: me, joinedAt: date(2026, 6, 1)),
            RemoteMember(circleID: circleID, userID: amina, joinedAt: date(2026, 6, 14, 20))]
        let recap = try XCTUnwrap(AppState.circleRecap(
            mode: .real,
            mirror: mirror(posts: fullDay(amina, week[6]), members: members),
            weekDayKeys: week, now: asOf,
            you: youEntry(logs: myFullDay(week[0]))))
        XCTAssertEqual(recap.standings.count, 2)
    }

    // MARK: - Reported photos (§4)

    private func photoPost(_ path: String) -> RemotePost {
        post(amina, .fajr, week[0], photoPath: path)
    }

    private func book() -> PhotoReports {
        let reports = PhotoReports(persists: false)
        let reporter: UUID = me
        reports.currentUserID = { reporter }
        return reports
    }

    /// The heart of §4: reporting hides the photo HERE, immediately, and the
    /// hide outlives the mirror. A pull replaces `circle.json` wholesale — the
    /// post comes back with its `photo_path` intact, exactly as the server
    /// still has it — and the reporter still never sees the picture.
    func testAReportedPhotoStaysHiddenAcrossASnapshotReload() {
        let path = "\(circleID.uuidString)/\(amina.uuidString)/photo-1.jpg"
        let reported: RemotePost = photoPost(path)
        let reports = book()

        let before = RemoteCircleDataSource(snapshot: mirror(posts: [reported]))
        XCTAssertEqual(before.photoPath(forMember: amina.uuidString, prayer: .fajr,
                                        dayKey: week[0], asOf: .distantFuture), path)
        XCTAssertEqual(reports.visiblePath(path), path)

        reports.hide(reported)
        XCTAssertTrue(reports.isHidden(path))
        XCTAssertNil(reports.visiblePath(path))

        // A fresh sync: a brand-new snapshot value, same row, same path.
        let after = RemoteCircleDataSource(snapshot: mirror(posts: [photoPost(path)]))
        XCTAssertEqual(after.photoPath(forMember: amina.uuidString, prayer: .fajr,
                                       dayKey: week[0], asOf: .distantFuture), path,
                       "the mirror is untouched — the hide is not an edit to it")
        XCTAssertNil(reports.visiblePath(path), "and the photo is still not drawn")
    }

    /// Reporting names a post, not a member: the buddy's OTHER photos are still
    /// theirs to show. Leaving the circle remains the block mechanism (§4).
    func testHidingOnePhotoLeavesTheirOtherPhotosAlone() {
        let reports = book()
        let hidden = "\(circleID.uuidString)/\(amina.uuidString)/one.jpg"
        let kept = "\(circleID.uuidString)/\(amina.uuidString)/two.jpg"
        reports.hide(photoPost(hidden))
        XCTAssertNil(reports.visiblePath(hidden))
        XCTAssertEqual(reports.visiblePath(kept), kept)
    }

    func testAPostWithNoPhotoHidesNothingAndStillFilesAReport() {
        let reports = book()
        let noPhoto: RemotePost = post(amina, .asr, week[1])
        reports.hide(noPhoto)
        XCTAssertTrue(reports.hiddenPaths.isEmpty)
        XCTAssertEqual(reports.pendingCount, 1)
    }

    /// One report per (reporter, post) — the rule the unique index enforces,
    /// applied locally so a double-tap never queues a second insert.
    func testReportingTheSamePhotoTwiceQueuesOneReport() {
        let reports = book()
        let path = "\(circleID.uuidString)/\(amina.uuidString)/three.jpg"
        let target: RemotePost = photoPost(path)
        reports.hide(target)
        reports.hide(target)
        XCTAssertEqual(reports.pendingCount, 1)
        XCTAssertNil(reports.visiblePath(path))
    }

    /// No session, no `reporter_id`, no insert the policy would accept — but
    /// the hide is the half the person can feel, so it still happens.
    func testWithoutASessionThePhotoIsStillHiddenAndNothingIsQueued() {
        let reports = PhotoReports(persists: false)
        reports.currentUserID = { nil }
        let path = "\(circleID.uuidString)/\(amina.uuidString)/four.jpg"
        reports.hide(photoPost(path))
        XCTAssertNil(reports.visiblePath(path))
        XCTAssertEqual(reports.pendingCount, 0)
    }

    func testVisiblePathTreatsAnEmptyOrMissingPathAsNoPhoto() {
        let reports = book()
        XCTAssertNil(reports.visiblePath(nil))
        XCTAssertNil(reports.visiblePath(""))
    }

    // MARK: - The report on the wire

    /// The grant is
    /// `insert (id, reporter_id, post_id, circle_id, reason, reported_user_id,
    /// photo_path)` and nothing else, so an eighth key is a `42501` refusal for
    /// every report this device ever files. Asserted for BOTH coders — the
    /// mirror's and the wire's — because a DTO whose `encode(to:)` served two
    /// jobs and quietly differed between them has already cost this project two
    /// CI rounds.
    func testReportEncodesExactlyTheGrantedColumns() throws {
        let report = RemoteReport(reporterID: me, postID: UUID(), circleID: circleID,
                                  reportedUserID: amina, photoPath: "a/b/c.jpg",
                                  reason: "Not a prayer photo")
        for persisting in [true, false] {
            let encoder = JSONEncoder()
            encoder.userInfo[.persistingMirror] = persisting
            let data: Data = try encoder.encode(report)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data)
                                        as? [String: Any])
            XCTAssertEqual(Set(object.keys),
                           ["id", "reporter_id", "post_id", "circle_id",
                            "reported_user_id", "photo_path", "reason"])
        }
    }

    /// A report with no words is still actionable — a human looks at the photo
    /// — and `reason` is nullable, so the key is simply absent.
    func testAReportWithNoReasonOmitsTheColumn() throws {
        let report = RemoteReport(reporterID: me, postID: UUID(), circleID: circleID,
                                  reportedUserID: amina)
        let data: Data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(object.keys.contains("reason"))
        XCTAssertEqual(Set(object.keys),
                       ["id", "reporter_id", "post_id", "circle_id", "reported_user_id"])
    }

    /// v4 Phase D FIX: the report has to say WHO it is about.
    ///
    /// Every foreign key on `reports` is `ON DELETE SET NULL` so that deleting
    /// the photo cannot retract the complaint — but undo is an ordinary button
    /// for the whole schedule day, and it nulled `post_id`, leaving triage with
    /// a timestamp, a reason and nobody to answer for it. A member could defeat
    /// every report against them by tapping undo.
    func testAQueuedReportNamesWhoWasReportedAndWhere() throws {
        let reports = book()
        let path = "\(circleID.uuidString)/\(amina.uuidString)/five.jpg"
        reports.hide(photoPost(path))
        let filed = try XCTUnwrap(reports.pendingReports.first)
        XCTAssertEqual(filed.reportedUserID, amina)
        XCTAssertEqual(filed.photoPath, path)
        XCTAssertEqual(filed.reporterID, me)
    }

    // MARK: - A report is not thrown away by a bad afternoon

    /// v4 Phase D FIX: settling used to be `!CircleError.from(error).isOffline`,
    /// so ANY failure that was not a `URLError` — a 500, a paused free-tier
    /// project, a body that would not decode — silently discarded the
    /// complaint, after the UI had said "we'll… send it to us to look at".
    func testATransientServerFailureKeepsTheReportQueued() {
        XCTAssertEqual(PhotoReports.outcome(for: ReportFailure()), .failed)
    }

    /// Offline costs nothing at all: a fortnight in airplane mode must not
    /// spend one of the bounded attempts.
    func testOfflineIsNotAnAttempt() {
        XCTAssertEqual(PhotoReports.outcome(for: URLError(.notConnectedToInternet)),
                       .offline)
    }

    /// A refusal the server actually uttered will be uttered again forever —
    /// a report against a circle this device has left can never be accepted.
    func testARefusalIsFinal() {
        XCTAssertEqual(PhotoReports.outcome(for: CircleError.notAllowed), .refused)
        XCTAssertEqual(PhotoReports.outcome(for: CircleError.notInACircle), .refused)
    }

    func testReportRoundTripsThroughTheOnDiskBook() throws {
        let report = RemoteReport(reporterID: me, postID: UUID(), circleID: circleID,
                                  reportedUserID: amina, photoPath: "a/b/c.jpg",
                                  reason: "why")
        let original = ReportBook(hiddenPaths: ["a/b/c.jpg"], pending: [report])
        let encoder = JSONEncoder()
        encoder.userInfo[.persistingMirror] = true
        let decoder = JSONDecoder()
        decoder.userInfo[.persistingMirror] = true
        let restored: ReportBook = try decoder.decode(ReportBook.self,
                                                      from: try encoder.encode(original))
        XCTAssertEqual(restored, original)
    }

    /// The tolerant decoder every persisted model in this app has: a book
    /// written by an older build (or half-written by a crash) loads as far as
    /// it can rather than throwing away a hidden photo.
    func testAPartialBookOnDiskStillLoads() throws {
        let json = Data(#"{"hiddenPaths":["x/y/z.jpg"]}"#.utf8)
        let book = try JSONDecoder().decode(ReportBook.self, from: json)
        XCTAssertEqual(book.hiddenPaths, ["x/y/z.jpg"])
        XCTAssertTrue(book.pending.isEmpty)
    }
}
