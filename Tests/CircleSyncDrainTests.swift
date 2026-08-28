import Foundation
import XCTest
@testable import SalahBuddy

// MARK: - Doubles

/// Stands in for `AppState` + `CircleService`: who is signed in, which circle
/// is live, and the mirror everything renders from.
@MainActor
private final class DrainHost: CircleSyncHost {
    var syncUserID: UUID?
    var syncCircleID: UUID?
    var syncSnapshot: CircleSnapshot
    var syncIdentityGeneration: Int = 1
    /// Every mirror the sync layer committed, in order. A pull that fails must
    /// not add to this — that is what "never blank a rendered circle" means.
    var commits: [CircleSnapshot] = []

    init(user: UUID?, circle: UUID?, snapshot: CircleSnapshot) {
        syncUserID = user
        syncCircleID = circle
        syncSnapshot = snapshot
    }

    func applySyncedSnapshot(_ snapshot: CircleSnapshot) {
        syncSnapshot = snapshot
        commits.append(snapshot)
    }
}

/// The network, replaced by a list. Records what was sent and in what order,
/// fails on demand, and answers reads from a canned page.
@MainActor
private final class DrainTransport: CircleSyncTransport {
    struct FetchCall: Equatable {
        var since: Date?
        var window: CircleSyncWindow
    }

    /// Ops the server ACCEPTED, in the order it accepted them.
    var sent: [CircleOp] = []
    /// Every attempt, accepted or not.
    var attempts: Int = 0
    /// While non-nil, every write fails with this.
    var failure: (any Error)?

    var page: CircleSyncPage = CircleSyncPage()
    var fetchError: (any Error)?
    var fetches: [FetchCall] = []

    var subscribedTo: UUID?
    var stops: Int = 0

    func perform(_ op: CircleOp, circleID: UUID, userID: UUID) async throws {
        attempts += 1
        if let failure {
            throw failure
        }
        sent.append(op)
    }

    func fetch(circleID: UUID, since: Date?, window: CircleSyncWindow) async throws -> CircleSyncPage {
        fetches.append(FetchCall(since: since, window: window))
        if let fetchError {
            throw fetchError
        }
        // Faithful to `SupabaseCircleTransport.fetch`, which returns BEFORE it
        // reads the roster whenever this is a delta. Handing a delta a roster
        // here would let a test "prove" a refresh the shipping code never
        // performs — the exact shape of fake that makes a green suite a lie.
        guard since == nil else {
            var delta: CircleSyncPage = page
            delta.members = nil
            delta.profiles = nil
            return delta
        }
        return page
    }

    /// Reports whether the channel JOINED — false is how a dead channel gets
    /// retried instead of silently staying dead.
    var joinSucceeds: Bool = true

    func startRealtime(circleID: UUID,
                       onEvent: @escaping @Sendable @MainActor (CircleSyncSignal) -> Void) async -> Bool {
        guard joinSucceeds else { return false }
        subscribedTo = circleID
        return true
    }

    func stopRealtime() async {
        subscribedTo = nil
        stops += 1
    }
}

/// Where §6's friend-activity push would go. `CircleSync.announcer` is nil in
/// the app (it reaches `PushRegistrar.shared`); a test supplies one and gets to
/// watch the announcement without APNs, a network or a signed-in user.
///
/// Deliberately not actor-isolated: it is only ever touched from the main
/// actor, and leaving it plain means the recording closure compiles whatever
/// isolation the hook carries.
private final class AnnounceRecorder {
    var ids: [UUID] = []
}

// MARK: - Tests

/// v4 Phase C: the outbox drain, the pull merge, and the promise that a break
/// reason cannot leave the device.
///
/// Nothing here touches the network, `Store`, or the Supabase SDK: `CircleSync`
/// talks to a `CircleSyncTransport`, and this file supplies one made of arrays.
/// Every `CircleSync` under test is built with `persists: false`, so no test
/// writes into the app's Documents directory either.
@MainActor
final class CircleSyncDrainTests: XCTestCase {

    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let friend = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// 2026-06-08 is a Monday — the same week the other suites use.
    private let monday = "2026-06-08"
    private let tuesday = "2026-06-09"

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    // MARK: Fixtures

    private func circle() -> RemoteCircle {
        RemoteCircle(id: circleID, code: "ABC234", name: "Test", emoji: "🤝")
    }

    private func snapshot(posts: [RemotePost] = [],
                          excused: [RemoteExcusedDay] = [],
                          recovery: [RemoteRecoveryWeek] = [],
                          challenges: [RemoteCustomChallenge] = [],
                          alsoMembers: [UUID] = [],
                          lastSyncedAt: Date? = nil) -> CircleSnapshot {
        let members: [RemoteMember] = [RemoteMember(circleID: circleID, userID: me)]
            + alsoMembers.map { RemoteMember(circleID: circleID, userID: $0) }
        return CircleSnapshot(circle: circle(), me: me,
                       profiles: [], members: members,
                       posts: posts, excusedDays: excused, recoveryWeeks: recovery,
                       challenges: challenges, lastSyncedAt: lastSyncedAt)
    }

    private func log(_ prayer: Prayer, dayKey: String, id: UUID = UUID(),
                     tier: LogTier = .onTime, photo: String? = nil,
                     placeTag: PlaceTag? = nil, placeName: String? = nil,
                     utcOffset: Int? = -7 * 3600) -> PrayerLog {
        // A REAL zone by default — see the note on CircleMirrorTests.log. With
        // nil here the "zone rides along" assertion compared nil to nil.
        PrayerLog(id: id, prayer: prayer, dayKey: dayKey, loggedAt: stamp(0), tier: tier,
                  xp: GameEngine.prayerXP(tier: tier, jamaat: false),
                  photoFilename: photo, jamaat: false,
                  placeTag: placeTag, placeName: placeName, utcOffset: utcOffset)
    }

    private func post(_ prayer: Prayer, dayKey: String, user: UUID,
                      id: UUID = UUID(), tier: LogTier = .onTime,
                      utcOffset: Int? = nil, at: Date? = nil,
                      photoPath: String? = nil) -> RemotePost {
        RemotePost(id: id, userID: user, circleID: circleID, dayKey: dayKey,
                   prayer: prayer, tier: tier, loggedAt: at ?? stamp(0),
                   photoPath: photoPath, utcOffset: utcOffset)
    }

    /// A sync wired to a live circle, with the network replaced.
    private func makeSync(host: DrainHost,
                          transport: DrainTransport) -> CircleSync {
        CircleSync(host: host, transport: transport, reachability: nil,
                   outbox: CircleOutbox.empty, persists: false)
    }

    /// The same, with a network switch the test can flip.
    private func makeSync(host: DrainHost, transport: DrainTransport,
                          reachability: Reachability) -> CircleSync {
        CircleSync(host: host, transport: transport, reachability: reachability,
                   outbox: CircleOutbox.empty, persists: false)
    }

    private func liveHost(_ snapshot: CircleSnapshot? = nil) -> DrainHost {
        DrainHost(user: me, circle: circleID, snapshot: snapshot ?? self.snapshot())
    }

    // MARK: - Drain order and the ack protocol

