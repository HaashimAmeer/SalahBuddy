import Foundation
import XCTest
@testable import SalahBuddy

/// v5 §6 / §4 (P4) — the Lock Screen and the nudge.
///
/// The two surfaces P4 adds are both in a different process from everything
/// that can be tested, so the same trick P2 used applies here: the DECISIONS
/// live on this side of the fence and the extension is a renderer. What is
/// pinned below is every one of them.
///
/// - `LiveActivityPlanner` — the whole state machine (start, move, replace,
///   end), driven from the same `WidgetSnapshot` the home screen renders, so
///   the two surfaces cannot disagree about one window.
/// - `PrayerWindowAttributes` — the shape a Deno function builds by hand
///   (`_shared/liveactivity.ts`). ActivityKit decodes a pushed content state
///   with no reply of any kind: a mismatch is not an error, it is a push that
///   does nothing forever. The tolerance rules are therefore assertions, not
///   habits.
/// - `SharedSession` — §2's third tooth. The extension NEVER refreshes, so
///   every "is this token usable" answer has to be right, and the ambiguous
///   case has to fail towards the deep link.
/// - `NudgeRequest` / `markingNudged` — the request the extension sends and the
///   optimistic state §4 requires it to write before returning.
@MainActor
final class LiveActivityTests: XCTestCase {

    // MARK: - Fixtures

    private let opensAt = Date(timeIntervalSince1970: 1_756_000_000)
    private var endsAt: Date { opensAt.addingTimeInterval(2 * 3600) }

