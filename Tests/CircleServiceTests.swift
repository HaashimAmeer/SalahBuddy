import XCTest
@testable import SalahBuddy

/// The signed-in user, in a box the test can empty. `CircleService` asks a
/// closure who is signed in precisely so a test can answer without an auth
/// stack, a session or a network.
private final class SessionBox {
    var userID: UUID?
    init(userID: UUID?) { self.userID = userID }
}

/// Stands in for `AppState`. It records what the service handed over — which
/// is also the point of the assertion in `testLeavingKeepsLocalHistory`: the
/// host protocol has exactly two methods, and neither of them can reach the
/// logs this stub is holding.
@MainActor
private final class StubHost: CircleServiceHost {
    /// The two calls in the order they arrived. Order matters for entering a
    /// circle: the mode flip is what pins the developer clock, and the mirror
    /// is stamped from that clock.
    enum Event: Equatable {
        case snapshot
        case mode(CircleMode)
    }

    var snapshots: [CircleSnapshot] = []
    var modes: [CircleMode] = []
    var events: [Event] = []
    /// Local history, standing still.
    var logs: [PrayerLog] = []

    func applyCircleSnapshot(_ snapshot: CircleSnapshot) {
        snapshots.append(snapshot)
        events.append(.snapshot)
    }

    func setCircleMode(_ mode: CircleMode) {
        modes.append(mode)
        events.append(.mode(mode))
    }
}

/// v4 Phase B3: `CircleService`, without the network.
///
/// Everything under test here is either a pure function (the join-code
/// normaliser, the mirror transitions, the wire decoder) or a local transition
/// that create/join/leave apply once the server has already said yes. The
/// service is built with `persists: false`, so no test touches the app's
/// Documents directory either.
@MainActor
final class CircleServiceTests: XCTestCase {

    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let friend = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let postID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private let monday = "2026-06-08"

