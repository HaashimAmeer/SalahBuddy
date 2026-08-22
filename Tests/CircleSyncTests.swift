import XCTest
@testable import SalahBuddy

/// v4 sync-layer tests: the wire format (snake_case columns, omitted
/// server-managed defaults), the tolerant snapshot decoder, the
/// RemotePost → PrayerLog bridge that keeps `GameEngine` the only scorer, and
/// the outbox's ordering + collapse rules.
///
/// Nothing here touches the network or `Store` — every type under test is a
/// pure value type, which is the whole reason the sync layer was split this way.
final class CircleSyncTests: XCTestCase {

    private let cal = Calendar.current

    // Fixed ids so failures are readable and nothing depends on UUID ordering.
    private let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let userB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let postID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let otherPostID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    /// 2026-06-08 is a Monday — the same week the other suites use.
    private let monday = "2026-06-08"
    private let tuesday = "2026-06-09"

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    /// Whole seconds only, so an ISO8601 round trip is lossless.
    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    /// Stands in for `Store`, so it must encode like Store does — including
    /// `persistingMirror`. Without it this helper silently tests the WIRE shape
    /// while claiming to test the on-disk round trip.
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.userInfo[.persistingMirror] = true
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.userInfo[.persistingMirror] = true
        return d
    }

    /// A WIRE encoder — deliberately without `persistingMirror`, because every
    /// caller of `jsonObject` is asserting what PostgREST receives. Sharing the
    /// persistence encoder here would let a server-owned column look sendable.
    private func wireEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try wireEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }

    /// The rule the two encoders exist to enforce, asserted directly: a column
    /// the INSERT grant omits must be kept on disk and withheld from the wire.
    func testServerOwnedColumnsArePersistedButNeverSent() throws {
        let challenge = RemoteCustomChallenge(id: "custom-1", circleID: circleID,
                                              createdBy: userA, prayer: .fajr, days: 3,
                                              weekKey: "2026-W24", createdAt: stamp(0))
        XCTAssertNil(try jsonObject(challenge)["created_at"],
                     "created_at is not in the INSERT grant — sending it is a refusal")

        let restored = try decoder().decode(RemoteCustomChallenge.self,
                                            from: try encoder().encode(challenge))
        XCTAssertEqual(restored.createdAt, challenge.createdAt,
                       "the on-disk mirror must keep it, or a cold launch drops it")
    }

    private func post(id: UUID? = nil, user: UUID? = nil, prayer: Prayer = .dhuhr,
                      tier: LogTier = .onTime, dayKey: String? = nil,
                      jamaat: Bool = false, placeLabel: String? = nil,
                      photoPath: String? = nil) -> RemotePost {
        RemotePost(id: id ?? postID, userID: user ?? userA, circleID: circleID,
                   dayKey: dayKey ?? monday, prayer: prayer, tier: tier,
                   loggedAt: stamp(0), jamaat: jamaat, placeLabel: placeLabel,
                   photoPath: photoPath, travelCombined: false)
    }

    // MARK: - Wire format

    func testRemotePostEncodesSnakeCaseColumns() throws {
        let sent = RemotePost(id: postID, userID: userA, circleID: circleID,
                              dayKey: monday, prayer: .maghrib, tier: .lastCall,
                              loggedAt: stamp(0), jamaat: true,
                              placeLabel: "🕌 Masjid", photoPath: nil,
                              travelCombined: true)
        let json = try jsonObject(sent)

        XCTAssertEqual(json["day_key"] as? String, monday)
        XCTAssertEqual(json["user_id"] as? String, userA.uuidString)
        XCTAssertEqual(json["circle_id"] as? String, circleID.uuidString)
        XCTAssertEqual(json["place_label"] as? String, "🕌 Masjid")
        XCTAssertEqual(json["travel_combined"] as? Bool, true)
        XCTAssertEqual(json["jamaat"] as? Bool, true)

        // PostgREST does not convert key casing, so a camelCase key would just
        // miss its column and be silently dropped.
        XCTAssertNil(json["dayKey"], "camelCase must never reach the wire")
        XCTAssertNil(json["placeLabel"])
        XCTAssertNil(json["travelCombined"])

        // The enum labels ARE the Postgres enum labels (see the init migration).
        XCTAssertEqual(json["prayer"] as? String, "maghrib")
        XCTAssertEqual(json["tier"] as? String, "lastCall")

        // Nil optionals are OMITTED, never sent as null — and created_at /
        // updated_at are never sent at all, so the DB defaults win over a
        // possibly-wrong device clock.
        XCTAssertNil(json["photo_path"], "a nil optional must be omitted, not null")
        XCTAssertNil(json["created_at"])
        XCTAssertNil(json["updated_at"])
    }

    func testRemotePostDecodesPostgRESTRow() throws {
        let row = """
        {"id":"44444444-4444-4444-4444-444444444444",
         "user_id":"11111111-1111-1111-1111-111111111111",
         "circle_id":"33333333-3333-3333-3333-333333333333",
         "day_key":"2026-06-08","prayer":"isha","tier":"closeCall",
         "logged_at":"2026-06-09T02:10:00Z","jamaat":false,
         "place_label":null,"photo_path":"33333333/11111111/abc.jpg",
         "travel_combined":false,
         "created_at":"2026-06-09T02:10:01Z","updated_at":"2026-06-09T02:10:01Z"}
        """.data(using: .utf8)!
        let decoded = try decoder().decode(RemotePost.self, from: row)

        XCTAssertEqual(decoded.prayer, .isha)
        XCTAssertEqual(decoded.tier, .closeCall)
        // The Isha-after-midnight rule travels with the post: logged_at is the
        // 9th, day_key stays the 8th, and the client never re-derives it.
        XCTAssertEqual(decoded.dayKey, "2026-06-08")
        XCTAssertNil(decoded.placeLabel)
        XCTAssertEqual(decoded.photoPath, "33333333/11111111/abc.jpg")
        XCTAssertFalse(decoded.travelCombined)
    }

    func testExcusedDayCarriesNothingButTheFlag() throws {
        // Period privacy is absolute (§3): breakReason has no column, and this
        // asserts it has no JSON key either.
        let day = RemoteExcusedDay(userID: userA, circleID: circleID, dayKey: monday)
        let json = try jsonObject(day)
        XCTAssertEqual(Set(json.keys), Set(["user_id", "circle_id", "day_key"]))
    }

    func testProfileChallengeAndRecoveryWeekUseSnakeCase() throws {
        let profile = RemoteProfile(id: userA, name: "Haashim", avatarEmoji: "🌙",
                                    avatarPath: nil, memberKind: "brother")
        let profileJSON = try jsonObject(profile)
        XCTAssertEqual(profileJSON["avatar_emoji"] as? String, "🌙")
        XCTAssertEqual(profileJSON["member_kind"] as? String, "brother")
        XCTAssertNil(profileJSON["avatar_path"])
        XCTAssertNil(profileJSON["avatarEmoji"])

        let challenge = RemoteCustomChallenge(id: "custom-1", circleID: circleID,
                                              createdBy: userA, prayer: .fajr,
                                              days: 3, weekKey: "2026-W24")
        let challengeJSON = try jsonObject(challenge)
        XCTAssertEqual(challengeJSON["circle_id"] as? String, circleID.uuidString)
        XCTAssertEqual(challengeJSON["created_by"] as? String, userA.uuidString)
        XCTAssertEqual(challengeJSON["week_key"] as? String, "2026-W24")
        XCTAssertEqual(challengeJSON["prayer"] as? String, "fajr")

        let week = RemoteRecoveryWeek(userID: userA, circleID: circleID,
                                      weekKey: "2026-W24", xp: 40)
        let weekJSON = try jsonObject(week)
        XCTAssertEqual(weekJSON["week_key"] as? String, "2026-W24")
        XCTAssertEqual(weekJSON["xp"] as? Int, 40)
        XCTAssertNil(weekJSON["updated_at"])
    }

    /// v4 Phase C REGRESSION: the challenge insert must not name `created_at`.
    ///
    /// `20260821000200_rls.sql` grants `authenticated`
    /// `insert (id, circle_id, created_by, prayer, days, week_key)` and
    /// `backend/tests/sql/12_rls_enabled_everywhere.sql` fails the backend
    /// build if `created_at` is ever added. Sending it made every custom
    /// challenge insert fail with `42501 permission denied for column
    /// created_at` — a refusal, so the op spent its whole budget and was then
    /// discarded, and the challenge never reached the circle at all.
    func testCustomChallengeInsertNamesOnlyGrantedColumns() throws {
        let challenge = RemoteCustomChallenge(id: "custom-1", circleID: circleID,
                                              createdBy: userA, prayer: .fajr,
                                              days: 3, weekKey: "2026-W24",
                                              createdAt: stamp(0))
        let json = try jsonObject(challenge)
        XCTAssertNil(json["created_at"], "the column has no INSERT grant — the DB default fills it")
        XCTAssertEqual(json.keys.sorted(),
                       ["circle_id", "created_by", "days", "id", "prayer", "week_key"])
    }

    /// It still DECODES — `select` is granted on the whole table, so the value
    /// comes back on the next pull.
    func testCustomChallengeStillDecodesItsServerCreatedAt() throws {
        var raw: String = "{\"id\":\"custom-1\","
        raw += "\"circle_id\":\"" + circleID.uuidString + "\","
        raw += "\"created_by\":\"" + userA.uuidString + "\","
        raw += "\"prayer\":\"fajr\",\"days\":3,\"week_key\":\"2026-W24\","
        raw += "\"created_at\":\"2026-06-08T09:00:00Z\"}"
        let row = try decoder().decode(RemoteCustomChallenge.self, from: Data(raw.utf8))
        XCTAssertNotNil(row.createdAt)
    }

    /// v4 Phase C REGRESSION: a slot repair says what a field IS now, `nil`
    /// included. Synthesised `Encodable` emits `encodeIfPresent` for an
    /// Optional, so a correction that DROPPED a place tag omitted the key and
    /// the PATCH left the other device's stale pill sitting on the row.
    func testAPostSlotPatchSendsAnAbsentPlaceLabelAsNull() throws {
        let patch = PostSlotPatch(tier: .prayed, loggedAt: stamp(0), jamaat: false,
                                  placeLabel: nil, travelCombined: false)
        let text: String = String(decoding: try encoder().encode(patch), as: UTF8.self)
        XCTAssertTrue(text.contains("\"place_label\":null"),
                      "a dropped place tag has to be written, not omitted: " + text)
        // photo_path stays OUT: the photo op owns it, and nulling it here would
        // let a replayed upsert tombstone a picture that had already landed.
        XCTAssertFalse(text.contains("photo_path"))
    }

    // MARK: - RemotePost → PrayerLog

    func testAsPrayerLogMapsTierDayKeyAndJamaat() {
        let remote = post(prayer: .asr, tier: .lastCall, dayKey: tuesday, jamaat: true,
                          placeLabel: "🏠 Home", photoPath: "c/u/x.jpg")
        let log = remote.asPrayerLog()

        XCTAssertEqual(log.id, remote.id, "the client UUID is shared — replays stay idempotent")
        XCTAssertEqual(log.prayer, .asr)
        XCTAssertEqual(log.tier, .lastCall)
        XCTAssertEqual(log.dayKey, tuesday)
        XCTAssertEqual(log.loggedAt, remote.loggedAt)
        XCTAssertTrue(log.jamaat)
        // Jamaat is a FLOOR to 30, and the mapping runs the same GameEngine
        // function the local logging path does.
        XCTAssertEqual(log.xp, GameEngine.prayerXP(tier: .lastCall, jamaat: true))
        XCTAssertEqual(log.xp, 30)
        // A buddy photo lives in the disposable cache, never in PhotoStore.
        XCTAssertNil(log.photoFilename, "buddy photos must never enter PhotoStore")
        XCTAssertNil(log.placeTag)
    }

    func testQadaPostKeepsQadaXPEvenWithJamaat() {
        let log = post(prayer: .fajr, tier: .qada, jamaat: true).asPrayerLog()
        XCTAssertEqual(log.xp, LogTier.qada.xp, "qada never takes the jamaat floor")
    }

    // MARK: - The late-edit rule crosses the wire (v4 Phase C regression)

    /// A retroactive make-up is worth what `GameEngine.lateEditXP` says — on
    /// EVERY device, not just the one that made it.
    ///
    /// `AppState.logPastMakeUp` scores an old day at 0 once it is past the
    /// 2-day grace (same-day logging is the incentive), while `asPrayerLog()`
    /// re-derived a flat `LogTier.qada.xp`. Every friend's device therefore
    /// scored a stale make-up five points higher than the poster's own, and
    /// both numbers sat on the same Mon-start scoreboard for the rest of the
    /// week. The rule needs no clock: the day the EDIT was made is `logged_at`,
    /// which is already on the wire.
    func testAStaleMakeUpScoresTheSameOnEveryDevice() {
        // Logged on the Sunday, for the Monday six days earlier.
        let loggedAt: Date = date(2026, 6, 14, 20, 0)
        let stale = RemotePost(id: postID, userID: userA, circleID: circleID,
                               dayKey: monday, prayer: .fajr, tier: .qada,
                               loggedAt: loggedAt)
        let local: Int = GameEngine.lateEditXP(dayKey: monday,
                                               todayKey: AppClock.dayKey(for: loggedAt),
                                               calendar: cal)
        XCTAssertEqual(local, 0, "six days late earns nothing locally")
        XCTAssertEqual(stale.asPrayerLog().xp, local)
    }

    func testAFreshMakeUpStillScoresQadaXP() {
        // Inside the grace window: logged the next day, for yesterday.
        let loggedAt: Date = date(2026, 6, 9, 20, 0)
        let fresh = RemotePost(id: postID, userID: userA, circleID: circleID,
                               dayKey: monday, prayer: .fajr, tier: .qada,
                               loggedAt: loggedAt)
        XCTAssertEqual(fresh.asPrayerLog().xp, LogTier.qada.xp)
    }

    /// The isha-after-midnight case: yesterday's `day_key`, this morning's
    /// `logged_at`. Comfortably inside the grace, exactly as the local path
    /// scores it.
    func testAPostMidnightQadaIsStillWorthFive() {
        let loggedAt: Date = date(2026, 6, 9, 1, 15)
        let overnight = RemotePost(id: postID, userID: userA, circleID: circleID,
                                   dayKey: monday, prayer: .isha, tier: .qada,
                                   loggedAt: loggedAt)
        XCTAssertEqual(overnight.asPrayerLog().xp, LogTier.qada.xp)
    }

    /// In-window tiers are untouched by the fix.
    func testInWindowTiersAreStillScoredByPrayerXP() {
        let entry = RemotePost(id: postID, userID: userA, circleID: circleID,
                               dayKey: monday, prayer: .maghrib, tier: .lastCall,
                               loggedAt: stamp(0), jamaat: true)
        XCTAssertEqual(entry.asPrayerLog().xp,
                       GameEngine.prayerXP(tier: .lastCall, jamaat: true))
    }

    func testRoundTripThroughTheWirePreservesTheLog() throws {
        let original = post(prayer: .maghrib, tier: .prayed, jamaat: false)
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(RemotePost.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.asPrayerLog(), original.asPrayerLog())
    }

    // MARK: - GameEngine over synced posts

    private func syncedWeekSnapshot() -> CircleSnapshot {
        var posts: [RemotePost] = [
            post(id: UUID(), prayer: .fajr, tier: .onTime),
            post(id: UUID(), prayer: .dhuhr, tier: .onTime),
            post(id: UUID(), prayer: .asr, tier: .onTime),
            post(id: UUID(), prayer: .maghrib, tier: .lastCall, jamaat: true),
            post(id: UUID(), prayer: .isha, tier: .onTime),
        ]
        posts.append(post(id: UUID(), prayer: .fajr, tier: .qada, dayKey: tuesday))
        posts.append(post(id: UUID(), prayer: .dhuhr, tier: .prayed, dayKey: tuesday))
        // A second member's posts must not leak into the first member's score.
        posts.append(post(id: UUID(), user: userB, prayer: .fajr, tier: .onTime))
        return CircleSnapshot(circle: RemoteCircle(id: circleID, code: "ABC234"),
                              me: userB,
                              profiles: [RemoteProfile(id: userA, name: "Amira", avatarEmoji: "🌸"),
                                         RemoteProfile(id: userB, name: "Haashim")],
                              members: [RemoteMember(circleID: circleID, userID: userA,
                                                     joinedAt: stamp(0)),
                                        RemoteMember(circleID: circleID, userID: userB,
                                                     joinedAt: stamp(60))],
                              posts: posts)
    }

    func testWeeklyXPOverMappedPostsMatchesLocalMath() {
        let snapshot = syncedWeekSnapshot()
        let logs: [PrayerLog] = snapshot.prayerLogs(userID: userA)
        XCTAssertEqual(logs.count, 7, "userB's post must not be counted")

        // Monday: 4 × 30 in-window + a jamaat lastCall floored to 30 = 150,
        // all five in-window so +25 perfect-day = 175.
        // Tuesday: qada 5 + prayed 20 = 25, no bonus.
        let weekStart = date(2026, 6, 8)
        let total = GameEngine.weeklyXP(logs: logs, weekStart: weekStart, calendar: cal)
        XCTAssertEqual(total, 200)
        XCTAssertEqual(GameEngine.xp(forDay: monday, logs: logs), 175)
        XCTAssertEqual(GameEngine.xp(forDay: tuesday, logs: logs), 25)
        XCTAssertTrue(GameEngine.isPerfectDay(logs: logs, dayKey: monday))
    }

    func testExcusedDaysFlowIntoTheSameScoringCall() {
        var snapshot = syncedWeekSnapshot()
        snapshot.excusedDays = [RemoteExcusedDay(userID: userA, circleID: circleID,
                                                 dayKey: monday)]
        XCTAssertTrue(snapshot.isExcused(userID: userA, dayKey: monday))
        XCTAssertFalse(snapshot.isExcused(userID: userB, dayKey: monday))
        XCTAssertEqual(snapshot.excusedDayKeys(userID: userA), Set([monday]))

        // An excused day never earns the perfect-day bonus — the same rule your
        // own days follow, run by the same pure function.
        let logs: [PrayerLog] = snapshot.prayerLogs(userID: userA)
        let total = GameEngine.weeklyXP(logs: logs, weekStart: date(2026, 6, 8),
                                        calendar: cal,
                                        excusedDayKeys: snapshot.excusedDayKeys(userID: userA))
        XCTAssertEqual(total, 175)
    }

    // MARK: - Snapshot helpers

    func testSnapshotRosterAndLookups() {
        let snapshot = syncedWeekSnapshot()

        XCTAssertTrue(snapshot.hasCircle)
        XCTAssertEqual(snapshot.remainingSlots, RemoteCircle.maxMembers - 2)
        XCTAssertEqual(snapshot.allMembers.count, 2)
        // Join order, oldest first — userA joined a minute before userB.
        XCTAssertEqual(snapshot.allMembers.first?.name, "Amira")

        // "You" is appended by AppState, exactly as in demo mode.
        let buddies = snapshot.buddyMembers
        XCTAssertEqual(buddies.count, 1)
        XCTAssertEqual(buddies.first?.id, userA.uuidString)
        XCTAssertFalse(buddies.first?.isYou ?? true)

        let me = snapshot.member(for: userB)
        XCTAssertEqual(me?.isYou, true)
        XCTAssertEqual(me?.name, "Haashim")
        XCTAssertNil(me?.avatarFilename, "avatarFilename names a PhotoStore file, not a sync path")

        let stranger = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        XCTAssertNil(snapshot.member(for: stranger))

        XCTAssertEqual(snapshot.posts(dayKey: monday, prayer: .fajr).count, 2)
        XCTAssertEqual(snapshot.post(userID: userA, dayKey: monday, prayer: .isha,
                                     asOf: .distantFuture)?.tier, .onTime)
        XCTAssertNil(snapshot.post(userID: userB, dayKey: tuesday, prayer: .isha,
                                   asOf: .distantFuture))
        XCTAssertEqual(snapshot.prayerLogs(userID: userA, dayKeys: [tuesday]).count, 2)
    }

    func testRecoveryXPIsSummedPerWeekAndPerUser() {
        var snapshot = syncedWeekSnapshot()
        snapshot.recoveryWeeks = [
            RemoteRecoveryWeek(userID: userA, circleID: circleID, weekKey: "2026-W24", xp: 40),
            RemoteRecoveryWeek(userID: userA, circleID: circleID, weekKey: "2026-W25", xp: 15),
            RemoteRecoveryWeek(userID: userB, circleID: circleID, weekKey: "2026-W24", xp: 90),
        ]
        XCTAssertEqual(snapshot.recoveryXP(userID: userA, weekKeys: ["2026-W24"]), 40)
        XCTAssertEqual(snapshot.recoveryXP(userID: userA, weekKeys: ["2026-W24", "2026-W25"]), 55)
        XCTAssertEqual(snapshot.recoveryXP(userID: userB, weekKeys: ["2026-W25"]), 0)
    }

    // MARK: - Tolerant snapshot decoding

    func testSnapshotMissingNewerFieldsStillDecodes() throws {
        // A mirror saved by an earlier build: no recoveryWeeks, no challenges,
        // no lastSyncedAt — and one key this build has never heard of.
        let json = """
        {"me":"22222222-2222-2222-2222-222222222222",
         "circle":{"id":"33333333-3333-3333-3333-333333333333","code":"ABC234",
                   "name":"The Lads","emoji":"🤝"},
         "profiles":[{"id":"11111111-1111-1111-1111-111111111111","name":"Amira",
                      "avatar_emoji":"🌸"}],
         "members":[{"circle_id":"33333333-3333-3333-3333-333333333333",
                     "user_id":"11111111-1111-1111-1111-111111111111"}],
         "posts":[],
         "somethingFromTheFuture":{"nested":true}}
        """.data(using: .utf8)!
        let snapshot = try decoder().decode(CircleSnapshot.self, from: json)

        XCTAssertEqual(snapshot.me, userB)
        XCTAssertEqual(snapshot.circle?.name, "The Lads")
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.members.count, 1)
        XCTAssertTrue(snapshot.recoveryWeeks.isEmpty, "a missing collection decodes to empty")
        XCTAssertTrue(snapshot.challenges.isEmpty)
        XCTAssertTrue(snapshot.excusedDays.isEmpty)
        XCTAssertNil(snapshot.lastSyncedAt)
        XCTAssertEqual(snapshot.member(for: userA)?.emoji, "🌸")
    }

    func testEmptySnapshotDecodesFromAnEmptyObject() throws {
        let snapshot = try decoder().decode(CircleSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(snapshot, CircleSnapshot.empty)
        XCTAssertFalse(snapshot.hasCircle)
        XCTAssertTrue(snapshot.buddyMembers.isEmpty)
        XCTAssertEqual(snapshot.remainingSlots, RemoteCircle.maxMembers)
    }

    func testSnapshotSurvivesASaveLoadRoundTrip() throws {
        var original = syncedWeekSnapshot()
        original.lastSyncedAt = stamp(120)
        original.challenges = [RemoteCustomChallenge(id: "custom-9", circleID: circleID,
                                                     createdBy: userA, prayer: .fajr, days: 3,
                                                     weekKey: "2026-W24", createdAt: stamp(0))]
        let data = try encoder().encode(original)
        let restored = try decoder().decode(CircleSnapshot.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.customChallenges.first?.days, 3)
        XCTAssertEqual(restored.customChallenges.first?.prayer, .fajr)
    }

    // MARK: - Outbox collapsing

    private func outboxWith(_ ops: [CircleOp]) -> CircleOutbox {
        var outbox = CircleOutbox.empty
        for (index, op) in ops.enumerated() {
            outbox.enqueue(op, id: UUID(), at: stamp(TimeInterval(index)))
        }
        return outbox
    }

    func testDeleteCancelsANeverSentUpsert() {
        // Log then undo while offline: the server never saw the post, so
        // replaying create-then-delete would be pure waste.
        let outbox = outboxWith([.upsertPost(post()), .deletePost(postID: postID)])
        XCTAssertTrue(outbox.isEmpty)
    }

    func testDeleteIsQueuedWhenNothingIsPending() {
        // The post already reached the server on an earlier drain — the delete
        // is real work and must survive.
        let outbox = outboxWith([.deletePost(postID: postID)])
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.peek?.op, CircleOp.deletePost(postID: postID))
    }

    func testDeleteAlsoDropsTheQueuedPhotoUpload() {
        let outbox = outboxWith([
            .upsertPost(post()),
            .uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "a.jpg", path: "c/u/a.jpg"),
            .deletePost(postID: postID),
        ])
        XCTAssertTrue(outbox.isEmpty, "a photo for a post that is going away is moot")
    }

    // MARK: - In-flight safety

    func testUndoDuringAnInFlightCreateStillQueuesTheDelete() {
        // The create is ON THE WIRE when undo is tapped. Cancelling it locally
        // used to swallow the delete while the POST went on to succeed —
        // leaving an undone prayer in the circle's feed forever.
        var outbox = outboxWith([.upsertPost(post())])
        let sending: OutboxItem? = outbox.checkout()
        XCTAssertEqual(sending?.op, CircleOp.upsertPost(post()))

        outbox.enqueue(.deletePost(postID: postID), id: UUID(), at: stamp(5))
        XCTAssertEqual(outbox.count, 2, "the in-flight create is never cancelled")
        XCTAssertEqual(outbox.items.last?.op, CircleOp.deletePost(postID: postID))

        // Once the create is acked the delete is the head, exactly as ordered.
        guard let sentID: UUID = sending?.id else { return XCTFail("expected a queued item") }
        outbox.remove(id: sentID)
        XCTAssertEqual(outbox.peek?.op, CircleOp.deletePost(postID: postID))
    }

    func testAnInFlightUpsertIsNotReplacedByANewerOne() {
        var outbox = outboxWith([.upsertPost(post(tier: .onTime))])
        _ = outbox.checkout()
        outbox.enqueue(.upsertPost(post(tier: .closeCall)), id: UUID(), at: stamp(5))

        XCTAssertEqual(outbox.count, 2,
                       "collapsing onto a sent op would ack the wrong item; the newer one queues")
        guard case .upsertPost(let latest)? = outbox.items.last?.op else {
            return XCTFail("expected the newer upsert to be queued behind the in-flight one")
        }
        XCTAssertEqual(latest.tier, .closeCall, "and it still carries the newer payload")
    }

    func testUndoDuringAnInFlightPhotoUploadRetractsTheObject() {
        // The object may land in Storage after the row is deleted, and the
        // retention sweep enumerates paths from `posts` — so it would never be
        // collected, and would stay readable by the whole circle (§4).
        let path = "c/u/a.jpg"
        var outbox = outboxWith([.uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "a.jpg", path: path)])
        _ = outbox.checkout()

        outbox.enqueue(.deletePost(postID: postID), id: UUID(), at: stamp(5))
        XCTAssertEqual(outbox.items.map { $0.op.kind },
                       [CircleOp.Kind.uploadPhoto, .deletePhoto, .deletePost],
                       "the compensating delete follows the upload it can't cancel")
        XCTAssertEqual(outbox.items[1].op, CircleOp.deletePhoto(path: path))
    }

    func testAQueuedButUnsentPhotoUploadNeedsNoRetraction() {
        // Nothing reached Storage, so dropping the upload is the whole fix —
        // a `.deletePhoto` here would 404 for no reason.
        var outbox = outboxWith([.uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "a.jpg", path: "c/u/a.jpg")])
        outbox.enqueue(.deletePost(postID: postID), id: UUID(), at: stamp(5))
        XCTAssertEqual(outbox.items.map { $0.op.kind }, [CircleOp.Kind.deletePost])
    }

    func testDeletePhotoSurvivesTheWireFormat() throws {
        var outbox = CircleOutbox.empty
        outbox.enqueue(.deletePhoto(path: "c/u/a.jpg"), id: UUID(), at: stamp(0))
        let data = try encoder().encode(outbox)
        let restored = try decoder().decode(CircleOutbox.self, from: data)
        XCTAssertEqual(restored.items.map(\.op), [CircleOp.deletePhoto(path: "c/u/a.jpg")])
        XCTAssertNil(restored.inFlightID, "a queue reloaded from disk has nothing on the wire")
    }

    // MARK: - Outbox collapsing (continued)

    func testRepeatedUpsertKeepsOneItemInItsOriginalPlace() {
        var outbox = outboxWith([
            .upsertPost(post(tier: .onTime)),
            .upsertPost(post(id: otherPostID, prayer: .asr)),
        ])
        outbox.enqueue(.upsertPost(post(tier: .closeCall)), id: UUID(), at: stamp(9))

        XCTAssertEqual(outbox.count, 2, "the newer upsert replaces the older one")
        guard case .upsertPost(let head)? = outbox.peek?.op else {
            return XCTFail("expected the replaced upsert to hold its place at the head")
        }
        XCTAssertEqual(head.tier, .closeCall, "the newer payload wins")
        XCTAssertEqual(head.id, postID)
    }

    func testRecoveryWeekAndExcusedCollapsePerKey() {
        var outbox = outboxWith([
            .setRecoveryWeek(weekKey: "2026-W24", xp: 5),
            .setRecoveryWeek(weekKey: "2026-W24", xp: 12),
        ])
        XCTAssertEqual(outbox.count, 1, "one week, one write")
        XCTAssertEqual(outbox.peek?.op, CircleOp.setRecoveryWeek(weekKey: "2026-W24", xp: 12))

        outbox.enqueue(.setRecoveryWeek(weekKey: "2026-W25", xp: 3), id: UUID(), at: stamp(3))
        XCTAssertEqual(outbox.count, 2, "a different week is a different row")

        var excused = outboxWith([
            .setExcused(dayKey: monday, excused: true),
            .setExcused(dayKey: monday, excused: false),
        ])
        XCTAssertEqual(excused.count, 1)
        XCTAssertEqual(excused.peek?.op, CircleOp.setExcused(dayKey: monday, excused: false))
        excused.enqueue(.setExcused(dayKey: tuesday, excused: true), id: UUID(), at: stamp(4))
        XCTAssertEqual(excused.count, 2)
    }

    func testChallengeCreateThenDeleteCancels() {
        let challenge = RemoteCustomChallenge(id: "custom-9", circleID: circleID,
                                              createdBy: userA, prayer: .fajr, days: 3)
        let cancelled = outboxWith([.upsertChallenge(challenge),
                                    .deleteChallenge(challengeID: "custom-9")])
        XCTAssertTrue(cancelled.isEmpty)

        let unrelated = outboxWith([.upsertChallenge(challenge),
                                    .deleteChallenge(challengeID: "custom-other")])
        XCTAssertEqual(unrelated.count, 2, "deleting a different challenge cancels nothing")
    }

    func testRepeatedPhotoUploadForOnePostCollapses() {
        let outbox = outboxWith([
            .uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "a.jpg", path: "c/u/a.jpg"),
            .uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "b.jpg", path: "c/u/b.jpg"),
            .uploadPhoto(postID: otherPostID, dayKey: monday, prayer: .asr, utcOffset: nil, filename: "c.jpg", path: "c/u/c.jpg"),
        ])
        XCTAssertEqual(outbox.count, 2)
        XCTAssertEqual(outbox.peek?.op,
                       CircleOp.uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "b.jpg", path: "c/u/b.jpg"))
    }

    func testALongOfflineStretchCollapsesToTheRealWork() {
        // 40 dhikr taps in one week become ONE weekly write; a day re-logged
        // five times becomes one upsert.
        var outbox = CircleOutbox.empty
        for tap in 1...40 {
            outbox.enqueue(.setRecoveryWeek(weekKey: "2026-W24", xp: tap),
                           id: UUID(), at: stamp(TimeInterval(tap)))
        }
        for tier in [LogTier.onTime, .prayed, .lastCall, .closeCall, .qada] {
            outbox.enqueue(.upsertPost(post(tier: tier)), id: UUID(), at: stamp(100))
        }
        XCTAssertEqual(outbox.count, 2)
    }

    // MARK: - Outbox ordering + persistence

    func testFIFOOrderSurvivesASaveLoadRoundTrip() throws {
        let ids: [UUID] = (0..<4).map { _ in UUID() }
        let ops: [CircleOp] = [
            .upsertPost(post()),
            .uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr, utcOffset: nil, filename: "a.jpg", path: "c/u/a.jpg"),
            .setExcused(dayKey: tuesday, excused: true),
            .setRecoveryWeek(weekKey: "2026-W24", xp: 30),
        ]
        var outbox = CircleOutbox.empty
        for (index, op) in ops.enumerated() {
            outbox.enqueue(op, id: ids[index], at: stamp(TimeInterval(index)))
        }

        let data = try encoder().encode(outbox)
        var restored = try decoder().decode(CircleOutbox.self, from: data)

        XCTAssertEqual(restored.items.map(\.id), ids, "FIFO order is the contract")
        XCTAssertEqual(restored.items.map(\.op), ops)
        XCTAssertEqual(restored.items.map(\.createdAt),
                       (0..<4).map { stamp(TimeInterval($0)) })

        // Draining takes the head and leaves it in place until it is acked —
        // an op removed before the server confirms it is an op silently lost.
        let head = restored.checkout()
        XCTAssertEqual(head?.id, ids[0])
        XCTAssertEqual(restored.items.map(\.id), ids, "the head stays queued while in flight")
        XCTAssertEqual(restored.inFlightID, ids[0])

        restored.remove(id: ids[0])
        XCTAssertEqual(restored.items.map(\.id), Array(ids.dropFirst()))
        XCTAssertNil(restored.inFlightID, "acking the head clears the wire")

        restored.remove(id: ids[2])
        XCTAssertEqual(restored.items.map(\.id), [ids[1], ids[3]])
    }

    func testAnUndecodableItemCostsOnlyThatItem() throws {
        // A queue written by a NEWER build can hold an op this build cannot
        // run. Losing the whole file (Store falls back to an empty outbox)
        // would be far worse than skipping the one entry.
        let json = """
        {"items":[
          {"id":"AAAAAAAA-0000-0000-0000-000000000001",
           "op":{"kind":"deletePost","postID":"44444444-4444-4444-4444-444444444444"},
           "createdAt":"2026-06-08T12:00:00Z","attempts":0},
          {"id":"AAAAAAAA-0000-0000-0000-000000000002",
           "op":{"kind":"teleportPost","destination":"mars"},
           "createdAt":"2026-06-08T12:00:01Z","attempts":0},
          {"id":"AAAAAAAA-0000-0000-0000-000000000003",
           "op":{"kind":"setRecoveryWeek","weekKey":"2026-W24","xp":7},
           "createdAt":"2026-06-08T12:00:02Z","attempts":0}
        ]}
        """.data(using: .utf8)!
        let restored = try decoder().decode(CircleOutbox.self, from: json)

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.items.map { $0.op.kind }, [CircleOp.Kind.deletePost, .setRecoveryWeek])
    }

    // MARK: - The slot repair has to land on the row that refused the insert

    /// `scopedToSlot`'s zone predicate, spelled out. A write that matches zero
    /// rows fails SILENTLY — PostgREST reports success — so this string is the
    /// difference between repairing a post and stranding a JPEG in Storage with
    /// no row pointing at it and nothing able to collect it (§4).
    ///
    /// It has to match the row's own zone OR a zoneless legacy one, because the
    /// row that refuses a zoned insert is either a same-zone duplicate or a
    /// pre-v4 row with no offset — and `utc_offset = -25200` is never true of
    /// a NULL.
    func testTheSlotRepairMatchesItsOwnZoneOrTheLegacyZonelessRow() {
        XCTAssertEqual(SupabaseCircleTransport.zoneOrLegacyFilter(-25200),
                       "utc_offset.eq.-25200,utc_offset.is.null")
        XCTAssertEqual(SupabaseCircleTransport.zoneOrLegacyFilter(19800),
                       "utc_offset.eq.19800,utc_offset.is.null")
        // UTC is a real zone, not an absent one.
        XCTAssertEqual(SupabaseCircleTransport.zoneOrLegacyFilter(0),
                       "utc_offset.eq.0,utc_offset.is.null")
    }

    /// A `uploadPhoto` queued by a build older than this one has no zone, and
    /// decoding must keep the item rather than drop a prayer's photo over a
    /// filter that only matters mid-flight. nil means "don't narrow by zone",
    /// which is exactly what that build did.
    func testAPhotoUploadQueuedBeforeTheZoneExistedStillDecodes() throws {
        let legacy = """
        {"kind":"uploadPhoto","postID":"\(postID.uuidString)","dayKey":"\(monday)",
         "prayer":"dhuhr","filename":"a.jpg","path":"c/u/a.jpg"}
        """
        let op = try decoder().decode(CircleOp.self, from: Data(legacy.utf8))
        XCTAssertEqual(op, CircleOp.uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr,
                                                utcOffset: nil, filename: "a.jpg",
                                                path: "c/u/a.jpg"))
    }

    /// ...and a zone that IS present survives the round trip, or a traveller's
    /// second fajr would have its photo patched onto the first one's row.
    func testAPhotoUploadCarriesItsZoneThroughTheQueue() throws {
        let op = CircleOp.uploadPhoto(postID: postID, dayKey: monday, prayer: .dhuhr,
                                      utcOffset: -25200, filename: "a.jpg", path: "c/u/a.jpg")
        let round = try decoder().decode(CircleOp.self, from: encoder().encode(op))
        XCTAssertEqual(round, op)
    }

    // MARK: - Last call

    /// The reminder is suppressed by the prayer you PRAYED, not by the calendar
    /// date. A traveller who prayed Asr on Mumbai time in the air and landed in
    /// Seattle, where Asr's window is still ahead, is being offered the camera
    /// for it — and used to be the only prayer of the day with no reminder.
    func testLastCallSurvivesAZoneChangeOnTheSameDayKey() {
        let mumbai = 5 * 3600 + 1800
        let seattle = -7 * 3600
        let inTheAir = PrayerLog(id: UUID(), prayer: .asr, dayKey: monday,
                                 loggedAt: stamp(0), tier: .onTime, xp: LogTier.onTime.xp,
                                 utcOffset: mumbai)

        XCTAssertTrue(NotificationManager.needsLastCall(prayer: .asr, dayKey: monday,
                                                        currentOffset: seattle,
                                                        logs: [inTheAir]),
                      "Seattle's Asr has not been prayed; it needs its reminder")
        XCTAssertFalse(NotificationManager.needsLastCall(prayer: .asr, dayKey: monday,
                                                         currentOffset: mumbai,
                                                         logs: [inTheAir]),
                       "and staying put still silences it")

        // A pre-v4 log has no zone and matches anything, so nobody upgrading
        // starts getting reminders for prayers they already logged.
        let legacy = PrayerLog(id: UUID(), prayer: .asr, dayKey: monday, loggedAt: stamp(0),
                               tier: .onTime, xp: LogTier.onTime.xp)
        XCTAssertFalse(NotificationManager.needsLastCall(prayer: .asr, dayKey: monday,
                                                         currentOffset: seattle,
                                                         logs: [legacy]))
        // A DST hour is not a flight.
        let dst = PrayerLog(id: UUID(), prayer: .asr, dayKey: monday, loggedAt: stamp(0),
                            tier: .onTime, xp: LogTier.onTime.xp, utcOffset: -8 * 3600)
        XCTAssertFalse(NotificationManager.needsLastCall(prayer: .asr, dayKey: monday,
                                                         currentOffset: seattle, logs: [dst]))
    }

    func testRepeatedFailureEventuallyDropsTheItemSoTheQueueDrains() {
        var outbox = outboxWith([.upsertPost(post()), .setExcused(dayKey: monday, excused: true)])
        guard let stuck = outbox.peek?.id else { return XCTFail("expected a queued item") }

        for _ in 1..<CircleOutbox.maxAttempts {
            outbox.recordFailure(id: stuck)
        }
        XCTAssertEqual(outbox.count, 2, "still retrying")
        XCTAssertEqual(outbox.peek?.attempts, CircleOutbox.maxAttempts - 1)

        outbox.recordFailure(id: stuck)
        XCTAssertEqual(outbox.count, 1, "a poison op must not wedge the queue forever")
        XCTAssertEqual(outbox.peek?.op, CircleOp.setExcused(dayKey: monday, excused: true))

        outbox.removeAll()
        XCTAssertTrue(outbox.isEmpty)
    }
}
