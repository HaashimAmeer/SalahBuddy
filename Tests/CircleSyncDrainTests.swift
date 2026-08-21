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
        return page
    }

    /// Reports whether the channel JOINED — false is how a dead channel gets
    /// retried instead of silently staying dead.
    var joinSucceeds: Bool = true

    func startRealtime(circleID: UUID,
                       onEvent: @escaping @Sendable @MainActor (CircleRealtimeEvent) -> Void) async -> Bool {
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
                          lastSyncedAt: Date? = nil) -> CircleSnapshot {
        CircleSnapshot(circle: circle(), me: me,
                       profiles: [], members: [RemoteMember(circleID: circleID, userID: me)],
                       posts: posts, excusedDays: excused, recoveryWeeks: recovery,
                       challenges: challenges, lastSyncedAt: lastSyncedAt)
    }

    private func log(_ prayer: Prayer, dayKey: String, id: UUID = UUID(),
                     tier: LogTier = .onTime, photo: String? = nil,
                     placeTag: PlaceTag? = nil, placeName: String? = nil) -> PrayerLog {
        PrayerLog(id: id, prayer: prayer, dayKey: dayKey, loggedAt: stamp(0), tier: tier,
                  xp: GameEngine.prayerXP(tier: tier, jamaat: false),
                  photoFilename: photo, jamaat: false,
                  placeTag: placeTag, placeName: placeName)
    }

    private func post(_ prayer: Prayer, dayKey: String, user: UUID,
                      id: UUID = UUID(), tier: LogTier = .onTime) -> RemotePost {
        RemotePost(id: id, userID: user, circleID: circleID, dayKey: dayKey,
                   prayer: prayer, tier: tier, loggedAt: stamp(0))
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
            if case .uploadPhoto(_, _, _, _, let path) = op { return path }
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
        XCTAssertEqual(merged.post(userID: me, dayKey: monday, prayer: .fajr)?.tier, .onTime)
        // The row nobody mentioned is exactly as it was.
        XCTAssertEqual(merged.post(userID: friend, dayKey: monday, prayer: .dhuhr), theirs)
        XCTAssertNotNil(merged.post(userID: friend, dayKey: monday, prayer: .asr))
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

        sync.realtimeEventArrived(.changed)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 1)
        // The delta is backdated by the overlap so a row written in the second
        // straddling the last sync is not lost forever.
        XCTAssertEqual(transport.fetches[0].since,
                       synced.addingTimeInterval(-CircleSyncTuning.deltaOverlap))

        sync.realtimeEventArrived(.deleted)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 2)
        // A deletion is invisible to `updated_at`, so only the reconciling read
        // can notice it.
        XCTAssertNil(transport.fetches[1].since)
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
        if case .uploadPhoto(let postID, let dayKey, let prayer,
                            let filename, let path) = sync.outbox.items[1].op {
            XCTAssertEqual(postID, entry.id)
            XCTAssertEqual(filename, "m.jpg")
            XCTAssertEqual(path, expected)
            // The SLOT rides along, because `photo_path` is patched by
            // (user, circle, day, prayer) and not by the row id — see
            // `CircleOp.uploadPhoto`.
            XCTAssertEqual(dayKey, monday)
            XCTAssertEqual(prayer, .maghrib)
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
        net.setOnline(false)
        let sync: CircleSync = makeSync(host: host, transport: transport, reachability: net)

        sync.realtimeEventArrived(.deleted)
        await sync.runDebouncedPull()
        XCTAssertTrue(transport.fetches.isEmpty, "offline: nothing was asked")

        net.setOnline(true)
        await sync.runDebouncedPull()
        XCTAssertEqual(transport.fetches.count, 1)
        XCTAssertNil(transport.fetches[0].since,
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
        case .uploadPhoto(_, _, _, _, let path):
            return path
        case .deletePost, .deleteChallenge, .deletePhoto:
            return nil
        }
    }
}