    // MARK: - Fixtures

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    /// A UTC instant built from components, so nothing here depends on the
    /// formatter it is meant to be checking.
    private func utc(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    private func circle(name: String = "The Nine", emoji: String = "🌙") -> RemoteCircle {
        RemoteCircle(id: circleID, code: "ABC234", name: name, emoji: emoji, createdBy: me)
    }

    /// A mirror with a circle, a friend and a week of somebody's posts in it —
    /// the thing leaving has to clear.
    private func populatedSnapshot() -> CircleSnapshot {
        let members: [RemoteMember] = [
            RemoteMember(circleID: circleID, userID: me, joinedAt: stamp(0)),
            RemoteMember(circleID: circleID, userID: friend, joinedAt: stamp(60))
        ]
        let profiles: [RemoteProfile] = [
            RemoteProfile(id: me, name: "Haashim", avatarEmoji: "😄"),
            RemoteProfile(id: friend, name: "Mina", avatarEmoji: "🌸")
        ]
        let posts: [RemotePost] = [
            RemotePost(id: postID, userID: friend, circleID: circleID, dayKey: monday,
                       prayer: .dhuhr, tier: .onTime, loggedAt: stamp(120))
        ]
        return CircleSnapshot(circle: circle(), me: me, profiles: profiles,
                              members: members, posts: posts,
                              excusedDays: [RemoteExcusedDay(userID: friend, circleID: circleID,
                                                             dayKey: monday)],
                              recoveryWeeks: [RemoteRecoveryWeek(userID: friend, circleID: circleID,
                                                                 weekKey: "2026-W24", xp: 30)],
                              lastSyncedAt: stamp(200))
    }

    private func filledOutbox() -> CircleOutbox {
        var outbox = CircleOutbox.empty
        let post = RemotePost(id: postID, userID: me, circleID: circleID, dayKey: monday,
                              prayer: .fajr, tier: .onTime, loggedAt: stamp(0))
        outbox.enqueue(.upsertPost(post), at: stamp(0))
        outbox.enqueue(.setExcused(dayKey: monday, excused: true), at: stamp(1))
        return outbox
    }

    /// A service with no disk and no network, plus the host and session box the
    /// test can inspect.
    private func makeService(snapshot: CircleSnapshot = .empty,
                             outbox: CircleOutbox = .empty,
                             signedInAs user: UUID?)
        -> (service: CircleService, host: StubHost, session: SessionBox) {
        let session = SessionBox(userID: user)
        let host = StubHost()
        let service = CircleService(snapshot: snapshot, outbox: outbox, persists: false,
                                    currentUserID: { session.userID })
        service.host = host
        return (service, host, session)
    }

    // MARK: - Join-code normaliser

    func testNormaliserUppercasesAndStripsSeparators() {
        XCTAssertEqual(CircleService.normalizedJoinCode("abc234"), "ABC234")
        XCTAssertEqual(CircleService.normalizedJoinCode("ABC-234"), "ABC234")
        XCTAssertEqual(CircleService.normalizedJoinCode("  abc 234  "), "ABC234")
        XCTAssertEqual(CircleService.normalizedJoinCode("a-b-c-2-3-4"), "ABC234")
        XCTAssertEqual(CircleService.normalizedJoinCode("abc\n234"), "ABC234")
        // An autocorrected en dash is still a dash to the person who typed it.
        XCTAssertEqual(CircleService.normalizedJoinCode("abc\u{2013}234"), "ABC234")
        XCTAssertEqual(CircleService.normalizedJoinCode("ABC234"), "ABC234")
    }

    /// I/O/0/1 are absent from the invite alphabet because they are the
    /// characters that get misread. A code containing one is a rejection, never
    /// a silent "correction" into somebody else's circle.
    func testNormaliserRejectsTheAmbiguousCharacters() {
        XCTAssertNil(CircleService.normalizedJoinCode("ABC23I"))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC23O"))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC230"))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC231"))
        XCTAssertNil(CircleService.normalizedJoinCode("abc23i"))
        // And anything else off the alphabet.
        XCTAssertNil(CircleService.normalizedJoinCode("ABC23!"))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC23🌙"))
    }

    func testNormaliserRejectsTheWrongLength() {
        XCTAssertNil(CircleService.normalizedJoinCode(""))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC23"))
        XCTAssertNil(CircleService.normalizedJoinCode("ABC2345"))
        XCTAssertNil(CircleService.normalizedJoinCode("------"))
        XCTAssertNil(CircleService.normalizedJoinCode("   "))
    }

    func testCodeAlphabetMatchesTheMigration() {
        XCTAssertEqual(CircleService.codeAlphabet, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        XCTAssertEqual(CircleService.codeLength, 6)
        for character in "IO01" {
            XCTAssertFalse(CircleService.codeAlphabet.contains(character),
                           "\(character) must not be in the invite alphabet")
        }
    }

    /// The field sanitiser drops what it cannot use instead of failing the
    /// string — a text field that refuses a keystroke feels broken.
    func testSanitizedInputDropsRatherThanRejects() {
        XCTAssertEqual(CircleService.sanitizedCodeInput("ab*c-2 34"), "ABC234")
        XCTAssertEqual(CircleService.sanitizedCodeInput("abc"), "ABC")
        XCTAssertEqual(CircleService.sanitizedCodeInput("ABC234ZZZ"), "ABC234")
        XCTAssertEqual(CircleService.sanitizedCodeInput("i0o1"), "")
    }

    // MARK: - Mirror transitions

    func testEnteringACircleMirrorsOnlyYou() throws {
        let entered: CircleSnapshot = CircleService.mirror(entering: circle(), me: me,
                                                           now: stamp(0))
        XCTAssertTrue(entered.hasCircle)
        XCTAssertEqual(entered.circle?.id, circleID)
        XCTAssertEqual(entered.me, me)
        XCTAssertEqual(entered.members.count, 1)
        let mine: RemoteMember = try XCTUnwrap(entered.members.first)
        XCTAssertEqual(mine.userID, me)
        XCTAssertEqual(mine.joinedAt, stamp(0))
        // You are not your own buddy; the roster fills in on the first pull.
        XCTAssertTrue(entered.buddyMembers.isEmpty)
        XCTAssertTrue(entered.posts.isEmpty)
        XCTAssertTrue(entered.profiles.isEmpty)
        XCTAssertEqual(entered.remainingSlots, RemoteCircle.maxMembers - 1)
    }

    func testLeavingKeepsOnlyTheSignedInIdentity() {
        let left: CircleSnapshot = CircleService.mirror(leaving: populatedSnapshot())
        XCTAssertFalse(left.hasCircle)
        XCTAssertNil(left.circle)
        XCTAssertTrue(left.members.isEmpty)
        XCTAssertTrue(left.profiles.isEmpty)
        XCTAssertTrue(left.posts.isEmpty)
        XCTAssertTrue(left.excusedDays.isEmpty)
        XCTAssertTrue(left.recoveryWeeks.isEmpty)
        XCTAssertTrue(left.challenges.isEmpty)
        XCTAssertTrue(left.buddyMembers.isEmpty)
        XCTAssertNil(left.lastSyncedAt)
        // Still signed in — `me` is what makes `isYou` decidable the moment you
        // join something else.
        XCTAssertEqual(left.me, me)
    }

    /// Entering a circle builds the mirror from scratch: a previous circle's
    /// posts and profiles must not survive into a new one.
    func testEnteringDropsThePreviousCircle() {
        let (service, _, _) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        let next = RemoteCircle(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                                code: "PQR789", name: "New Circle", emoji: "🕌", createdBy: me)
        service.applyEnteredCircle(next, me: me)
        XCTAssertEqual(service.snapshot.circle?.id, next.id)
        XCTAssertTrue(service.snapshot.posts.isEmpty)
        XCTAssertTrue(service.snapshot.profiles.isEmpty)
        XCTAssertTrue(service.snapshot.excusedDays.isEmpty)
        XCTAssertEqual(service.snapshot.members.map(\.userID), [me])
    }

    // MARK: - The mode switch

    /// `createCircle` and `joinCircle` both funnel through
    /// `applyEnteredCircle`, and `leaveCircle` through `applyLeftCircle` —
    /// those are the transitions, minus the RPC the server has already
    /// answered. Join then leave, and the mirror is empty again.
    func testJoinThenLeaveSwitchesModeAndEmptiesTheMirror() {
        let (service, host, _) = makeService(signedInAs: me)
        XCTAssertEqual(service.phase, .noCircle)

        service.applyEnteredCircle(circle(), me: me)
        XCTAssertEqual(service.phase, .inCircle)
        XCTAssertEqual(host.modes, [.real])
        XCTAssertTrue(service.snapshot.hasCircle)

        service.applyLeftCircle()
        XCTAssertEqual(service.phase, .noCircle)
        XCTAssertEqual(host.modes, [.real, .demo])
        XCTAssertFalse(service.snapshot.hasCircle)
        XCTAssertTrue(service.snapshot.members.isEmpty)
        XCTAssertTrue(service.snapshot.posts.isEmpty)
        // The host saw every transition, so `AppState` re-renders each time.
        XCTAssertEqual(host.snapshots.count, 2)
    }

    /// SPEC-V4 §2: leaving "returns to solo mode with all local history
    /// intact". The service cannot do otherwise — `CircleServiceHost` has no
    /// method that reaches a log, an XP total or a streak.
    func testLeavingKeepsLocalHistory() {
        let (service, host, _) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        host.logs = [PrayerLog(id: postID, prayer: .fajr, dayKey: monday,
                               loggedAt: stamp(0), tier: .onTime, xp: 30)]
        let before: [PrayerLog] = host.logs

        service.applyLeftCircle()

        XCTAssertEqual(host.logs, before)
        XCTAssertEqual(host.modes, [.demo])
        XCTAssertFalse(service.snapshot.hasCircle)
    }

    /// Writes owed to a circle you have left are meaningless — worse, replayed
    /// into whatever circle comes next they would post your prayers to
    /// strangers.
    func testLeavingClearsTheOutbox() {
        let (service, _, _) = makeService(snapshot: populatedSnapshot(),
                                          outbox: filledOutbox(), signedInAs: me)
        XCTAssertEqual(service.outbox.count, 2)

        service.applyLeftCircle()

        XCTAssertTrue(service.outbox.isEmpty)
        XCTAssertNil(service.outbox.peek)
    }

    // MARK: - Offline-safe public paths

    /// Signed out with a circle still mirrored, leaving is REFUSED rather than
    /// faked.
    ///
    /// This deliberately replaces the earlier
    /// `testLeaveWithoutASessionClearsLocallyWithoutTheNetwork`, which locked in
    /// the wrong behaviour: the `circle_members` row is still on the server, so
    /// a local-only clear keeps showing the circle a member who has gone, and
    /// the next sign-in's `pull()` re-applies the circle and flips the mode
    /// back to `.real`. That is exactly the lie `leaveCircle`'s own doc comment
    /// refuses to tell offline, and the state is reachable — a refresh token
    /// that expires clears the session while `circle.json` keeps the circle.
    func testLeaveWithoutASessionRefusesRatherThanFakingIt() async {
        let (service, host, _) = makeService(snapshot: populatedSnapshot(),
                                             outbox: filledOutbox(), signedInAs: nil)
        do {
            try await service.leaveCircle()
            XCTFail("Leaving with a mirrored circle and no session must not succeed")
        } catch {
            XCTAssertEqual(CircleError.from(error), CircleError.notSignedIn)
        }
        // Nothing was touched: the circle, the queue and the mode all stand.
        XCTAssertTrue(service.snapshot.hasCircle)
        XCTAssertEqual(service.outbox.count, 2)
        XCTAssertTrue(host.modes.isEmpty)
        XCTAssertEqual(service.lastError, CircleError.notSignedIn)
        XCTAssertEqual(service.phase, .signedOut)
    }

    /// No circle and no session is still a no-op, not a refusal — there is
    /// nothing to tell the server about, so clearing the mirror IS the whole
    /// operation.
    func testLeaveWithNoCircleAndNoSessionIsANoOp() async throws {
        let (service, host, _) = makeService(signedInAs: nil)
        try await service.leaveCircle()
        XCTAssertFalse(service.snapshot.hasCircle)
        XCTAssertEqual(host.modes, [.demo])
        XCTAssertNil(service.lastError)
    }

    func testLeaveWithNoCircleIsANoOp() async throws {
        let (service, host, _) = makeService(signedInAs: me)
        try await service.leaveCircle()
        XCTAssertFalse(service.snapshot.hasCircle)
        XCTAssertEqual(service.phase, .noCircle)
        XCTAssertEqual(host.modes, [.demo])
    }

    func testSignOutForgetsTheCircleButNotTheApp() async {
        let (service, host, session) = makeService(snapshot: populatedSnapshot(),
                                                   outbox: filledOutbox(), signedInAs: me)
        service.signOutHandler = { session.userID = nil }

        await service.signOutAndReset()

        XCTAssertNil(session.userID)
        XCTAssertFalse(service.snapshot.hasCircle)
        // The identity goes too: keeping a stale `me` would let the next
        // account inherit it.
        XCTAssertNil(service.snapshot.me)
        XCTAssertTrue(service.outbox.isEmpty)
        XCTAssertEqual(service.phase, .signedOut)
        XCTAssertEqual(host.modes, [.demo])
    }

    // MARK: - Entering: the clock is pinned before it is read

    /// SPEC-V4 §3: flipping to `.real` is what pins the developer clock to real
    /// time, and `mirror(entering:)` stamps your own `joinedAt` from
    /// `AppClock.now`. So the mode has to reach the host BEFORE the mirror is
    /// built — otherwise a developer who time-travelled in demo mode and then
    /// joined a real circle writes a fictional join time into `circle.json`,
    /// and both call sites end in `try? await pull()`, so a failed first pull
    /// leaves it there to mis-order the roster.
    func testEnteringFlipsTheModeBeforeStampingJoinedAt() {
        let (service, host, _) = makeService(signedInAs: me)
        service.applyEnteredCircle(circle(), me: me)
        XCTAssertEqual(host.events, [StubHost.Event.mode(.real), StubHost.Event.snapshot])
    }

    // MARK: - Staleness (an in-flight pull vs. sign-out / leave)

    /// `pull()` suspends three times and `signOutAndReset()` suspends once,
    /// both on the main actor, so they interleave. A pull that started before
    /// the sign-out must not commit what it read: doing so wrote the departing
    /// account's roster back over the emptied mirror and called
    /// `setCircleMode(.real)`, leaving the app signed out inside a phantom
    /// circle that survived relaunch. The generation is what `pull()` re-checks.
    func testSignOutInvalidatesAnInFlightPull() async {
        let (service, _, session) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        let generation: Int = service.identityGeneration
        XCTAssertTrue(service.isCurrent(generation, me))

        service.signOutHandler = { session.userID = nil }
        await service.signOutAndReset()

        XCTAssertFalse(service.isCurrent(generation, me))
    }

    /// The same guard, the other cause: leaving on this device while a pull is
    /// still resolving.
    func testLeavingInvalidatesAnInFlightPull() {
        let (service, _, _) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        let generation: Int = service.identityGeneration
        service.applyLeftCircle()
        XCTAssertFalse(service.isCurrent(generation, me))
    }

    /// And the third: entering a circle while a pull against the previous one
    /// is still resolving — its rows belong to a mirror that no longer exists.
    func testEnteringACircleInvalidatesAnInFlightPull() {
        let (service, _, _) = makeService(signedInAs: me)
        let generation: Int = service.identityGeneration
        service.applyEnteredCircle(circle(), me: me)
        XCTAssertFalse(service.isCurrent(generation, me))
    }

    /// A quiet refresh must NOT look stale — the guard has to be inert when
    /// nothing has happened, or every pull would silently refuse to commit.
    func testNothingHappeningLeavesAPullCurrent() {
        let (service, _, _) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        let generation: Int = service.identityGeneration
        XCTAssertTrue(service.isCurrent(generation, me))
        XCTAssertFalse(service.isCurrent(generation, friend))
    }

    // MARK: - Phase

    func testPhaseTracksSignInAndMembership() {
        let (signedOut, _, _) = makeService(snapshot: populatedSnapshot(), signedInAs: nil)
        XCTAssertEqual(signedOut.phase, .signedOut)

        let (soloAccount, _, _) = makeService(signedInAs: me)
        XCTAssertEqual(soloAccount.phase, .noCircle)

        let (member, _, _) = makeService(snapshot: populatedSnapshot(), signedInAs: me)
        XCTAssertEqual(member.phase, .inCircle)
    }

    // MARK: - Wire decoding

    private func circleJSON(createdAt: String) -> String {
        """
        {"id":"33333333-3333-3333-3333-333333333333","code":"ABC234",\
        "name":"The Nine","emoji":"🌙",\
        "created_by":"11111111-1111-1111-1111-111111111111",\
        "created_at":"\(createdAt)"}
        """
    }

    /// The RPCs `return public.circles`, which PostgREST renders as a bare
    /// object; a set-returning function would wrap it in an array. Both decode,
    /// so the client cannot be wrong about a server-side detail.
    func testDecodeCircleRowAcceptsAnObjectOrAnArray() throws {
        let object: Data = Data(circleJSON(createdAt: "2026-06-08T12:34:56+00:00").utf8)
        let fromObject: RemoteCircle = try CircleService.decodeCircleRow(from: object)
        XCTAssertEqual(fromObject.id, circleID)
        XCTAssertEqual(fromObject.code, "ABC234")
        XCTAssertEqual(fromObject.name, "The Nine")
        XCTAssertEqual(fromObject.emoji, "🌙")
        XCTAssertEqual(fromObject.createdBy, me)
        XCTAssertEqual(fromObject.createdAt, utc(2026, 6, 8, 12, 34, 56))

        let array: Data = Data("[\(circleJSON(createdAt: "2026-06-08T12:34:56Z"))]".utf8)
        let fromArray: RemoteCircle = try CircleService.decodeCircleRow(from: array)
        XCTAssertEqual(fromArray.id, circleID)
        XCTAssertEqual(fromArray.createdAt, utc(2026, 6, 8, 12, 34, 56))
    }

    /// PostgREST hands back `timestamptz` with fractional seconds only
    /// sometimes. Both parse, because a circle that fails to decode is a circle
    /// that fails to be created.
    func testWireDecoderHandlesFractionalSeconds() throws {
        let data: Data = Data(circleJSON(createdAt: "2026-06-08T12:34:56.789+00:00").utf8)
        let decoded: RemoteCircle = try CircleService.decodeCircleRow(from: data)
        let createdAt: Date = try XCTUnwrap(decoded.createdAt)
        let expected: Date = utc(2026, 6, 8, 12, 34, 56).addingTimeInterval(0.789)
        XCTAssertEqual(createdAt.timeIntervalSince1970, expected.timeIntervalSince1970,
                       accuracy: 0.002)
    }

    func testWireDecoderReadsSnakeCaseRows() throws {
        let json = """
        [{"circle_id":"33333333-3333-3333-3333-333333333333",\
        "user_id":"22222222-2222-2222-2222-222222222222",\
        "joined_at":"2026-06-08T12:34:56+00:00"}]
        """
        let members: [RemoteMember] = try CircleService.decode([RemoteMember].self,
                                                               from: Data(json.utf8))
        XCTAssertEqual(members.count, 1)
        let member: RemoteMember = try XCTUnwrap(members.first)
        XCTAssertEqual(member.circleID, circleID)
        XCTAssertEqual(member.userID, friend)
        XCTAssertEqual(member.joinedAt, utc(2026, 6, 8, 12, 34, 56))
    }

    func testDecodeCircleRowThrowsOnAnEmptyResult() {
        XCTAssertThrowsError(try CircleService.decodeCircleRow(from: Data("[]".utf8)))
    }
}
