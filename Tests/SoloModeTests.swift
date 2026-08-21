import XCTest
@testable import SalahBuddy

/// v3.9 "solo-first" core tests: the startedSolo migration + circle shaping,
/// group-challenge gating while the circle is empty (this closed a live XP
/// exploit), and the Journey weekly recap math. Everything here stays in the
/// pure layer — AppState is orchestration and isn't unit-tested elsewhere
/// either.
final class SoloModeTests: XCTestCase {

    private let cal = Calendar.current

    /// Mon–Sun dayKeys of a real week (2026-06-08 is a Monday).
    private let week = ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11",
                        "2026-06-12", "2026-06-13", "2026-06-14"]

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    private func log(_ prayer: Prayer, _ tier: LogTier, dayKey: String,
                     loggedAt: Date = Date(timeIntervalSince1970: 0),
                     photo: String? = nil) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey, loggedAt: loggedAt,
                  tier: tier, xp: tier.xp, photoFilename: photo)
    }

    private func fullDay(dayKey: String, tier: LogTier = .onTime) -> [PrayerLog] {
        Prayer.allCases.map { log($0, tier, dayKey: dayKey) }
    }

    private func member(_ id: String, isYou: Bool = false) -> CircleMember {
        CircleMember(id: id, name: id, emoji: "🙂", isYou: isYou)
    }

    private func context(myLogs: [PrayerLog] = [],
                         memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = [],
                         completions: [String: Date] = [:],
                         customChallenges: [CustomChallenge] = [],
                         hasCircle: Bool = true,
                         groupAwardsFrozen: Bool = false) -> ChallengeEngine.Context {
        ChallengeEngine.Context(myLogs: myLogs, memberWeekLogs: memberWeekLogs,
                                todayKey: "d07",
                                recentDayKeys: (1...7).map { String(format: "d%02d", $0) },
                                weekDayKeys: ["d01", "d02", "d03", "d04", "d05", "d06", "d07"],
                                weekKey: "2026-W24", hardestPrayer: nil,
                                completions: completions, customChallenges: customChallenges,
                                hasCircle: hasCircle, groupAwardsFrozen: groupAwardsFrozen)
    }

    // MARK: - startedSolo migration

    func testV38ProfileWithoutStartedSoloKeepsItsCircle() throws {
        // A v3.8 profile has the circle fields but no startedSolo → false, and
        // the 8-buddy demo circle it's been living with is untouched.
        let json = """
        {"name":"H","totalXP":900,"streak":3,"longestStreak":5,"streakFreezes":1,
         "earnedBadges":{},"perfectDayCount":2,"joinedAt":"2026-05-01T12:00:00Z",
         "excusedDayKeys":[],"challengeCompletions":{},
         "removedBuddyNames":[],"invitedBuddyNames":["Amira"]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(UserProfile.self, from: json)

        XCTAssertFalse(profile.startedSolo, "pre-v3.9 saves default to the legacy circle")
        XCTAssertNil(profile.groupAwardsFrozenWeek, "no removal on record → nothing frozen")
        let circle = BuddySimulator.activeBuddies(removed: profile.removedBuddyNames,
                                                  invited: profile.invitedBuddyNames,
                                                  startedSolo: profile.startedSolo)
        XCTAssertEqual(circle.count, 9, "the base 8 plus the accepted invite")
        XCTAssertTrue(circle.contains { $0.name == "Amira" })
    }

    func testStartedSoloDefaultsAndRoundTrip() throws {
        // Memberwise default is false — every existing construction site keeps
        // the legacy circle...
        let legacy = UserProfile(name: "H", totalXP: 0, streak: 0, longestStreak: 0,
                                 streakFreezes: 0, lastStreakDayKey: nil,
                                 lastReconciledDayKey: nil, earnedBadges: [:],
                                 perfectDayCount: 0, joinedAt: date(2026, 6, 1))
        XCTAssertFalse(legacy.startedSolo)
        // ...but a brand-new account starts solo whether or not onboarding has
        // written the flag yet.
        XCTAssertTrue(UserProfile.fresh(now: date(2026, 6, 1)).startedSolo)

        XCTAssertNil(legacy.groupAwardsFrozenWeek)

        var solo = legacy
        solo.startedSolo = true
        solo.groupAwardsFrozenWeek = "2026-W24"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(UserProfile.self, from: encoder.encode(solo))
        XCTAssertTrue(restored.startedSolo)
        XCTAssertEqual(restored.groupAwardsFrozenWeek, "2026-W24",
                       "the freeze survives a relaunch, so it can't be shaken off")
    }

    // MARK: - Circle shaping

    func testSoloCircleStartsEmptyAndGrowsFromTheFullRoster() {
        XCTAssertTrue(BuddySimulator.activeBuddies(removed: [], invited: [], startedSolo: true).isEmpty,
                      "solo accounts start with nobody")

        // Invites resolve against the WHOLE roster — base buddies included —
        // and come back in roster order.
        let circle = BuddySimulator.activeBuddies(removed: [], invited: ["Idris", "Mina"],
                                                  startedSolo: true)
        XCTAssertEqual(circle.map(\.name), ["Mina", "Idris"])

        // Removing a solo friend drops them again.
        XCTAssertEqual(BuddySimulator.activeBuddies(removed: ["Mina"], invited: ["Idris", "Mina"],
                                                    startedSolo: true).map(\.name), ["Idris"])

        // Same inputs, legacy account: base 8 (minus removals) plus pool invites.
        XCTAssertEqual(BuddySimulator.activeBuddies(removed: [], invited: ["Idris", "Mina"],
                                                    startedSolo: false).count, 9)
        XCTAssertEqual(BuddySimulator.activeBuddies(removed: ["Mina"], invited: [],
                                                    startedSolo: false).count, 7)
    }

    func testRosterCoversEveryInvitableFriend() {
        XCTAssertEqual(BuddySimulator.roster.count,
                       BuddySimulator.buddies.count + BuddySimulator.invitablePool.count)
        XCTAssertEqual(Set(BuddySimulator.roster.map(\.name)).count, BuddySimulator.roster.count,
                       "no duplicate names across base + pool")
        XCTAssertEqual(BuddySimulator.buddy(named: "Layla")?.emoji, "🌷")
        XCTAssertEqual(BuddySimulator.buddy(named: "Idris")?.emoji, "🪶")
        XCTAssertNil(BuddySimulator.buddy(named: "Nobody"))
        // Deeper than one circle can hold — maxFriends still caps at the
        // invite site (AppState.acceptInvite).
        XCTAssertEqual(BuddySimulator.maxFriends, 8)
        XCTAssertGreaterThan(BuddySimulator.roster.count, BuddySimulator.maxFriends)
    }

    func testARemovedBaseBuddyCanBeInvitedBackIntoALegacyCircle() {
        // A legacy user who removes all 8 lands in solo mode, so
        // AppState.invitableBuddies offers the WHOLE roster back (it keys off
        // the derived isSoloMode, not the persisted startedSolo flag).
        let allRemoved = BuddySimulator.buddies.map(\.name)
        XCTAssertTrue(BuddySimulator.activeBuddies(removed: allRemoved, invited: [],
                                                   startedSolo: false).isEmpty)
        XCTAssertEqual(BuddySimulator.roster.count, 11, "everyone is offerable again")

        // acceptInvite clears the name from removedBuddyNames as it records the
        // invite; the legacy branch then yields them again — exactly once (a
        // base buddy isn't in invitablePool, so `extras` can't duplicate them).
        let back = BuddySimulator.activeBuddies(removed: allRemoved.filter { $0 != "Mina" },
                                                invited: ["Mina"], startedSolo: false)
        XCTAssertEqual(back.map(\.name), ["Mina"])

        // A re-invited base buddy is in BOTH lists, so removing them again can't
        // just drop the invite — the base 8 would keep them (AppState.removeMember
        // records the removal for anyone still standing afterwards).
        XCTAssertEqual(BuddySimulator.activeBuddies(removed: allRemoved.filter { $0 != "Mina" },
                                                    invited: [], startedSolo: false).map(\.name),
                       ["Mina"], "dropping the invite alone does not remove a base buddy")
    }

    // MARK: - Group-challenge gating

    func testGroupChallengesHiddenAndUnawardedWithoutACircle() {
        let you = member("you", isYou: true)
        let isha = ["d05", "d06", "d07"].map { log(.isha, .prayed, dayKey: $0) }
        let custom = CustomChallenge(id: "custom-solo", prayer: .isha, days: 3,
                                     createdAt: date(2026, 6, 8))
        let solo = context(myLogs: isha, memberWeekLogs: [(you, isha)],
                           customChallenges: [custom], hasCircle: false)

        let visible = ChallengeEngine.progressList(solo).map(\.id)
        for id in ["isha3", "race300", "circleperfect", "custom-solo"] {
            XCTAssertFalse(visible.contains(id), "\(id) must not show while the circle is empty")
        }
        XCTAssertTrue(visible.contains("fullday"), "personal challenges are unchanged")
        XCTAssertTrue(visible.contains("fajr3"))
        XCTAssertTrue(ChallengeEngine.progressList(solo).allSatisfy { !$0.isGroup })
        XCTAssertTrue(ChallengeEngine.newlyCompleted(solo).allSatisfy { !$0.definition.isGroup })

        // A context that doesn't say otherwise still has a circle — v3.8 behavior.
        XCTAssertTrue(context().hasCircle)
        XCTAssertTrue(ChallengeEngine.progressList(context()).contains { $0.isGroup })
    }

    func testSoloIshaStreakNoLongerAutoAwards() {
        let def = ChallengeEngine.definition(id: "isha3")!
        let you = member("you", isYou: true)
        let isha = ["d05", "d06", "d07"].map { log(.isha, .prayed, dayKey: $0) }

        // The exploit: "everyone logged Isha" is trivially true over a
        // one-member circle, so isha3 completed itself and re-paid 50 XP every
        // week. The predicate still says yes...
        let solo = context(memberWeekLogs: [(you, isha)], hasCircle: false)
        XCTAssertTrue(ChallengeEngine.isCompletedNow(def, ctx: solo))
        // ...but isha3 is no longer an active definition, so nothing is awarded.
        XCTAssertFalse(ChallengeEngine.activeDefinitions(solo).contains { $0.id == "isha3" })
        XCTAssertFalse(ChallengeEngine.newlyCompleted(solo).map(\.key).contains("isha3|2026-W24"))

        // One real friend and the challenge is live again.
        let withCircle = context(memberWeekLogs: [(member("a"), isha), (you, isha)], hasCircle: true)
        XCTAssertEqual(ChallengeEngine.current(for: def, ctx: withCircle), 3)
        XCTAssertTrue(ChallengeEngine.newlyCompleted(withCircle).map(\.key).contains("isha3|2026-W24"))
    }

    func testSoloRaceAndCirclePerfectNotAwarded() {
        let you = member("you", isYou: true)
        let t0 = date(2026, 6, 8, 6, 0)
        // 10 onTime logs = 300 weekly XP — solo you'd crown yourself weekly.
        let burst = (0..<10).map { i in
            log(.dhuhr, .onTime, dayKey: "d0\(1 + i / 5)",
                loggedAt: t0.addingTimeInterval(Double(i) * 3600))
        }
        let soloRace = context(memberWeekLogs: [(you, burst)], hasCircle: false)
        XCTAssertEqual(ChallengeEngine.raceWinnerID(memberWeekLogs: [(you, burst)]), "you",
                       "the raw race still says you crossed first — you're the only runner")
        XCTAssertNil(ChallengeEngine.activeDefinitions(soloRace).first { $0.id == "race300" })
        XCTAssertFalse(ChallengeEngine.newlyCompleted(soloRace).map(\.key)
            .contains { $0.hasPrefix("race300") })

        // circleperfect's target collapses to 1 (just you) when solo — gone too.
        let full = Prayer.allCases.map { log($0, .onTime, dayKey: "d07") }
        let soloPerfect = context(memberWeekLogs: [(you, full)], hasCircle: false)
        XCTAssertNil(ChallengeEngine.activeDefinitions(soloPerfect).first { $0.id == "circleperfect" })

        // With one friend it's back, targeting every member.
        let withCircle = context(memberWeekLogs: [(member("a"), full), (you, full)], hasCircle: true)
        XCTAssertEqual(ChallengeEngine.activeDefinitions(withCircle)
            .first { $0.id == "circleperfect" }?.target, 2)
    }

    func testAShrunkCircleFreezesThisWeeksGroupAwards() {
        // Every group target is sized off the LIVE circle, and a removal is a
        // tap away from being undone (their week backfills on re-invite), so
        // shrink-then-restore used to farm isha3 + circleperfect + race300.
        // A removal now voids the week's group payouts.
        let you = member("you", isYou: true)
        let friend = member("buddy.Mina")
        let t0 = date(2026, 6, 8, 6, 0)
        var mine: [PrayerLog] = []
        var theirs: [PrayerLog] = []
        for (dayIndex, key) in ["d05", "d06", "d07"].enumerated() {
            for (prayerIndex, prayer) in Prayer.allCases.enumerated() {
                let at = t0.addingTimeInterval(Double(dayIndex * 24 + prayerIndex) * 3600)
                mine.append(log(prayer, .onTime, dayKey: key, loggedAt: at))
                // A hair later, so YOU are the one who crosses 300 first.
                theirs.append(log(prayer, .onTime, dayKey: key, loggedAt: at.addingTimeInterval(600)))
            }
        }
        let members = [(friend, theirs), (you, mine)]

        // Live circle: all three group challenges pay out.
        let live = context(myLogs: mine, memberWeekLogs: members)
        let liveKeys = ChallengeEngine.newlyCompleted(live).map(\.key)
        XCTAssertTrue(liveKeys.contains("isha3|2026-W24"))
        XCTAssertTrue(liveKeys.contains("circleperfect|2026-W24"))
        XCTAssertTrue(liveKeys.contains("race300|2026-W24"))

        // Same week after a removal: nothing group-shaped is awarded...
        let frozen = context(myLogs: mine, memberWeekLogs: members, groupAwardsFrozen: true)
        let frozenAwards = ChallengeEngine.newlyCompleted(frozen)
        XCTAssertTrue(frozenAwards.allSatisfy { !$0.definition.isGroup },
                      "a circle that shrank this week pays out no group challenge")
        // ...while personal challenges are untouched.
        XCTAssertTrue(frozenAwards.map(\.key).contains("fullday"))
        XCTAssertTrue(frozenAwards.map(\.key).contains("fajr3"))
        // The cards still render and still count — only the payout is withheld.
        XCTAssertEqual(ChallengeEngine.progressList(frozen).filter(\.isGroup).count,
                       ChallengeEngine.progressList(live).filter(\.isGroup).count)
    }

    // MARK: - Weekly recap

    func testWeeklyRecapNilWhenTheWeekHasNoLogsOfYours() {
        XCTAssertNil(GameEngine.weeklyRecap(logs: [], weekDayKeys: week))
        XCTAssertNil(GameEngine.weeklyRecap(logs: [], weekDayKeys: []))
        // Logs outside the week don't resurrect it.
        XCTAssertNil(GameEngine.weeklyRecap(logs: fullDay(dayKey: "2026-06-15"), weekDayKeys: week),
                     "next Monday belongs to the following week")
    }

    func testWeeklyRecapTotalsBestDayAndCompleteDays() {
        var logs = fullDay(dayKey: "2026-06-08", tier: .onTime)        // 150 + 25 perfect
        logs += fullDay(dayKey: "2026-06-10", tier: .prayed)           // 100 + 25 perfect
        logs += [log(.fajr, .onTime, dayKey: "2026-06-12"),            // 30
                 log(.isha, .qada, dayKey: "2026-06-12")]              // 5
        logs += fullDay(dayKey: "2026-06-15")                          // next week — ignored

        let recap = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week)!
        XCTAssertEqual(recap.weekStartDayKey, "2026-06-08")
        XCTAssertEqual(recap.weekEndDayKey, "2026-06-14")
        XCTAssertEqual(recap.prayersLogged, 12)
        XCTAssertEqual(recap.daysWithAllFive, 2)
        XCTAssertEqual(recap.totalXP, 175 + 125 + 35)
        XCTAssertEqual(recap.bestDay?.dayKey, "2026-06-08")
        XCTAssertEqual(recap.bestDay?.xp, 175)
        XCTAssertTrue(recap.photoFilenames.isEmpty, "no photos logged that week")
    }

    func testWeeklyRecapExcusedDayKeepsPrayersButDropsThePerfectBonus() {
        let logs = fullDay(dayKey: "2026-06-08", tier: .onTime)
        let recap = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week,
                                           excusedDayKeys: ["2026-06-08"])!
        XCTAssertEqual(recap.totalXP, 150)
        XCTAssertEqual(recap.daysWithAllFive, 1, "the prayers still happened")
        XCTAssertEqual(recap.bestDay?.xp, 150)
    }

    func testWeeklyRecapPhotoHighlightsAreCappedAndSpreadAcrossTheWeek() {
        var logs: [PrayerLog] = []
        for (dayIndex, key) in week.enumerated() {
            for (prayerIndex, prayer) in Prayer.allCases.enumerated() {
                logs.append(log(prayer, .onTime, dayKey: key,
                                loggedAt: date(2026, 6, 8 + dayIndex, 5 + prayerIndex),
                                photo: "\(key)-\(prayer.rawValue).jpg"))
            }
        }
        let recap = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week)!
        XCTAssertEqual(recap.photoFilenames.count, GameEngine.weeklyRecapPhotoCap)
        XCTAssertEqual(Set(recap.photoFilenames).count, GameEngine.weeklyRecapPhotoCap,
                       "no duplicate highlights")
        let days = Set(recap.photoFilenames.map { String($0.prefix(10)) })
        XCTAssertEqual(days.count, GameEngine.weeklyRecapPhotoCap,
                       "highlights span the week instead of clumping on one day")
        XCTAssertTrue(recap.photoFilenames.first!.hasPrefix("2026-06-08"))

        // Under the cap everything comes through, chronologically.
        let few = GameEngine.weeklyRecap(logs: Array(logs.prefix(3)), weekDayKeys: week)!
        XCTAssertEqual(few.photoFilenames,
                       ["2026-06-08-fajr.jpg", "2026-06-08-dhuhr.jpg", "2026-06-08-asr.jpg"])
    }

    func testWeeklyRecapDoesNotRepeatATravelCombinedPairsSharedPhoto() {
        // logCombined writes the lead AND its partner from one photo.
        let shared = "ab12.jpg"
        let logs = [log(.fajr, .onTime, dayKey: "2026-06-08",
                        loggedAt: date(2026, 6, 8, 5), photo: "mon.jpg"),
                    log(.dhuhr, .onTime, dayKey: "2026-06-09",
                        loggedAt: date(2026, 6, 9, 13), photo: shared),
                    log(.asr, .onTime, dayKey: "2026-06-09",
                        loggedAt: date(2026, 6, 9, 13), photo: shared)]
        let recap = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week)!
        XCTAssertEqual(recap.photoFilenames, ["mon.jpg", shared],
                       "the shared travel photo appears once")
    }

    func testASundayIshaLoggedAfterMidnightStillLandsInThatWeeksRecap() {
        // Why AppState.lastCompletedWeekRecap() defers on Monday morning: the
        // log carries SUNDAY's dayKey even though it happens after midnight, so
        // publishing the card at 00:20 shows a total that then changes at 00:45.
        var logs = fullDay(dayKey: "2026-06-08") + fullDay(dayKey: "2026-06-09")
            + fullDay(dayKey: "2026-06-10") + fullDay(dayKey: "2026-06-11")
        logs += Prayer.allCases.filter { $0 != .isha }
            .map { log($0, .onTime, dayKey: "2026-06-14", loggedAt: date(2026, 6, 14, 6)) }

        let atMidnight = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week)!
        XCTAssertEqual(atMidnight.daysWithAllFive, 4)

        // 00:45 Monday — Sunday's isha lands, still in its window.
        logs.append(log(.isha, .onTime, dayKey: "2026-06-14", loggedAt: date(2026, 6, 15, 0, 45)))
        let settled = GameEngine.weeklyRecap(logs: logs, weekDayKeys: week)!
        XCTAssertEqual(settled.daysWithAllFive, 5, "the after-midnight isha completes Sunday")
        XCTAssertEqual(settled.totalXP, atMidnight.totalXP + LogTier.onTime.xp + GameEngine.perfectDayBonus,
                       "…and moves the week's total, which is why the card waits")
    }

    func testPreviousCompletedWeekIsTheMondayThroughSundayBeforeThisOne() {
        // The arithmetic AppState.lastCompletedWeekRecap() runs: step one day
        // back from this week's Monday, then take that week's 7 dayKeys.
        let thisMonday = BuddySimulator.weekStart(for: date(2026, 6, 18, 9, 0))
        let previousDay = cal.date(byAdding: .day, value: -1, to: thisMonday)!
        XCTAssertEqual(BuddySimulator.weekDayKeys(for: previousDay), week)
        // Mid-week today doesn't leak the week in progress into the recap.
        XCTAssertFalse(BuddySimulator.weekDayKeys(for: previousDay).contains("2026-06-18"))
    }
}