    func testDrainSendsEveryQueuedWriteInFIFOOrder() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday), photoFilename: nil, travelCombined: false)
        sync.excusedChanged(dayKey: tuesday, on: true)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 40)
        await sync.drain()

        XCTAssertEqual(transport.sent.count, 3)
        XCTAssertEqual(transport.sent[0].kind, .upsertPost)
        XCTAssertEqual(transport.sent[1].kind, .setExcused)
        XCTAssertEqual(transport.sent[2].kind, .setRecoveryWeek)
        // Acknowledged: the queue is empty and the UI has nothing to report.
        XCTAssertTrue(sync.outbox.isEmpty)
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertEqual(sync.status, .idle)
    }

    // MARK: - The friend-activity push (§6)

    /// v4 Phase D FIX: an acknowledged post is the ONE moment the app knows a
    /// post is on the server, and it used to tell nobody —
    /// `PushRegistrar.announcePost` had no call site anywhere in `Sources/`, so
    /// "📸 X posted first for Fajr" could never fire and the server's
    /// `kind: "post"` path was never once exercised. The ack is also what the
    /// function requires: it looks the post up by id and answers
    /// `post_not_found` for a row that is not there yet.
    func testAnAcknowledgedPostAnnouncesItself() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)
        let recorder = AnnounceRecorder()
        sync.announcer = { id in recorder.ids.append(id) }

        let entry: PrayerLog = log(.fajr, dayKey: monday)
        sync.postLogged(entry)
        await sync.drain()
        // One post, one announcement, however many times the queue is drained.
        // The server's `posts.notified_at` lease is the real belt; this is the
        // braces.
        await sync.drain()

        XCTAssertEqual(recorder.ids, [entry.id])
    }

    /// Nothing is announced until the SERVER has it. A failing write holds the
    /// queue, and a push about a post nobody can look up is the
    /// `post_not_found` reply.
    func testAQueuedPostIsNotAnnouncedWhileItIsStillQueued() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)
        let recorder = AnnounceRecorder()
        sync.announcer = { id in recorder.ids.append(id) }

        sync.postLogged(log(.fajr, dayKey: monday))
        await sync.drain()
        XCTAssertTrue(recorder.ids.isEmpty)

        transport.failure = nil
        // `retryNow()` rather than `drain()`: a failed item carries a backoff
        // stamp, and only the retry path clears it.
        await sync.retryNow()
        XCTAssertEqual(recorder.ids.count, 1, "and it goes out when the write lands")
    }

    /// Undo before the write lands: the delete cancels the queued create, and
    /// the announcement goes with it. (The registrar's own guard covers the
    /// narrower case where the create was already on the wire — a post the
    /// person has taken back must not wake anybody either way.)
    func testARetractedPostIsNeverAnnounced() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)
        let recorder = AnnounceRecorder()
        sync.announcer = { id in recorder.ids.append(id) }

        let entry: PrayerLog = log(.fajr, dayKey: monday)
        sync.postLogged(entry)
        await sync.drain()
        sync.postRetracted(entry)

        transport.failure = nil
        await sync.retryNow()
        XCTAssertTrue(recorder.ids.isEmpty)
    }

    /// The join backfill publishes prayers that already happened, some of them
    /// days ago (§2). Announcing them would fire "posted first for Fajr" up to
    /// 35 times the moment somebody joins, for windows that closed on Monday.
    func testTheJoinBackfillAnnouncesNothing() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)
        let recorder = AnnounceRecorder()
        sync.announcer = { id in recorder.ids.append(id) }

        let now: Date = AppClock.now
        let todayKey: String = AppClock.dayKey(for: now)
        let week: [PrayerLog] = [
            PrayerLog(id: UUID(), prayer: .fajr, dayKey: todayKey,
                      loggedAt: now.addingTimeInterval(-3600), tier: .onTime,
                      xp: GameEngine.prayerXP(tier: .onTime, jamaat: false)),
            PrayerLog(id: UUID(), prayer: .dhuhr, dayKey: todayKey,
                      loggedAt: now.addingTimeInterval(-1800), tier: .prayed,
                      xp: GameEngine.prayerXP(tier: .prayed, jamaat: false))
        ]
        sync.backfillWeek(week, asOf: now)
        await sync.drain()

        XCTAssertEqual(transport.sent.count, 2, "the facts are still shared")
        XCTAssertTrue(recorder.ids.isEmpty, "and nobody's phone buzzes for them")
    }

    func testTwoQueuedWritesBothLandInOneDrain() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        sync.postLogged(log(.dhuhr, dayKey: monday))
        await sync.drain()
        XCTAssertTrue(sync.outbox.isEmpty)
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testAFailedWriteStaysAtTheHeadAndHoldsTheQueue() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        sync.postLogged(log(.dhuhr, dayKey: monday))
        await sync.drain()

        // Nothing was accepted, nothing was thrown away, and the order the
        // second write is owed in has not changed.
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertEqual(sync.outbox.count, 2)
        XCTAssertEqual(sync.pendingCount, 2)
        XCTAssertEqual(sync.discardedCount, 0)
        XCTAssertEqual(sync.lastError, .offline)
    }

    func testABackedOffHeadIsNotRetriedUntilItIsDue() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.timedOut)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        await sync.drain()
        let afterFirst: Int = transport.attempts
        XCTAssertGreaterThanOrEqual(afterFirst, 1)

        // Immediately again: the backoff has not expired, so the wire stays
        // quiet. This is what stops a failing queue becoming a spin.
        await sync.drain()
        XCTAssertEqual(transport.attempts, afterFirst)
        XCTAssertNotNil(sync.nextAttemptDate(for: sync.outbox.peek!.id))
    }

    // MARK: - Backoff bookkeeping

    func testBackoffDoublesAndIsCapped() {
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 1), 2)
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 2), 4)
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 3), 8)
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 4), 16)
        // Capped, and it stays capped however long the outage runs.
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 20), CircleSyncTuning.retryMaxDelay)
        XCTAssertEqual(CircleSync.backoffDelay(forAttempt: 200), CircleSyncTuning.retryMaxDelay)
    }

    func testEachFailureIsCountedAgainstTheItem() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        await sync.drain()
        let id: UUID = sync.outbox.peek!.id
        let first: Int = sync.failureCount(for: id)
        XCTAssertGreaterThanOrEqual(first, 1)

        // `retryNow` is the "try again" button: it forgets the WAIT but not the
        // history, so the count keeps climbing.
        await sync.retryNow()
        XCTAssertGreaterThan(sync.failureCount(for: id), first)
    }

    // MARK: - A poison item is kept, or given up on loudly

    func testAnOfflineStretchNeverDiscardsAWrite() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        // Far more failures than `CircleOutbox.maxAttempts`: a fortnight in
        // airplane mode must not cost a prayer post.
        for _ in 0..<(CircleOutbox.maxAttempts * 2) {
            await sync.retryNow()
        }

        XCTAssertEqual(sync.outbox.count, 1)
        XCTAssertEqual(sync.discardedCount, 0)
        XCTAssertNil(sync.lastDiscarded)
        // And it is SURFACED, not silent.
        XCTAssertNotNil(sync.stalledItem)
        XCTAssertEqual(sync.status, .waiting(count: 1, reason: .offline))
    }

    func testAServerRefusalIsGivenUpOnLoudlyAndTheQueueMovesOn() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = CircleService.unknownCode   // SB404, a refusal the server uttered
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        for _ in 0..<(CircleOutbox.maxAttempts + 2) {
            await sync.retryNow()
        }

        XCTAssertEqual(sync.discardedCount, 1)
        XCTAssertEqual(sync.lastDiscarded, .unknownCode)
        XCTAssertTrue(sync.outbox.isEmpty)

        // The queue is usable again: the next write goes out normally.
        transport.failure = nil
        sync.postLogged(log(.dhuhr, dayKey: monday))
        await sync.drain()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(sync.discardedCount, 1)
    }

    // MARK: - Replay idempotence

    func testAReplayLandsOnTheSameRowAndTheSamePhotoObject() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        let entry: PrayerLog = log(.asr, dayKey: monday, photo: "asr.jpg")
        sync.postLogged(entry, photoFilename: "asr.jpg")
        await sync.drain()
        // The acknowledgement is lost and the app re-queues the same log.
        sync.postLogged(entry, photoFilename: "asr.jpg")
        await sync.drain()

        let posts: [RemotePost] = transport.sent.compactMap { (op: CircleOp) -> RemotePost? in
            if case .upsertPost(let post) = op { return post }
            return nil
        }
        XCTAssertEqual(posts.count, 2)
        // Same primary key both times: the second write is an upsert onto the
        // first row, not a second post in the same cell.
        XCTAssertEqual(posts[0].id, entry.id)
        XCTAssertEqual(posts[1].id, entry.id)

        let paths: [String] = transport.sent.compactMap { (op: CircleOp) -> String? in
            if case .uploadPhoto(_, _, _, _, _, let path) = op { return path }
            return nil
        }
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0], paths[1])
    }

    func testQueueingTheSamePostTwiceBeforeItDrainsCollapsesToOneWrite() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        let entry: PrayerLog = log(.isha, dayKey: monday)
        sync.postLogged(entry)
        sync.postLogged(entry)
        XCTAssertEqual(sync.outbox.count, 1)
    }

    // MARK: - Merge: delta adds and updates, full read reconciles

    func testDeltaMergeAddsAndUpdatesWithoutTouchingUnrelatedRows() {
        let mineID = UUID()
        let mine: RemotePost = post(.fajr, dayKey: monday, user: me, id: mineID, tier: .prayed)
        let theirs: RemotePost = post(.dhuhr, dayKey: monday, user: friend)
        let base: CircleSnapshot = snapshot(posts: [mine, theirs])

        let updated: RemotePost = post(.fajr, dayKey: monday, user: me, id: mineID, tier: .onTime)
        let fresh: RemotePost = post(.asr, dayKey: monday, user: friend)
        let page = CircleSyncPage(posts: [updated, fresh])

        let merged: CircleSnapshot = CircleSync.merged(base, delta: page)

        XCTAssertEqual(merged.posts.count, 3)
        XCTAssertEqual(merged.post(userID: me, dayKey: monday, prayer: .fajr,
                                   asOf: .distantFuture)?.tier, .onTime)
        // The row nobody mentioned is exactly as it was.
        XCTAssertEqual(merged.post(userID: friend, dayKey: monday, prayer: .dhuhr,
                                   asOf: .distantFuture), theirs)
        XCTAssertNotNil(merged.post(userID: friend, dayKey: monday, prayer: .asr,
                                    asOf: .distantFuture))
    }

    func testADeltaThatMentionsNothingLeavesTheMirrorAlone() {
        let base: CircleSnapshot = snapshot(posts: [post(.fajr, dayKey: monday, user: friend)],
                                            excused: [RemoteExcusedDay(userID: friend,
                                                                       circleID: circleID,
                                                                       dayKey: monday)])
        let merged: CircleSnapshot = CircleSync.merged(base, delta: CircleSyncPage())
        XCTAssertEqual(merged, base)
    }

    func testARelogInTheSameCellReplacesTheStaleRow() {
        // Undo + re-log gives the prayer a NEW row id in the same
        // (user, day, prayer) slot. Two rows in one cell would draw twice.
        let old: RemotePost = post(.maghrib, dayKey: monday, user: friend, id: UUID(), tier: .lastCall)
        let new: RemotePost = post(.maghrib, dayKey: monday, user: friend, id: UUID(), tier: .onTime)
        let base: CircleSnapshot = snapshot(posts: [old])

        let merged: CircleSnapshot = CircleSync.merged(base, delta: CircleSyncPage(posts: [new]))
        XCTAssertEqual(merged.posts.count, 1)
        XCTAssertEqual(merged.posts.first?.id, new.id)
    }

    func testTwoSameDayFajrsFromDifferentZonesBothSurviveTheMerge() {
        // v4: the server's uniqueness key gained utc_offset (migration
        // 20260822000300) because a long-haul flight makes two genuinely
        // different prayers share one day_key. `slotKey` mirrors that key, so
        // the mirror has to hold both rows — collapsing them here would drop a
        // prayer that the database kept.
        let mumbai: RemotePost = post(.fajr, dayKey: monday, user: friend,
                                      id: UUID(), utcOffset: 5 * 3600 + 1800)
        let seattle: RemotePost = post(.fajr, dayKey: monday, user: friend,
                                       id: UUID(), utcOffset: -7 * 3600)
        let base: CircleSnapshot = snapshot(posts: [mumbai])

        let merged: CircleSnapshot = CircleSync.merged(base, delta: CircleSyncPage(posts: [seattle]))
        XCTAssertEqual(merged.posts.count, 2, "two zones, two prayers, two rows")
        XCTAssertEqual(Set(merged.posts.map(\.id)), [mumbai.id, seattle.id])
    }

    func testARelogInTheSameZoneStillCollapses() {
        // The other half of the same rule: an undo-and-relog of one prayer in
        // one place is still ONE row on the server and must be one here. The
        // traveller's exemption is not a licence to draw a cell twice.
        let zone: Int = -7 * 3600
        let old: RemotePost = post(.maghrib, dayKey: monday, user: friend,
                                   id: UUID(), tier: .lastCall, utcOffset: zone)
        let new: RemotePost = post(.maghrib, dayKey: monday, user: friend,
                                   id: UUID(), tier: .onTime, utcOffset: zone)
        let base: CircleSnapshot = snapshot(posts: [old])

        let merged: CircleSnapshot = CircleSync.merged(base, delta: CircleSyncPage(posts: [new]))
        XCTAssertEqual(merged.posts.count, 1)
        XCTAssertEqual(merged.posts.first?.id, new.id)
    }

    func testZonelessLegacyPostsStillCollapseIntoOneSlot() {
        // `slotKey`'s spelling of the constraint's NULLS NOT DISTINCT. Every
        // post written before 20260822000200 has no offset; if "no offset"
        // rendered as something unique per row, all of history would stop
        // deduping at once.
        let old: RemotePost = post(.asr, dayKey: monday, user: friend, id: UUID(), tier: .lastCall)
        let new: RemotePost = post(.asr, dayKey: monday, user: friend, id: UUID(), tier: .onTime)
        let merged: CircleSnapshot = CircleSync.merged(snapshot(posts: [old]),
                                                       delta: CircleSyncPage(posts: [new]))
        XCTAssertEqual(merged.posts.count, 1)
        XCTAssertEqual(merged.posts.first?.id, new.id)

        // ...and a zoneless row is a WILDCARD, not a third zone: a zoned row for
        // the same prayer DISPLACES it rather than sitting beside it.
        //
        // This is the pair the v4 rollout produces on its own — one device on
        // an old build writes the zoneless row, the same account's second
        // device writes the zoned one — and it is one prayer, not two. Left
        // side by side, no later delta could displace either (their slot keys
        // differ), `CircleSnapshot.prayerLogs` fed both into `GameEngine`, and
        // that member's weekly score read a whole prayer high on every other
        // device in the circle. 20260822000400 refuses the pair server-side;
        // this is the mirror agreeing.
        let zoned: RemotePost = post(.asr, dayKey: monday, user: friend,
                                     id: UUID(), utcOffset: -7 * 3600)
        let healed: CircleSnapshot = CircleSync.merged(merged, delta: CircleSyncPage(posts: [zoned]))
        XCTAssertEqual(healed.posts.count, 1, "a zoneless post matches every zone")
        XCTAssertEqual(healed.posts.first?.id, zoned.id, "incoming is the server, and it wins")

        // And the other way round: a zoneless row arriving over a zoned one is
        // still the same prayer. Symmetry matters — whichever order the two
        // devices reach this mirror in, it must settle on one row.
        let backwards: CircleSnapshot = CircleSync.merged(
            snapshot(posts: [zoned]), delta: CircleSyncPage(posts: [old]))
        XCTAssertEqual(backwards.posts.count, 1)
        XCTAssertEqual(backwards.posts.first?.id, old.id)
    }

    // MARK: One member, one cell, two prayers

    /// A traveller's slot holds two rows, and the cell drawing it must pick one
    /// BY A RULE rather than by array order.
    ///
    /// Maghrib in London at 20:00 BST, a flight, Maghrib in New York at 19:45
    /// EDT on the same local date. Both rows are real and both survive. The
    /// lookup used to take `first`, so when a photo patch bumped the London
    /// row's `updated_at`, the next delta re-appended it at the END of the
    /// array and the cell silently switched to the other prayer's photo, tier
    /// and time — with nobody touching anything.
    func testATravellersCellPicksTheLatestPrayerThatHasHappened() {
        let london = post(.maghrib, dayKey: monday, user: friend, id: UUID(),
                          tier: .onTime, utcOffset: 3600, at: stamp(0),
                          photoPath: "c/u/london.jpg")
        let newYork = post(.maghrib, dayKey: monday, user: friend, id: UUID(),
                           tier: .lastCall, utcOffset: -4 * 3600, at: stamp(5 * 3600),
                           photoPath: "c/u/newyork.jpg")
        let now = stamp(6 * 3600)

        for order in [[london, newYork], [newYork, london]] {
            let mirror: CircleSnapshot = snapshot(posts: order, alsoMembers: [friend])
            XCTAssertEqual(mirror.post(userID: friend, dayKey: monday, prayer: .maghrib,
                                       asOf: now)?.id,
                           newYork.id,
                           "the latest prayer that has actually happened, whatever the array order")
            XCTAssertEqual(mirror.posts(userID: friend, dayKey: monday, prayer: .maghrib)
                             .map(\.id),
                           [london.id, newYork.id],
                           "and the slot itself is ordered by the data, not by the array")

            // The tile and the photograph behind it are resolved at the same
            // instant by the same rule, so a cell can never show one prayer's
            // tier above the other one's picture.
            let source = RemoteCircleDataSource(snapshot: mirror)
            let (state, _) = source.entry(forMember: friend.uuidString, prayer: .maghrib,
                                          dayKey: monday, window: nil, now: now)
            guard case .posted(_, let tier, let at) = state else {
                return XCTFail("expected a posted square")
            }
            XCTAssertEqual(tier, newYork.tier)
            XCTAssertEqual(at, newYork.loggedAt)
            XCTAssertEqual(source.photoPath(forMember: friend.uuidString, prayer: .maghrib,
                                            dayKey: monday, asOf: now),
                           newYork.photoPath)
        }
    }

    /// The cell only ever moves FORWARD in time. Before the second prayer's
    /// `loggedAt` arrives, the square is still the first one's — it must not
    /// jump ahead to a prayer that has not happened yet, and it must not fall
    /// back to "missed" either.
    func testACellDoesNotJumpAheadToAPrayerThatHasNotHappenedYet() {
        let london = post(.maghrib, dayKey: monday, user: friend, id: UUID(),
                          tier: .onTime, utcOffset: 3600, at: stamp(0))
        let newYork = post(.maghrib, dayKey: monday, user: friend, id: UUID(),
                           tier: .lastCall, utcOffset: -4 * 3600, at: stamp(5 * 3600))
        let mirror: CircleSnapshot = snapshot(posts: [newYork, london],
                                              alsoMembers: [friend])

        XCTAssertEqual(mirror.post(userID: friend, dayKey: monday, prayer: .maghrib,
                                   asOf: stamp(3600))?.id, london.id)
        XCTAssertEqual(mirror.post(userID: friend, dayKey: monday, prayer: .maghrib,
                                   asOf: stamp(5 * 3600))?.id, newYork.id)

        // Nothing has arrived yet: the earliest row is handed back so the
        // caller can hold the square rather than flashing "missed".
        XCTAssertEqual(mirror.post(userID: friend, dayKey: monday, prayer: .maghrib,
                                   asOf: stamp(-3600))?.id, london.id)
        let source = RemoteCircleDataSource(snapshot: mirror)
        XCTAssertEqual(source.cell(forMember: friend.uuidString, prayer: .maghrib,
                                   dayKey: monday, window: nil, now: stamp(-3600)),
                       .future, "held, not flashed as missed")
        // ...and once the first prayer has landed the cell is ITS tier, not the
        // one still in the future — proof the assertion above is not passing
        // because the member is invisible.
        XCTAssertEqual(source.cell(forMember: friend.uuidString, prayer: .maghrib,
                                   dayKey: monday, window: nil, now: stamp(3600)),
                       .inWindow(london.tier))
        XCTAssertEqual(source.cell(forMember: friend.uuidString, prayer: .maghrib,
                                   dayKey: monday, window: nil, now: stamp(5 * 3600)),
                       .inWindow(newYork.tier))
    }

    /// Two rows with two DIFFERENT real zones are two prayers and both score.
    /// A zoneless row beside a zoned one is ONE prayer written twice and must
    /// not — that pair is what inflated a member's weekly total by a whole
    /// prayer on everybody else's device.
    func testOnlyGenuinelyDifferentZonesScoreTwice() {
        let mumbai: Int = 5 * 3600 + 1800
        let both: CircleSnapshot = snapshot(posts: [
            post(.fajr, dayKey: monday, user: friend, id: UUID(), utcOffset: mumbai),
            post(.fajr, dayKey: monday, user: friend, id: UUID(), utcOffset: -7 * 3600),
        ])
        XCTAssertEqual(both.prayerLogs(userID: friend).count, 2,
                       "two real prayers, hours apart, sharing a calendar date")

        let legacyPlusZoned: CircleSnapshot = CircleSync.merged(
            snapshot(posts: [post(.fajr, dayKey: monday, user: friend, id: UUID())]),
            delta: CircleSyncPage(posts: [post(.fajr, dayKey: monday, user: friend,
                                               id: UUID(), utcOffset: -7 * 3600)]))
        XCTAssertEqual(legacyPlusZoned.prayerLogs(userID: friend).count, 1,
                       "a zoneless row matches every zone — it cannot also be a second prayer")
    }

    func testFullPullRemovesRowsThatVanishedServerSide() {
        let kept: RemotePost = post(.fajr, dayKey: monday, user: friend)
        let deletedElsewhere: RemotePost = post(.dhuhr, dayKey: monday, user: friend)
        let base: CircleSnapshot = snapshot(posts: [kept, deletedElsewhere],
                                            excused: [RemoteExcusedDay(userID: friend,
                                                                       circleID: circleID,
                                                                       dayKey: monday)],
                                            challenges: [RemoteCustomChallenge(id: "custom-1",
                                                                               circleID: circleID,
                                                                               createdBy: friend,
                                                                               prayer: .fajr,
                                                                               days: 3)])
        let page = CircleSyncPage(posts: [kept], excusedDays: [], recoveryWeeks: [], challenges: [])

        let merged: CircleSnapshot = CircleSync.merged(base, full: page, circleID: circleID)

        XCTAssertEqual(merged.posts, [kept])
        XCTAssertTrue(merged.excusedDays.isEmpty)
        XCTAssertTrue(merged.challenges.isEmpty)
        // A collection the page did not fetch is left alone rather than emptied.
        XCTAssertEqual(merged.members, base.members)
    }

    func testAFullPullKeepsWhatItDidNotAskFor() {
        let base: CircleSnapshot = snapshot(posts: [post(.fajr, dayKey: monday, user: friend)])
        let merged: CircleSnapshot = CircleSync.merged(base, full: CircleSyncPage(),
                                                       circleID: circleID)
        XCTAssertEqual(merged, base)
    }

    func testRecoveryAndExcusedRoundTripThroughADelta() {
        let base: CircleSnapshot = snapshot()
        let page = CircleSyncPage(
            excusedDays: [RemoteExcusedDay(userID: friend, circleID: circleID, dayKey: monday)],
            recoveryWeeks: [RemoteRecoveryWeek(userID: friend, circleID: circleID,
                                               weekKey: "2026-W24", xp: 55)])
        let merged: CircleSnapshot = CircleSync.merged(base, delta: page)
        XCTAssertTrue(merged.isExcused(userID: friend, dayKey: monday))
        XCTAssertEqual(merged.recoveryXP(userID: friend, weekKeys: ["2026-W24"]), 55)
    }

    // MARK: - Pull safety

    func testAFailedPullNeverBlanksTheCircle() async {
        let existing: RemotePost = post(.fajr, dayKey: monday, user: friend)
        let host: DrainHost = liveHost(snapshot(posts: [existing]))
        let transport = DrainTransport()
        transport.fetchError = URLError(.networkConnectionLost)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        await sync.pull(since: nil)

        XCTAssertTrue(host.commits.isEmpty)
        XCTAssertEqual(host.syncSnapshot.posts, [existing])
        XCTAssertEqual(sync.lastError, .offline)
    }

    func testASuccessfulPullCommitsAndStampsTheMirror() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.page = CircleSyncPage(posts: [post(.fajr, dayKey: monday, user: friend)])
        let sync: CircleSync = makeSync(host: host, transport: transport)

        await sync.pull(since: nil)

        XCTAssertEqual(host.commits.count, 1)
        XCTAssertEqual(host.syncSnapshot.posts.count, 1)
        XCTAssertNil(sync.lastError)
    }

    /// v4 Phase C: the delta cursor is the SERVER's clock, not this device's.
    ///
    /// This replaces a weaker assertion (`lastSyncedAt` is merely non-nil after
    /// a pull) that `AppClock.now` satisfied. It could not: the cursor is handed
    /// straight back as `updated_at > <cursor>`, a column Postgres stamps, so a
    /// device clock more than `deltaOverlap` fast asked for rows from the
    /// server's future and every delta came back empty, silently, forever.
    func testTheDeltaCursorComesFromTheServersOwnStamp() async {
        let serverStamp: Date = stamp(5_000)
        var fresh: RemotePost = post(.fajr, dayKey: monday, user: friend)
        fresh.updatedAt = serverStamp
        var older: RemotePost = post(.dhuhr, dayKey: monday, user: friend)
        older.updatedAt = serverStamp.addingTimeInterval(-600)

        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.page = CircleSyncPage(posts: [older, fresh])
        let sync: CircleSync = makeSync(host: host, transport: transport)

        await sync.pull(since: nil)
        XCTAssertEqual(host.syncSnapshot.lastSyncedAt, serverStamp)

        // And the next delta starts from it, backdated only by the overlap.
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.last?.since,
                       serverStamp.addingTimeInterval(-CircleSyncTuning.deltaOverlap))
    }

    /// A quiet page must not move the window past rows nobody has read.
    func testAPageWithNoServerStampsKeepsThePreviousCursor() async {
        let previous: Date = stamp(900)
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: previous))
        let transport = DrainTransport()
        transport.page = CircleSyncPage(posts: [])
        let sync: CircleSync = makeSync(host: host, transport: transport)

        await sync.pull(since: nil)
        XCTAssertEqual(host.syncSnapshot.lastSyncedAt, previous)
    }

    func testAPullForADifferentCircleIsNotCommitted() async {
        // The mirror moved on to another circle while the read was in flight.
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)
        host.syncSnapshot = CircleSnapshot(circle: RemoteCircle(id: UUID(), code: "ZZZ234"), me: me)

        await sync.pull(since: nil)
        XCTAssertTrue(host.commits.isEmpty)
    }

    // MARK: - Realtime is a signal, never a data path

    func testADeleteEventForcesAFullReadAndAChangeUsesTheDelta() async {
        let synced: Date = stamp(0)
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: synced))
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        // The launch's reconciling read, which is what `start()` does — and the
        // precondition for the assertion below: an unreconciled roster promotes
        // the next pull whatever the signal said, so without this the "a change
        // uses the delta" half would be measuring the wrong rule.
        await sync.pull(since: nil)
        XCTAssertEqual(transport.fetches.count, 1)
        XCTAssertNil(transport.fetches[0].since)

        sync.signalArrived(.changed)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 2)
        // The delta is backdated by the overlap so a row written in the second
        // straddling the last sync is not lost forever.
        XCTAssertEqual(transport.fetches[1].since,
                       synced.addingTimeInterval(-CircleSyncTuning.deltaOverlap))

        sync.signalArrived(.deleted)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 3)
        // A deletion is invisible to `updated_at`, so only the reconciling read
        // can notice it.
        XCTAssertNil(transport.fetches[2].since)
    }

    // MARK: - A join push refreshes the roster (v4 Phase D)

    /// THE regression, end to end through the same door realtime uses.
    ///
    /// `circle_members` is deliberately outside the realtime publication (its
    /// DELETE payload is the whole user→circle graph) and outside the cheap
    /// delta, so a friend joining a circle whose app was already open refreshed
    /// NOTHING until a cold launch: their posts arrived on the next delta and
    /// drew as nobody, because every screen resolves a post through the members
    /// it knows about. The join push is the only thing that can say so.
    func testAJoinPushRefreshesTheRosterAndProfilesIntoTheMirror() async {
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: stamp(0)))
        let transport = DrainTransport()
        transport.page = CircleSyncPage(
            posts: [],
            members: [RemoteMember(circleID: circleID, userID: me),
                      RemoteMember(circleID: circleID, userID: friend, joinedAt: stamp(60))],
            profiles: [RemoteProfile(id: friend, name: "Yusuf", avatarEmoji: "🌙")])
        let sync: CircleSync = makeSync(host: host, transport: transport)
        // The launch read, so nothing below is riding on a never-reconciled
        // mirror — the join has to be what does this on its own.
        await sync.pull(since: nil)
        XCTAssertEqual(host.syncSnapshot.members.count, 2)

        // ...and now the friend is gone again and comes back, so the assertion
        // cannot pass on what the launch already fetched.
        host.syncSnapshot.members = [RemoteMember(circleID: circleID, userID: me)]
        host.syncSnapshot.profiles = []

        sync.signalArrived(CircleSyncSignal.forPush(.join))
        await sync.runDebouncedPull()

        XCTAssertNil(transport.fetches.last?.since,
                     "a join is answerable only by the pass that reads the roster")
        XCTAssertEqual(host.syncSnapshot.members.count, 2, "the new member is in the mirror")
        XCTAssertEqual(host.syncSnapshot.member(for: friend)?.name, "Yusuf",
                       "and their profile came with them, or the scoreboard draws a blank row")
    }

    /// The other half, which is what keeps the delta cheap: an ordinary post
    /// push is NOT a reason to re-read the roster.
    func testAPostPushStaysOnTheCheapDelta() async {
        let synced: Date = stamp(0)
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: synced))
        let transport = DrainTransport()
        transport.page = CircleSyncPage(
            posts: [],
            members: [RemoteMember(circleID: circleID, userID: me),
                      RemoteMember(circleID: circleID, userID: friend)],
            profiles: [])
        let sync: CircleSync = makeSync(host: host, transport: transport)
        await sync.pull(since: nil)

        sync.signalArrived(CircleSyncSignal.forPush(.post))
        await sync.runDebouncedPull()

        XCTAssertEqual(transport.fetches.last?.since,
                       synced.addingTimeInterval(-CircleSyncTuning.deltaOverlap),
                       "`posts` is published to realtime; a post push needs nothing extra")
    }

    /// A nudge is aimed at one person about their own prayer and changes
    /// nothing on the server — it still costs a delta, because the person who
    /// sent it is demonstrably live in the circle at that moment, and never a
    /// full read.
    func testANudgePushIsWorthNoMoreThanADelta() {
        XCTAssertEqual(CircleSyncSignal.forPush(.nudge), .changed)
        XCTAssertFalse(CircleSyncSignal.forPush(.nudge).needsReconcilingRead)
    }

    /// Nothing signals a DEPARTURE — no realtime event, no push — so the only
    /// thing standing between a mirror and a member who left is the clock.
    /// A mirror that has never been reconciled is stale by definition, which is
    /// what makes the very first signal of a session ask for everything.
    func testAnUnreconciledMirrorPromotesTheNextDeltaToTheFullRead() async {
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: stamp(0)))
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)
        XCTAssertNil(sync.lastReconciledAt)

        sync.signalArrived(.changed)
        await sync.runDebouncedPull()

        XCTAssertNil(transport.fetches.last?.since,
                     "the roster has never been read; a delta cannot fix that")
        XCTAssertNotNil(sync.lastReconciledAt, "and the reconciling read says so")
    }

    /// The rule itself, asserted without moving a clock.
    func testTheReconcileIntervalIsTheFloorUnderAStaleRoster() {
        let now: Date = stamp(100_000)
        let interval: TimeInterval = CircleSyncTuning.reconcileInterval

        XCTAssertTrue(CircleSync.needsReconcilingRead(requested: true,
                                                      lastReconciledAt: now, now: now),
                      "a signal that asked for one always wins")
        XCTAssertTrue(CircleSync.needsReconcilingRead(requested: false,
                                                      lastReconciledAt: nil, now: now),
                      "never reconciled is stale, not fresh")
        XCTAssertFalse(CircleSync.needsReconcilingRead(
            requested: false,
            lastReconciledAt: now.addingTimeInterval(-interval + 1), now: now),
                       "a burst of posts a minute after a full read stays a delta")
        XCTAssertTrue(CircleSync.needsReconcilingRead(
            requested: false,
            lastReconciledAt: now.addingTimeInterval(-interval), now: now),
                      "and the interval is a floor, not a maybe")
    }

    /// Leaving and joining another circle throws the stamp away with everything
    /// else: the new circle's roster has never been read, whatever the old
    /// one's age said.
    func testChangingCircleForgetsThatTheRosterWasEverRead() async {
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: stamp(0)))
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)
        // Anchor the generation the way the first enqueue or drain of a real
        // launch does, so the bump below reads as a CHANGE rather than as the
        // first identity this engine has ever seen.
        await sync.drain()
        await sync.pull(since: nil)
        XCTAssertNotNil(sync.lastReconciledAt)

        host.syncIdentityGeneration += 1
        await sync.drain()

        XCTAssertNil(sync.lastReconciledAt)
    }

    // MARK: - What never gets queued

    func testNothingIsQueuedOutsideARealCircle() {
        // Demo mode: `AppState` calls the same methods and nothing happens.
        let host = DrainHost(user: me, circle: nil, snapshot: CircleSnapshot.empty)
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday), photoFilename: "a.jpg")
        sync.postRetracted(log(.dhuhr, dayKey: monday))
        sync.excusedChanged(dayKey: monday, on: true)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 30)
        sync.challengeDeleted(id: "custom-1")

        XCTAssertTrue(sync.outbox.isEmpty)
        XCTAssertEqual(sync.status, .idle)
    }

    func testLeavingACircleReanchorsTheQueue() {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        XCTAssertEqual(sync.outbox.count, 1)

        // What `CircleService` does on leave / sign-out / adopting another
        // account: the identity generation moves and the queue on disk is
        // cleared. Writes owed to a circle you have left are meaningless.
        host.syncIdentityGeneration += 1
        sync.excusedChanged(dayKey: monday, on: true)
        XCTAssertEqual(sync.outbox.count, 1)
        XCTAssertEqual(sync.outbox.peek?.op.kind, .setExcused)
    }

    // MARK: - Shape of what goes out

    func testATravelPairMarksBothPrayers() {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        // `logCombined` logs the lead and its partner from one photo.
        sync.postLogged(log(.dhuhr, dayKey: monday, photo: "pair.jpg"),
                        photoFilename: "pair.jpg", travelCombined: true)
        sync.postLogged(log(.asr, dayKey: monday, photo: "pair.jpg"),
                        photoFilename: "pair.jpg", travelCombined: true)

        let posts: [RemotePost] = sync.outbox.items.compactMap { (item: OutboxItem) -> RemotePost? in
            if case .upsertPost(let post) = item.op { return post }
            return nil
        }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.travelCombined })
        XCTAssertEqual(Set(posts.map { $0.prayer }), Set([Prayer.dhuhr, Prayer.asr]))
    }

    func testThePhotoFollowsThePostAndLandsInTheOwnersFolder() {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        let entry: PrayerLog = log(.maghrib, dayKey: monday, photo: "m.jpg")
        sync.postLogged(entry, photoFilename: "m.jpg")

        XCTAssertEqual(sync.outbox.count, 2)
        XCTAssertEqual(sync.outbox.items[0].op.kind, .upsertPost)
        XCTAssertEqual(sync.outbox.items[1].op.kind, .uploadPhoto)

        // The row does NOT advertise the object until the bytes are up.
        if case .upsertPost(let post) = sync.outbox.items[0].op {
            XCTAssertNil(post.photoPath)
        } else {
            XCTFail("expected a post")
        }
        // Lowercased: the Storage policies compare the folders against
        // `current_circle_id()::text` and `auth.uid()::text`.
        let expected: String = PhotoSync.storagePath(circleID: circleID, userID: me,
                                                     objectID: entry.id)
        XCTAssertEqual(expected,
                       "\(circleID.uuidString.lowercased())/\(me.uuidString.lowercased())/"
                       + "\(entry.id.uuidString.lowercased()).jpg")
        if case .uploadPhoto(let postID, let dayKey, let prayer, let utcOffset,
                            let filename, let path) = sync.outbox.items[1].op {
            XCTAssertEqual(postID, entry.id)
            XCTAssertEqual(filename, "m.jpg")
            XCTAssertEqual(path, expected)
            // The SLOT rides along, because `photo_path` is patched by
            // (user, circle, day, prayer, utc_offset) and not by the row id —
            // see `CircleOp.uploadPhoto`.
            XCTAssertEqual(dayKey, monday)
            XCTAssertEqual(prayer, .maghrib)
            XCTAssertEqual(utcOffset, entry.utcOffset)
        } else {
            XCTFail("expected a photo upload")
        }
    }

    func testUndoQueuesTheRetraction() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        let entry: PrayerLog = log(.isha, dayKey: monday)
        sync.postLogged(entry)
        await sync.drain()
        sync.postRetracted(entry)
        await sync.drain()

        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual(transport.sent[1], .deletePost(postID: entry.id))
    }

    // MARK: - Period privacy is absolute (§3)

    /// The one test this whole file exists to make impossible to break: no path
    /// from `AppState` into the sync layer can carry a break REASON, and the
    /// excused row that does go out carries three columns and a flag.
    func testNoEnqueuePathCanCarryABreakReason() throws {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        // Every enqueue API, including the ones a break actually touches.
        sync.postLogged(log(.fajr, dayKey: monday, photo: "f.jpg",
                            placeTag: .home, placeName: "Home"),
                        photoFilename: "f.jpg", travelCombined: true)
        sync.postRetracted(log(.dhuhr, dayKey: monday))
        sync.excusedChanged(dayKey: monday, on: true)
        sync.excusedChanged(dayKey: tuesday, on: false)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 60)
        sync.challengeCreated(CustomChallenge(id: "custom-1", prayer: .fajr, days: 3,
                                              createdAt: stamp(0)))
        sync.challengeDeleted(id: "custom-2")

        let forbidden: [String] = ["reason", "period", "illness", "note", "breakReason"]
        for item in sync.outbox.items {
            // The queue file itself, and then the request body each op puts on
            // the wire.
            let queued: String = try text(encoding: item.op)
            for word in forbidden {
                XCTAssertFalse(queued.lowercased().contains(word),
                               "\(word) reached the queue: \(queued)")
            }
            guard let body: String = try wireBody(for: item.op) else { continue }
            for word in forbidden {
                XCTAssertFalse(body.lowercased().contains(word),
                               "\(word) reached the wire: \(body)")
            }
        }
    }

    func testTheExcusedRowIsThreeColumnsAndAFlag() throws {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.excusedChanged(dayKey: monday, on: true)
        guard case .setExcused(let dayKey, let excused)? = sync.outbox.peek?.op else {
            return XCTFail("expected an excused op")
        }
        XCTAssertEqual(dayKey, monday)
        XCTAssertTrue(excused)

        let row = RemoteExcusedDay(userID: me, circleID: circleID, dayKey: monday)
        let data: Data = try encoder().encode(row)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?.keys.sorted(), ["circle_id", "day_key", "user_id"])
    }

    func testUnRestingIsTheSameFlag() {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.excusedChanged(dayKey: monday, on: true)
        sync.excusedChanged(dayKey: monday, on: false)
        // One row, one op: the later answer replaces the earlier one.
        XCTAssertEqual(sync.outbox.count, 1)
        XCTAssertEqual(sync.outbox.peek?.op, .setExcused(dayKey: monday, excused: false))
    }

    // MARK: - v4 Phase C regressions

    /// Undo after a create that failed OFFLINE must still cancel the create.
    ///
    /// `checkout()` marks the head in flight, and collapsing deliberately never
    /// touches an in-flight item — but the offline branch of `recordFailure`
    /// returned before `outbox.recordFailure(id:)`, the only call that clears
    /// the marker. So the head stayed flagged from the first failed attempt
    /// until relaunch, and `enqueue`'s cancel skipped it: the queue became
    /// [create, delete] instead of empty, and on reconnect the circle was shown
    /// a prayer the user had already retracted (and it claimed the first-post
    /// push lease on the way through).
    func testUndoAfterAnOfflineFailureStillCancelsTheCreate() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.timedOut)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        let entry: PrayerLog = log(.maghrib, dayKey: monday)
        sync.postLogged(entry)
        await sync.drain()
        XCTAssertEqual(sync.outbox.count, 1, "nothing was accepted")
        XCTAssertNil(sync.outbox.inFlightID, "an offline failure releases the marker")

        sync.postRetracted(entry)
        XCTAssertTrue(sync.outbox.isEmpty,
                      "a create the server never took has nothing to delete")

        transport.failure = nil
        await sync.drain()
        XCTAssertTrue(transport.sent.isEmpty, "and nothing goes out at all")
    }

    /// The attempt counter is what must stay unspent — not the marker.
    func testReleasingTheMarkerDoesNotSpendAnAttempt() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.failure = URLError(.notConnectedToInternet)
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.postLogged(log(.fajr, dayKey: monday))
        for _ in 0..<(CircleOutbox.maxAttempts * 2) {
            await sync.retryNow()
        }
        XCTAssertEqual(sync.outbox.count, 1)
        XCTAssertEqual(sync.discardedCount, 0)
    }

    /// A delta page carries `excused_days`, `recovery_weeks` and
    /// `custom_challenges` as COMPLETE window lists (they have no usable
    /// `updated_at`, so the transport reads the whole window every pass). An
    /// add-only merge threw away exactly the removals it had been handed: a
    /// buddy tapping "Resume prayers" deletes their row, `excused_days` is
    /// deliberately not in the realtime publication so nothing forces a full
    /// read, and the mirror kept a rest day the buddy no longer has — which
    /// zeroes their perfect-day bonus on this device only.
    func testADeltaRemovesARestDayTheServerNoLongerHas() {
        let base: CircleSnapshot = snapshot(
            excused: [RemoteExcusedDay(userID: friend, circleID: circleID, dayKey: monday)],
            recovery: [RemoteRecoveryWeek(userID: friend, circleID: circleID,
                                          weekKey: "2026-W24", xp: 40)],
            challenges: [RemoteCustomChallenge(id: "custom-1", circleID: circleID,
                                               createdBy: friend, prayer: .fajr, days: 3)])
        // The authoritative window list, with all three gone.
        let page = CircleSyncPage(posts: nil, excusedDays: [], recoveryWeeks: [],
                                  challenges: [])
        let merged: CircleSnapshot = CircleSync.merged(base, delta: page)

        XCTAssertFalse(merged.isExcused(userID: friend, dayKey: monday))
        XCTAssertEqual(merged.recoveryXP(userID: friend, weekKeys: ["2026-W24"]), 0)
        XCTAssertTrue(merged.challenges.isEmpty)
    }

    /// …and `posts` stays additive, because a delta genuinely has no opinion
    /// about a post it did not mention.
    func testADeltaStillNeverRemovesAPost() {
        let kept: RemotePost = post(.fajr, dayKey: monday, user: friend)
        let base: CircleSnapshot = snapshot(posts: [kept])
        let merged: CircleSnapshot = CircleSync.merged(base, delta: CircleSyncPage(posts: []))
        XCTAssertEqual(merged.posts, [kept])
    }

    /// A drain that stops because it ran out of STEPS has to schedule its own
    /// continuation: backoff timers only exist for items that FAILED, and these
    /// did not. Reconnecting after a week away used to send the first
    /// `maxOpsPerDrain` writes and leave the rest sitting.
    func testADrainThatHitsTheCapKeepsGoing() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        // Distinct posts, so nothing collapses: a week offline really is
        // dozens of separate writes, which is what the old comment on
        // `maxOpsPerDrain` got wrong.
        let total: Int = CircleSyncTuning.maxOpsPerDrain + 12
        for _ in 0..<total {
            sync.postLogged(log(.fajr, dayKey: monday, id: UUID()))
        }
        XCTAssertGreaterThan(sync.outbox.count, CircleSyncTuning.maxOpsPerDrain,
                             "the fixture has to actually exceed the cap")

        await sync.drain()
        await settle()
        XCTAssertTrue(sync.outbox.isEmpty, "everything queued eventually goes out")
        XCTAssertEqual(transport.sent.count, total)
    }

    /// A realtime channel that fails to join must be retried, not silently
    /// abandoned. `subscribedCircleID` was claimed BEFORE the join and never
    /// released, so a join that lost the race with `AuthService.restore()` left
    /// realtime dead until the app was backgrounded and re-foregrounded.
    func testAFailedRealtimeJoinIsTriedAgainOnTheNextForeground() async {
        let host: DrainHost = liveHost()
        let transport = DrainTransport()
        transport.joinSucceeds = false
        let sync: CircleSync = makeSync(host: host, transport: transport)

        await sync.enteredForeground()
        XCTAssertNil(transport.subscribedTo, "the join failed")

        transport.joinSucceeds = true
        await sync.enteredForeground()
        XCTAssertEqual(transport.subscribedTo, circleID, "and the next one is tried")
    }

    /// A DELETE's "this needs a full read" bit must survive a pull that never
    /// ran. The flag was consumed before the pull, and `pull` bails outright
    /// when it is offline or already running — so the retraction stayed on
    /// screen until some later lifecycle full pull.
    func testTheFullReadBitSurvivesAPullThatNeverRan() async {
        let host: DrainHost = liveHost(snapshot(lastSyncedAt: stamp(0)))
        let transport = DrainTransport()
        let net = Reachability()
        net.setOnline(true)
        let sync: CircleSync = makeSync(host: host, transport: transport, reachability: net)
        // The launch's reconciling read FIRST, so the roster is fresh and the
        // only thing that can force a full read below is the bit the DELETE
        // set. Without it a never-reconciled mirror would ask for everything
        // anyway and this would pass while proving nothing.
        await sync.pull(since: nil)
        XCTAssertEqual(transport.fetches.count, 1)

        net.setOnline(false)
        sync.signalArrived(.deleted)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 1, "offline: nothing was asked")

        net.setOnline(true)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 2)
        XCTAssertNil(transport.fetches[1].since,
                     "the deletion still needs the reconciling read")
    }

    /// Acknowledging a challenge delete drops it from the MIRROR too, so the
    /// card cannot come back between the drain and the next pull.
    func testAnAcknowledgedChallengeDeleteLeavesTheMirror() async {
        let row = RemoteCustomChallenge(id: "custom-1", circleID: circleID,
                                        createdBy: me, prayer: .fajr, days: 3)
        let host: DrainHost = liveHost(snapshot(challenges: [row]))
        let transport = DrainTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport)

        sync.challengeDeleted(id: "custom-1")
        XCTAssertEqual(sync.pendingChallengeDeletions, Set(["custom-1"]),
                       "hidden while the delete is still owed")

        await sync.drain()
        await settle()
        XCTAssertTrue(sync.pendingChallengeDeletions.isEmpty)
        XCTAssertTrue(host.syncSnapshot.challenges.isEmpty,
                      "and gone from the mirror the moment the server took it")
    }

    /// The rest days a break created before the engine existed.
    func testUnmirroredRestDaysAreTheOnesTheCircleHasNotSeen() {
        let local: Set<String> = ["2026-06-08", "2026-06-09", "2026-06-10",
                                  "2026-04-01", "2026-06-30"]
        let mirrored: Set<String> = ["2026-06-08"]
        let owed: [String] = CircleSync.unmirroredExcusedDayKeys(
            local: local, mirrored: mirrored,
            startDayKey: "2026-06-01", todayKey: "2026-06-10")
        // 06-08 is already up there, 04-01 is outside the pull window, and
        // 06-30 has not happened yet.
        XCTAssertEqual(owed, ["2026-06-09", "2026-06-10"])
    }

    /// Let the main actor's queued tasks run.
    ///
    /// `drain()` schedules its own continuation as a fresh Task when it hits
    /// `maxOpsPerDrain` (and `enqueue` kicks one too), so a test that asserts
    /// the END state has to give those a turn. The transport is an array, so
    /// one resume runs a whole batch — this is generous, not tight.
    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    // MARK: - Encoding helpers

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func text(encoding op: CircleOp) throws -> String {
        let data: Data = try encoder().encode(op)
        return String(decoding: data, as: UTF8.self)
    }

    /// The JSON body the transport hands PostgREST for this op, or nil when the
    /// op has no body at all (the deletes, which travel entirely as filters).
    private func wireBody(for op: CircleOp) throws -> String? {
        switch op {
        case .upsertPost(let post):
            return String(decoding: try encoder().encode(post), as: UTF8.self)
        case .setExcused(let dayKey, let excused):
            guard excused else { return nil }
            let row = RemoteExcusedDay(userID: me, circleID: circleID, dayKey: dayKey)
            return String(decoding: try encoder().encode(row), as: UTF8.self)
        case .setRecoveryWeek(let weekKey, let xp):
            let row = RemoteRecoveryWeek(userID: me, circleID: circleID, weekKey: weekKey, xp: xp)
            return String(decoding: try encoder().encode(row), as: UTF8.self)
        case .upsertChallenge(let challenge):
            return String(decoding: try encoder().encode(challenge), as: UTF8.self)
        case .uploadPhoto(_, _, _, _, _, let path):
            return path
        case .deletePost, .deleteChallenge, .deletePhoto:
            return nil
        }
    }
}