    private func snapshot(prayer: Prayer = .asr,
                          dayKey: String = "2026-08-24",
                          prayedCount: Int = 2,
                          memberCount: Int = 5,
                          youLogged: Bool = false,
                          posts: [WidgetSnapshot.Post] = [],
                          waiting: [WidgetSnapshot.Waiting] = [],
                          window: Bool = true) -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: opensAt,
            mode: .real,
            window: window ? WidgetSnapshot.Window(prayer: prayer, dayKey: dayKey,
                                                   opensAt: opensAt, endsAt: endsAt)
                           : nil,
            you: WidgetSnapshot.You(logged: youLogged, streak: 7),
            circle: WidgetSnapshot.Circle(prayedCount: prayedCount,
                                          memberCount: memberCount,
                                          posts: posts, waiting: waiting))
    }

    private func post(_ name: String, _ emoji: String, _ tier: LogTier,
                      minutesAgo: Int) -> WidgetSnapshot.Post {
        WidgetSnapshot.Post(name: name, emoji: emoji, tier: tier,
                            loggedAt: opensAt.addingTimeInterval(Double(-minutesAgo) * 60),
                            thumb: nil)
    }

    private func waiting(_ id: String, _ name: String, nudged: Bool = false)
        -> WidgetSnapshot.Waiting {
        WidgetSnapshot.Waiting(userID: id, name: name, emoji: "🎧",
                               nudgedThisWindow: nudged)
    }

    private func running(_ snapshot: WidgetSnapshot, at now: Date)
        -> LiveActivityPlanner.Running? {
        guard let attributes = LiveActivityPlanner.attributes(for: snapshot) else { return nil }
        return LiveActivityPlanner.Running(
            attributes: attributes,
            state: LiveActivityPlanner.contentState(for: snapshot, now: now))
    }

    // MARK: - Which window is live

    func testActivityRunsOnlyWhileTheWindowIsOpen() {
        let file = snapshot()
        // The file names the NEXT window when nothing is open — the tile has to
        // say "Asr, opens 3:12 PM" — and a Live Activity for a prayer whose
        // time has not come in is a countdown to nothing for six hours.
        XCTAssertFalse(LiveActivityPlanner.shouldRun(snapshot: file,
                                                     now: opensAt.addingTimeInterval(-60)))
        XCTAssertTrue(LiveActivityPlanner.shouldRun(snapshot: file, now: opensAt))
        XCTAssertTrue(LiveActivityPlanner.shouldRun(snapshot: file,
                                                    now: endsAt.addingTimeInterval(-1)))
        // §6: "ending itself when the window closes". The end is exclusive.
        XCTAssertFalse(LiveActivityPlanner.shouldRun(snapshot: file, now: endsAt))
        XCTAssertFalse(LiveActivityPlanner.shouldRun(snapshot: nil, now: opensAt))
    }

    func testStartsWhenTheWindowOpensAndNothingIsRunning() {
        let file = snapshot(posts: [post("Mina", "🌸", .onTime, minutesAgo: 5)])
        let plan = LiveActivityPlanner.plan(snapshot: file, running: nil,
                                            now: opensAt.addingTimeInterval(600))
        guard case .start(let attributes, let state) = plan else {
            return XCTFail("expected a start, got \(plan)")
        }
        XCTAssertEqual(attributes.prayerRaw, Prayer.asr.rawValue)
        XCTAssertEqual(attributes.dayKey, "2026-08-24")
        XCTAssertEqual(attributes.endsAtDate.timeIntervalSince1970,
                       endsAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(state.prayedCount, 2)
        XCTAssertEqual(state.memberCount, 5)
    }

    func testNothingRunningAndNothingToRunIsNotAnEnd() {
        // Ending an activity that is not there is an await into ActivityKit on
        // every publish — and `publishWidgetSnapshot` is called on every state
        // change, which is most taps in the app.
        let closed = snapshot()
        XCTAssertEqual(LiveActivityPlanner.plan(snapshot: closed, running: nil,
                                                now: endsAt.addingTimeInterval(60)),
                       .none)
        XCTAssertEqual(LiveActivityPlanner.plan(snapshot: nil, running: nil, now: opensAt),
                       .none)
    }

    func testEndsWhenTheWindowCloses() {
        let file = snapshot()
        let live = running(file, at: opensAt)
        XCTAssertEqual(LiveActivityPlanner.plan(snapshot: file, running: live,
                                                now: endsAt.addingTimeInterval(1)),
                       .end)
        // ...and when the file loses its window altogether (no schedule yet).
        XCTAssertEqual(LiveActivityPlanner.plan(snapshot: snapshot(window: false),
                                                running: live, now: opensAt),
                       .end)
    }

    func testUpdatesOnlyWhenSomethingASurfaceDrawsHasChanged() {
        let before = snapshot(prayedCount: 2)
        let live = running(before, at: opensAt)
        let now = opensAt.addingTimeInterval(900)

        // `updatedAt` moves on every publish and nothing renders it. If it
        // counted, every tasbih tap would be an ActivityKit update — and
        // updates are exactly what iOS rations when it decides an app is noisy.
        XCTAssertEqual(LiveActivityPlanner.plan(snapshot: before, running: live, now: now),
                       .none)

        let after = snapshot(prayedCount: 3)
        guard case .update(let state) =
                LiveActivityPlanner.plan(snapshot: after, running: live, now: now) else {
            return XCTFail("a friend praying did not move the Lock Screen")
        }
        XCTAssertEqual(state.prayedCount, 3)
    }

    func testAWindowThatMovedUnderARunningActivityIsRestarted() {
        // Attributes are an activity's IDENTITY and cannot be updated, so Asr
        // closing and Maghrib opening while nobody was looking can only be
        // followed by retiring one and starting another.
        let asr = snapshot(prayer: .asr)
        let live = running(asr, at: opensAt)
        let maghrib = snapshot(prayer: .maghrib)
        guard case .restart(let attributes, _) =
                LiveActivityPlanner.plan(snapshot: maghrib, running: live,
                                         now: opensAt.addingTimeInterval(60)) else {
            return XCTFail("the activity stayed on yesterday's prayer")
        }
        XCTAssertEqual(attributes.prayerRaw, Prayer.maghrib.rawValue)

        // The same prayer on a DIFFERENT schedule day is also a different
        // activity — an isha logged after midnight carries yesterday's dayKey.
        let tomorrow = snapshot(prayer: .asr, dayKey: "2026-08-25")
        guard case .restart = LiveActivityPlanner.plan(snapshot: tomorrow, running: live,
                                                       now: opensAt.addingTimeInterval(60))
        else {
            return XCTFail("a new day reused yesterday's activity")
        }
    }

    // MARK: - What the surface says

    func testTheLockScreenAndTheTileCountTheSameCircle() {
        // One derivation, one file, two surfaces — the reason the planner takes
        // a `WidgetSnapshot` rather than an `AppState`. A tile saying "3 of 5"
        // while the Dynamic Island says 2, on one phone, at one second, with
        // neither wrong about its own source, is the bug this prevents.
        //
        // Asserted against the FILE rather than against `CircleWidgetModel`,
        // which lives in the widget target and is not linked here (§3: the
        // extension compiles four paths, and the test bundle is not one of
        // them). The claim is the same either way — the tile reads exactly
        // these four fields off exactly this snapshot — and it is the field
        // names that would have to drift for it to break.
        let file = snapshot(prayedCount: 3, memberCount: 5, youLogged: true,
                            posts: [post("Mina", "🌸", .onTime, minutesAgo: 5)])
        let state = LiveActivityPlanner.contentState(for: file, now: opensAt)
        XCTAssertEqual(state.prayedCount, file.circle.prayedCount)
        XCTAssertEqual(state.memberCount, file.circle.memberCount)
        XCTAssertEqual(state.youLogged, file.you.logged)
        XCTAssertFalse(state.isSolo)
        XCTAssertEqual(state.faces.map { $0.name }, file.circle.posts.map { $0.name })
    }

    func testFacesAreCappedAndCarryTheTierAsAString() {
        let many: [WidgetSnapshot.Post] = (0 ..< 7).map {
            post("Friend \($0)", "🙂", .prayed, minutesAgo: $0)
        }
        let state = LiveActivityPlanner.contentState(for: snapshot(posts: many), now: opensAt)
        XCTAssertEqual(state.faces.count, PrayerWindowAttributes.faceCap)
        XCTAssertEqual(state.faces.first?.tier, LogTier.prayed.rawValue)
        XCTAssertEqual(state.faces.first?.logTier, .prayed)
    }

    func testSoloIsSaidDifferently() {
        let alone = snapshot(prayedCount: 0, memberCount: 1)
        XCTAssertTrue(LiveActivityPlanner.contentState(for: alone, now: opensAt).isSolo)
        XCTAssertEqual(LiveActivityPlanner.contentState(for: alone, now: opensAt).progress, 0)
        let full = snapshot(prayedCount: 5, memberCount: 5)
        XCTAssertEqual(LiveActivityPlanner.contentState(for: full, now: opensAt).progress, 1)
    }

    // MARK: - The wire (§6)

    func testAnOrdinaryContentStateFitsThePushBudget() {
        let state = LiveActivityPlanner.contentState(
            for: snapshot(posts: [post("Mina", "🌸", .onTime, minutesAgo: 2),
                                  post("Yusuf", "🧢", .prayed, minutesAgo: 9),
                                  post("Harun", "🎧", .lastCall, minutesAgo: 20),
                                  post("Sara", "🌙", .qada, minutesAgo: 44)]),
            now: opensAt)
        XCTAssertTrue(PrayerWindowAttributes.fitsPushBudget(state))
    }

    func testTheContentStateDecodesWhatTheServerWrites() throws {
        // Byte-for-byte what `buildLiveActivityContentState` emits (seconds, a
        // bare tier string, no dates). If this stops decoding, every pushed
        // update silently stops moving anybody's Lock Screen — there is no
        // reply on that path and nothing to see.
        let json = """
        {"prayedCount":3,"memberCount":5,"youLogged":true,
         "faces":[{"name":"Mina","emoji":"🌸","tier":"onTime"}],
         "updatedAt":1756000000}
        """
        let state = try JSONDecoder().decode(PrayerWindowAttributes.ContentState.self,
                                             from: Data(json.utf8))
        XCTAssertEqual(state.prayedCount, 3)
        XCTAssertEqual(state.memberCount, 5)
        XCTAssertTrue(state.youLogged)
        XCTAssertEqual(state.faces.count, 1)
        XCTAssertEqual(state.faces.first?.logTier, .onTime)
        XCTAssertEqual(state.updatedAt, 1_756_000_000)
    }

    func testTheAttributesDecodeWhatTheServerWrites() throws {
        let json = #"{"prayer":"asr","dayKey":"2026-08-24","endsAt":1756007200}"#
        let attributes = try JSONDecoder().decode(PrayerWindowAttributes.self,
                                                  from: Data(json.utf8))
        XCTAssertEqual(attributes.prayer, .asr)
        XCTAssertEqual(attributes.dayKey, "2026-08-24")
        XCTAssertEqual(attributes.endsAtDate.timeIntervalSince1970, 1_756_007_200)
    }

    func testAnUnknownTierCostsAColourAndNotThePush() throws {
        let json = """
        {"prayedCount":1,"memberCount":2,
         "faces":[{"name":"Mina","emoji":"🌸","tier":"moonlit"}]}
        """
        let state = try JSONDecoder().decode(PrayerWindowAttributes.ContentState.self,
                                             from: Data(json.utf8))
        XCTAssertEqual(state.faces.count, 1, "a tier this build cannot name dropped the face")
        XCTAssertNil(state.faces.first?.logTier)
        // ...and the fields the surface is actually about survived.
        XCTAssertEqual(state.prayedCount, 1)
        XCTAssertFalse(state.youLogged, "an absent field must default, not throw")
    }

    // MARK: - The session (§2 tooth #3)

    private func sessionJSON(accessToken: String = "eyJhbGciOi",
                             expiresAt: String? = "1756003600") -> Data {
        let expiry: String = expiresAt.map { ",\"expires_at\":\($0)" } ?? ""
        return Data("""
        {"access_token":"\(accessToken)","token_type":"bearer",\
        "refresh_token":"rt"\(expiry)}
        """.utf8)
    }

    func testTheSessionIsReadFromTheSDKsOwnShape() {
        let token = SharedSession.decode(sessionJSON())
        XCTAssertEqual(token?.accessToken, "eyJhbGciOi")
        XCTAssertEqual(token?.expiresAt, 1_756_003_600)
        // A string expiry is accepted rather than dropped: a value we can read
        // is better than a deep link we did not need.
        XCTAssertEqual(SharedSession.decode(sessionJSON(expiresAt: "\"1756003600\""))?.expiresAt,
                       1_756_003_600)
        XCTAssertNil(SharedSession.decode(Data("{}".utf8)))
        XCTAssertNil(SharedSession.decode(Data("not json".utf8)))
        XCTAssertNil(SharedSession.decode(sessionJSON(accessToken: "")))
    }

    func testAnExpiringTokenIsNotSpent() {
        let token = SharedSession.decode(sessionJSON())!
        let expiry = Date(timeIntervalSince1970: 1_756_003_600)
        XCTAssertTrue(token.isFresh(at: expiry.addingTimeInterval(-600)))
        // Inside the margin: the request still has to cross a network and be
        // verified, and a 401 reads to a person as "the button is broken".
        XCTAssertFalse(token.isFresh(at: expiry.addingTimeInterval(-30)))
        XCTAssertFalse(token.isFresh(at: expiry.addingTimeInterval(60)))
    }

    func testATokenWithNoExpiryFailsTowardsTheDeepLink() {
        // The two mistakes are not symmetric. Treating an unknown expiry as
        // fresh spends a possibly-dead token on a request nobody can retry and
        // leaves a button that silently does nothing; treating it as expired
        // opens the app, where a real client with a real refresh path — the one
        // process allowed to refresh at all — sorts it out.
        let token = SharedSession.decode(sessionJSON(expiresAt: nil))
        XCTAssertNotNil(token)
        XCTAssertFalse(token!.isFresh(at: Date(timeIntervalSince1970: 0)))
    }

    // MARK: - The request

    func testTheNudgeRequestIsTheSameCallTheAppMakes() throws {
        let request = try XCTUnwrap(
            NudgeRequest.build(memberID: "7C7A6C22-0000-4000-8000-000000000001",
                               dayKey: "2026-08-24", prayer: "asr",
                               accessToken: "token-1"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, SharedBackend.notifyURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"),
                       SharedBackend.publishableKey)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String])
        // The keys `_shared/validate.ts` parses, and no others.
        XCTAssertEqual(json, ["kind": "nudge",
                              "recipientId": "7C7A6C22-0000-4000-8000-000000000001",
                              "dayKey": "2026-08-24",
                              "prayer": "asr"])
    }

    func testAnIncompleteNudgeIsNeverSent() {
        XCTAssertNil(NudgeRequest.build(memberID: "", dayKey: "2026-08-24",
                                        prayer: "asr", accessToken: "t"))
        XCTAssertNil(NudgeRequest.build(memberID: "m", dayKey: "", prayer: "asr",
                                        accessToken: "t"))
        XCTAssertNil(NudgeRequest.build(memberID: "m", dayKey: "2026-08-24", prayer: "",
                                        accessToken: "t"))
        XCTAssertNil(NudgeRequest.build(memberID: "m", dayKey: "2026-08-24",
                                        prayer: "asr", accessToken: ""))
    }

    func testAlreadyNudgedIsNotAFailure() {
        // The same reading `PushRegistrar.outcome` makes: you already nudged
        // them for this window, the chip already says so, and a second tap must
        // not un-tick it.
        XCTAssertTrue(NudgeRequest.landed(status: 200,
                                          body: Data(#"{"ok":true,"sent":true}"#.utf8)))
        XCTAssertTrue(NudgeRequest.landed(
            status: 200,
            body: Data(#"{"ok":true,"sent":false,"reason":"rate_limited"}"#.utf8)))
        XCTAssertFalse(NudgeRequest.landed(
            status: 200,
            body: Data(#"{"ok":true,"sent":false,"reason":"not_in_circle"}"#.utf8)))
        XCTAssertFalse(NudgeRequest.landed(status: 401, body: nil))
    }

    // MARK: - The optimistic write (§4)

    func testMarkingNudgedMovesOneFlagAndNothingElse() {
        let file = snapshot(posts: [post("Mina", "🌸", .onTime, minutesAgo: 3)],
                            waiting: [waiting("m1", "Harun"), waiting("m2", "Sara")])
        let marked = file.markingNudged(memberID: "m1")
        XCTAssertTrue(marked.circle.waiting[0].nudgedThisWindow)
        XCTAssertFalse(marked.circle.waiting[1].nudgedThisWindow)
        // Nudging somebody is not praying for them.
        XCTAssertEqual(marked.circle.prayedCount, file.circle.prayedCount)
        XCTAssertEqual(marked.circle.posts, file.circle.posts)
        // A name that is not in the list is a no-op, not a crash.
        XCTAssertEqual(file.markingNudged(memberID: "nobody"), file)
        XCTAssertEqual(file.markingNudged(memberID: ""), file)
    }

    func testTheButtonAimsAtTheFirstPersonNotYetNudged() {
        let file = snapshot(waiting: [waiting("m1", "Harun", nudged: true),
                                      waiting("m2", "Sara")])
        XCTAssertEqual(file.nextNudgeTarget?.userID, "m2")
        // The list is already gated (`WidgetSnapshotBuilder.nudgesAllowed`), so
        // an empty one means "nobody is nudgeable yet" and the button is simply
        // not drawn.
        XCTAssertNil(snapshot().nextNudgeTarget)
        XCTAssertNil(file.markingNudged(memberID: "m2").nextNudgeTarget)
    }

    func testTheIntentsWriteSurvivesARoundTripThroughTheContainer() throws {
        // §4: "write the new state into the container inside perform() before
        // returning so the reload renders it." This is that write, against a
        // real file, through the same encoder/decoder pair both processes use.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-nudge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = snapshot(waiting: [waiting("m1", "Harun")])
        XCTAssertTrue(WidgetFile.write(file, to: url))

        XCTAssertTrue(WidgetFile.markNudged(memberID: "m1", at: url))
        let reread = try XCTUnwrap(WidgetFile.read(at: url))
        XCTAssertTrue(reread.circle.waiting[0].nudgedThisWindow)
        XCTAssertNil(reread.nextNudgeTarget)

        // Idempotent: a second tap writes nothing rather than churning the file
        // (and the server's rate limit is the real one-per-window guarantee).
        XCTAssertFalse(WidgetFile.markNudged(memberID: "m1", at: url))
        // ...and a file that is not there is not an error.
        XCTAssertFalse(WidgetFile.markNudged(
            memberID: "m1",
            at: url.deletingLastPathComponent().appendingPathComponent("absent.json")))
    }

    // MARK: - The deep link (§2 tooth #3)

    func testTheDeepLinkRoundTrips() throws {
        let url = try XCTUnwrap(SharedBackend.nudgeDeepLink(memberID: "m1", prayer: "asr",
                                                            dayKey: "2026-08-24"))
        XCTAssertEqual(url.scheme, "salahbuddy")
        let target = try XCTUnwrap(SharedBackend.nudgeDeepLinkTarget(url))
        XCTAssertEqual(target.memberID, "m1")
        XCTAssertEqual(target.prayer, "asr")
        XCTAssertEqual(target.dayKey, "2026-08-24")
    }

    func testGooglesCallbackIsNotOurs() {
        // Both come through the same `.onOpenURL`, and the app hands anything
        // this does not claim to `AuthService`. Claiming one of Google's would
        // break sign-in.
        let google = URL(string: "com.googleusercontent.apps.1234:/oauth2callback?code=x")!
        XCTAssertNil(SharedBackend.nudgeDeepLinkTarget(google))
        XCTAssertNil(SharedBackend.nudgeDeepLinkTarget(URL(string: "salahbuddy://camera")!))

        let state = AppState()
        XCTAssertFalse(state.handleDeepLink(google))
        XCTAssertNil(state.pendingWidgetNudge)
        XCTAssertTrue(state.handleDeepLink(
            SharedBackend.nudgeDeepLink(memberID: "m1", prayer: "asr", dayKey: "2026-08-24")!))
        XCTAssertEqual(state.pendingWidgetNudge?.memberID, "m1")
        XCTAssertEqual(state.pendingWidgetNudge?.prayer, .asr)
        state.clearPendingWidgetNudge()
        XCTAssertNil(state.pendingWidgetNudge)
    }

    // MARK: - The token registration (§6)

    func testAnActivityTokenNamesItsWindowAndAStartTokenDoesNot() {
        // The RPC refuses both mismatched combinations (SQL test 30), and the
        // fingerprint is what stops ActivityKit's stream re-registering the same
        // row on every emission.
        let update = LiveActivityRegistration(
            token: "abc", kind: .update, activityID: "A1", dayKey: "2026-08-24",
            prayer: .asr, endsAt: endsAt, environment: "sandbox", utcOffset: -25200)
        let start = LiveActivityRegistration(
            token: "abc", kind: .start, activityID: nil, dayKey: nil, prayer: nil,
            endsAt: nil, environment: "sandbox", utcOffset: -25200)
        XCTAssertNotEqual(update.fingerprint, start.fingerprint)
        XCTAssertEqual(update.fingerprint, update.fingerprint)

        var moved = update
        moved.utcOffset = 19800
        XCTAssertNotEqual(update.fingerprint, moved.fingerprint,
                          "a phone that changed zones must re-register")
    }

    func testTheRegistrationEncodesTheRPCsParameterNames() throws {
        let registration = LiveActivityRegistration(
            token: "abc", kind: .update, activityID: "A1", dayKey: "2026-08-24",
            prayer: .asr, endsAt: Date(timeIntervalSince1970: 1_787_543_200),
            environment: "sandbox", utcOffset: -25200)
        let data = try JSONEncoder().encode(registration.registerParams)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["p_token"] as? String, "abc")
        XCTAssertEqual(json["p_kind"] as? String, "update")
        XCTAssertEqual(json["p_activity_id"] as? String, "A1")
        XCTAssertEqual(json["p_day_key"] as? String, "2026-08-24")
        XCTAssertEqual(json["p_prayer"] as? String, "asr")
        XCTAssertEqual(json["p_utc_offset"] as? Int, -25200)
        // `timestamptz` as PostgREST wants it, spelled out rather than left to
        // whatever date strategy the SDK's encoder happens to carry — a column
        // that silently becomes NULL costs the fan-out its stale date and its
        // ability to retire the activity.
        XCTAssertEqual(json["p_ends_at"] as? String, "2026-08-24T03:46:40Z")

        // A start token omits the window fields entirely rather than sending
        // nulls: PostgREST resolves an RPC by the argument names in the body.
        let startData = try JSONEncoder().encode(
            LiveActivityRegistration(token: "abc", kind: .start, activityID: nil,
                                     dayKey: nil, prayer: nil, endsAt: nil,
                                     environment: "production", utcOffset: 0)
                .registerParams)
        let startJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: startData) as? [String: Any])
        XCTAssertNil(startJSON["p_day_key"])
        XCTAssertNil(startJSON["p_prayer"])
        XCTAssertNil(startJSON["p_ends_at"])
        XCTAssertNil(startJSON["p_activity_id"])
    }
}
