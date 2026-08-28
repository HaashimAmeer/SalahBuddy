import Foundation
import XCTest
@testable import SalahBuddy

// MARK: - Doubles

/// Stands in for the live circle: who is signed in, which circle, and the
/// mirror. The same shape `CircleService` fills in the app.
@MainActor
private final class MirrorHost: CircleSyncHost {
    var syncUserID: UUID?
    var syncCircleID: UUID?
    var syncSnapshot: CircleSnapshot
    var syncIdentityGeneration: Int = 1

    init(user: UUID?, circle: UUID?, snapshot: CircleSnapshot) {
        syncUserID = user
        syncCircleID = circle
        syncSnapshot = snapshot
    }

    func applySyncedSnapshot(_ snapshot: CircleSnapshot) {
        syncSnapshot = snapshot
    }
}

/// The network as a list. Never fails; records what it was asked to send.
@MainActor
private final class MirrorTransport: CircleSyncTransport {
    var sent: [CircleOp] = []

    func perform(_ op: CircleOp, circleID: UUID, userID: UUID) async throws {
        sent.append(op)
    }

    func fetch(circleID: UUID, since: Date?, window: CircleSyncWindow) async throws -> CircleSyncPage {
        CircleSyncPage()
    }

    func startRealtime(circleID: UUID,
                       onEvent: @escaping @Sendable @MainActor (CircleSyncSignal) -> Void) async -> Bool {
        true
    }

    func stopRealtime() async {}
}

/// `AppState`'s side of `CircleServiceHost`, including the ONE opening §2 needs:
/// the week the join backfill uploads.
@MainActor
private final class BackfillHost: CircleServiceHost {
    var snapshots: [CircleSnapshot] = []
    var modes: [CircleMode] = []
    /// Local history, standing still — and reachable only through the one
    /// read below.
    var logs: [PrayerLog] = []
    var excusedDayKeys: Set<String> = []
    var backfillReads: Int = 0

    func applyCircleSnapshot(_ snapshot: CircleSnapshot) { snapshots.append(snapshot) }
    func setCircleMode(_ mode: CircleMode) { modes.append(mode) }

    func circleBackfillLogs(forWeekOf now: Date) -> [PrayerLog] {
        backfillReads += 1
        let keys: Set<String> = Set(BuddySimulator.weekDayKeys(for: now))
        return logs.filter { keys.contains($0.dayKey) }
    }

    func circleBackfillExcusedDayKeys(forWeekOf now: Date) -> [String] {
        let keys: Set<String> = Set(BuddySimulator.weekDayKeys(for: now))
        return excusedDayKeys.filter { keys.contains($0) }.sorted()
    }
}

// MARK: - Tests

/// v4 Phase C: what `AppState` mirrors to the circle, and what it must never.
///
/// These exercise the exact calls `AppState` makes — `postLogged` once per
/// prayer, twice with `travelCombined` for a jam' pair, `postRetracted` on
/// undo, `excusedChanged` for a rest day, `recoveryWeekChanged` for the week's
/// dhikr total — through the same `CircleSync` the app wires, with the network
/// replaced by an array. Nothing here touches Supabase, `Store` or the app's
/// Documents directory: every `CircleSync` is built with `persists: false`.
///
/// The last test is the one that matters most for §7's "leaderboard
/// agreement": a week of posts scores identically whether it arrives from the
/// simulator or from the wire, because both feed the same `GameEngine`.
@MainActor
final class CircleMirrorTests: XCTestCase {

    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let friend = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// 2026-06-08 is a Monday — the week every other suite uses.
    private let monday = "2026-06-08"
    private let sunday = "2026-06-07"

    private let cal = Calendar.current

    // MARK: - Fixtures

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    private func circle() -> RemoteCircle {
        RemoteCircle(id: circleID, code: "ABC234", name: "Test", emoji: "🤝")
    }

    private func snapshot(posts: [RemotePost] = [],
                          profiles: [RemoteProfile] = [],
                          members: [RemoteMember]? = nil) -> CircleSnapshot {
        let roster: [RemoteMember] = members ?? [RemoteMember(circleID: circleID, userID: me)]
        return CircleSnapshot(circle: circle(), me: me, profiles: profiles,
                              members: roster, posts: posts)
    }

    /// A log shaped exactly as `AppState.buildLog` shapes one.
    private func log(_ prayer: Prayer, dayKey: String, id: UUID = UUID(),
                     tier: LogTier = .onTime, at: TimeInterval = 0,
                     photo: String? = nil, jamaat: Bool = false,
                     placeTag: PlaceTag? = nil, placeName: String? = nil,
                     utcOffset: Int? = -7 * 3600) -> PrayerLog {
        // utcOffset defaults to a REAL zone, not nil. A nil default made the
        // "the zone rides along" assertions below compare nil to nil, so they
        // passed while proving nothing: hard-coding `utcOffset: nil` in
        // CircleSync.postLogged left the whole suite green and reintroduced the
        // bug scopedToSlot exists to prevent.
        PrayerLog(id: id, prayer: prayer, dayKey: dayKey, loggedAt: stamp(at), tier: tier,
                  xp: GameEngine.prayerXP(tier: tier, jamaat: jamaat),
                  photoFilename: photo, jamaat: jamaat,
                  placeTag: placeTag, placeName: placeName, utcOffset: utcOffset)
    }

    /// A sync wired to a live circle with the network stubbed and the monitor
    /// reporting OFFLINE, so nothing drains behind the assertions' back — the
    /// outbox is inspected exactly as the enqueues left it.
    private func makeSync(host: MirrorHost, transport: MirrorTransport,
                          online: Bool = false) -> CircleSync {
        let net = Reachability()
        net.setOnline(online)
        return CircleSync(host: host, transport: transport, reachability: net,
                          outbox: CircleOutbox.empty, persists: false)
    }

    private func liveHost(_ snap: CircleSnapshot? = nil) -> MirrorHost {
        MirrorHost(user: me, circle: circleID, snapshot: snap ?? snapshot())
    }

    private func ops(_ sync: CircleSync) -> [CircleOp] {
        sync.outbox.items.map { $0.op }
    }

    private func posts(_ sync: CircleSync) -> [RemotePost] {
        var result: [RemotePost] = []
        for item in sync.outbox.items {
            if case .upsertPost(let post) = item.op { result.append(post) }
        }
        return result
    }

    // MARK: - Logging

    /// `AppState.log` → one post, and nothing else. A photo adds the upload
    /// and still only ONE row.
    func testLoggingEnqueuesExactlyOnePost() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let entry: PrayerLog = log(.fajr, dayKey: monday, tier: .onTime)

        sync.postLogged(entry, photoFilename: nil, travelCombined: false)

        XCTAssertEqual(ops(sync).count, 1, "one log, one write")
        XCTAssertEqual(ops(sync).first?.kind, .upsertPost)

        let mirrored: [RemotePost] = posts(sync)
        XCTAssertEqual(mirrored.count, 1)
        XCTAssertEqual(mirrored.first?.id, entry.id,
                       "the post carries the LOG's uuid — that is what makes a replay idempotent")
        XCTAssertEqual(mirrored.first?.userID, me)
        XCTAssertEqual(mirrored.first?.circleID, circleID)
        XCTAssertEqual(mirrored.first?.prayer, .fajr)
        XCTAssertEqual(mirrored.first?.tier, .onTime)
        XCTAssertEqual(mirrored.first?.loggedAt, entry.loggedAt)
        XCTAssertEqual(mirrored.first?.travelCombined, false)
        XCTAssertNil(mirrored.first?.photoPath,
                     "photo_path is patched only once the bytes are really in Storage")
    }

    /// The picture is a SECOND op, deliberately: the row must exist (and be
    /// drawable) whether or not the JPEG ever lands.
    func testAPhotoAddsAnUploadBehindThePost() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let entry: PrayerLog = log(.dhuhr, dayKey: monday, photo: "2026-06-08_dhuhr_ab12.jpg")

        sync.postLogged(entry, photoFilename: entry.photoFilename, travelCombined: false)

        XCTAssertEqual(ops(sync).map { $0.kind }, [.upsertPost, .uploadPhoto],
                       "row first, bytes second — order is the whole point")
        guard case .uploadPhoto(let postID, let dayKey, let prayer, let utcOffset,
                               let filename, let path) = ops(sync)[1] else {
            return XCTFail("expected an upload")
        }
        XCTAssertEqual(postID, entry.id)
        XCTAssertEqual(filename, entry.photoFilename)
        XCTAssertEqual(dayKey, entry.dayKey)
        XCTAssertEqual(prayer, entry.prayer)
        XCTAssertEqual(utcOffset, entry.utcOffset,
                       "the zone rides along: `photo_path` is patched by the SLOT, and v4 put "
                       + "utc_offset in it, so a traveller's two same-day fajrs stay two rows")
        XCTAssertTrue(path.hasPrefix("\(circleID.uuidString.lowercased())/"),
                      "RLS reads folder 1 as the circle id, and Postgres renders uuids lowercase")
        XCTAssertFalse(path.contains("dhuhr"),
                       "a Storage key is readable by the circle; it must not spell out the prayer")
    }

    /// §3: a travel pair posts BOTH prayers, both flagged, both against the
    /// combined window's tier — the shape `AppState.logCombined` produces.
    func testTravelCombinedMirrorsBothPrayersWithTheFlag() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let lead: PrayerLog = log(.dhuhr, dayKey: monday, tier: .prayed, at: 100)
        let follow: PrayerLog = log(.asr, dayKey: monday, tier: .prayed, at: 100)

        sync.postLogged(lead, photoFilename: nil, travelCombined: true)
        sync.postLogged(follow, photoFilename: nil, travelCombined: true)

        let mirrored: [RemotePost] = posts(sync)
        XCTAssertEqual(mirrored.count, 2)
        XCTAssertEqual(mirrored.map { $0.prayer }, [.dhuhr, .asr])
        XCTAssertTrue(mirrored.allSatisfy { $0.travelCombined },
                      "both halves of a jam' say so, or the circle reads it as two separate posts")
        XCTAssertTrue(mirrored.allSatisfy { $0.tier == .prayed },
                      "both earn the tier of the COMBINED window")
        XCTAssertEqual(Set(mirrored.map { $0.id }).count, 2,
                       "two rows, two ids — the unique key is (user, day, prayer)")
    }

    /// The Isha-after-midnight rule travels WITH the post; the server never
    /// re-derives a day from `logged_at` (§3).
    func testTheClientsDayKeyTravelsUnchanged() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        // Logged at 1 AM on Monday, but it belongs to SUNDAY's schedule day.
        let entry: PrayerLog = log(.isha, dayKey: sunday, tier: .lastCall, at: 3_600)

        sync.postLogged(entry, photoFilename: nil, travelCombined: false)

        XCTAssertEqual(posts(sync).first?.dayKey, sunday)
        XCTAssertEqual(posts(sync).first?.loggedAt, entry.loggedAt,
                       "the timestamp is the real instant; the day key is the schedule day")
    }

    /// A make-up carries the past day it belongs to, and the qada tier.
    func testARetroactiveMakeUpMirrorsAsAQadaPostOnItsOwnDay() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let entry: PrayerLog = log(.asr, dayKey: sunday, tier: .qada, at: 90_000)

        sync.postLogged(entry, photoFilename: nil, travelCombined: false)

        XCTAssertEqual(posts(sync).first?.tier, .qada)
        XCTAssertEqual(posts(sync).first?.dayKey, sunday)
    }

    // MARK: - Undo

    /// §3: undo retracts the post. A create that never left the device has
    /// nothing to retract, so the pair collapses to nothing at all — which is
    /// the common case, because undo usually follows logging by seconds.
    func testUndoCollapsesACreateThatNeverLeft() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let entry: PrayerLog = log(.maghrib, dayKey: monday)

        sync.postLogged(entry, photoFilename: nil, travelCombined: false)
        XCTAssertEqual(ops(sync).count, 1)

        sync.postRetracted(entry)
        XCTAssertTrue(sync.outbox.isEmpty,
                      "create + delete of a row the server never saw is pure waste")
    }

    /// The photo goes with it: an upload for a post that is going away has
    /// nothing left to be the picture of.
    func testUndoAlsoCancelsAQueuedPhotoUpload() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())
        let entry: PrayerLog = log(.isha, dayKey: monday, photo: "2026-06-08_isha_cd34.jpg")

        sync.postLogged(entry, photoFilename: entry.photoFilename, travelCombined: false)
        XCTAssertEqual(ops(sync).count, 2)

        sync.postRetracted(entry)
        XCTAssertTrue(sync.outbox.isEmpty)
    }

    /// Once the create HAS landed, undo is a real delete.
    func testUndoAfterTheCreateLandedQueuesTheDelete() async {
        let host: MirrorHost = liveHost()
        let transport = MirrorTransport()
        let sync: CircleSync = makeSync(host: host, transport: transport, online: true)
        let entry: PrayerLog = log(.fajr, dayKey: monday)

        sync.postLogged(entry, photoFilename: nil, travelCombined: false)
        await sync.drain()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(sync.outbox.isEmpty)

        sync.postRetracted(entry)
        XCTAssertEqual(ops(sync).count, 1)
        XCTAssertEqual(ops(sync).first, .deletePost(postID: entry.id))
    }

    // MARK: - Excused days

    /// §3: the circle sees "resting". It never sees why — and the reason has
    /// nowhere to travel, which is the enforcement.
    func testExcusedMirrorsTheBareFlag() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        sync.excusedChanged(dayKey: monday, on: true)

        XCTAssertEqual(ops(sync), [.setExcused(dayKey: monday, excused: true)])
    }

    func testUnexcusingMirrorsTheSameFlagTurnedOff() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        sync.excusedChanged(dayKey: monday, on: true)
        sync.excusedChanged(dayKey: monday, on: false)

        XCTAssertEqual(ops(sync), [.setExcused(dayKey: monday, excused: false)],
                       "same day, same signature — the later answer replaces the earlier one")
    }

    /// A break that spans days marks each of them: one row per day, in order.
    func testAMultiDayBreakMirrorsEveryDayItCovers() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        for key in ["2026-06-08", "2026-06-09", "2026-06-10"] {
            sync.excusedChanged(dayKey: key, on: true)
        }

        XCTAssertEqual(ops(sync).count, 3)
        XCTAssertEqual(ops(sync), [.setExcused(dayKey: "2026-06-08", excused: true),
                                   .setExcused(dayKey: "2026-06-09", excused: true),
                                   .setExcused(dayKey: "2026-06-10", excused: true)])
    }

    /// The promise, asserted against the bytes: encode everything the mirror
    /// can queue and go looking for a reason. There is no field for one, so
    /// there is nothing to find — this fails the day somebody adds one.
    func testNoQueuedWriteCanCarryABreakReason() throws {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        sync.excusedChanged(dayKey: monday, on: true)
        sync.postLogged(log(.fajr, dayKey: monday), photoFilename: nil, travelCombined: false)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 120)

        let encoder = JSONEncoder()
        let data: Data = try encoder.encode(sync.outbox)
        let text: String = String(decoding: data, as: UTF8.self)
        for reason in ["period", "illness", "breakReason", "break_reason", "reason"] {
            XCTAssertFalse(text.contains(reason),
                           "\(reason) must never appear in anything this device sends")
        }
    }

    /// The excused op's whole shape, spelled out: three keys, and none of them
    /// could hold a reason even by accident.
    func testTheExcusedOpHasExactlyThreeFields() throws {
        let op: CircleOp = .setExcused(dayKey: monday, excused: true)
        let data: Data = try JSONEncoder().encode(op)
        let object: [String: Any] = (try JSONSerialization.jsonObject(with: data)
                                     as? [String: Any]) ?? [:]
        let keys: Set<String> = Set(object.keys)
        XCTAssertEqual(keys, ["kind", "dayKey", "excused"])
    }

    // MARK: - Recovery XP

    /// §3: one opaque weekly integer. Not the tap count, not which deed.
    func testRecoveryMirrorsOneOpaqueWeeklyTotal() {
        let host: MirrorHost = liveHost()
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 15)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 16)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 17)

        XCTAssertEqual(ops(sync), [.setRecoveryWeek(weekKey: "2026-W24", xp: 17)],
                       "a hundred tasbih taps collapse to one pending write with the latest total")
    }

    // MARK: - Demo mode and solo

    /// Demo mode and a solo account never form a wire type at all: with no
    /// circle, every door is shut.
    func testWithNoCircleNothingIsEverQueued() {
        let host = MirrorHost(user: me, circle: nil, snapshot: .empty)
        let sync: CircleSync = makeSync(host: host, transport: MirrorTransport())

        sync.postLogged(log(.fajr, dayKey: monday), photoFilename: "x.jpg", travelCombined: false)
        sync.postRetracted(log(.dhuhr, dayKey: monday))
        sync.excusedChanged(dayKey: monday, on: true)
        sync.recoveryWeekChanged(weekKey: "2026-W24", xp: 40)

        XCTAssertTrue(sync.outbox.isEmpty)
        XCTAssertEqual(sync.pendingCount, 0)
    }

    // MARK: - Join-week backfill (§2)

    /// The seam `CircleService.joinWeekBackfill` documented, now filled: the
    /// current Mon-start week's own logs go up so the circle sees your week so
    /// far — and nothing older does.
    func testJoiningBackfillsThisWeekAndOnlyThisWeek() async {
        let now: Date = AppClock.now
        let thisWeek: [String] = BuddySimulator.weekDayKeys(for: now)
        let stale: String = AppClock.dayKey(for: now.addingTimeInterval(-40 * 86_400))

        let appHost = BackfillHost()
        appHost.logs = [log(.fajr, dayKey: thisWeek[0]),
                        log(.dhuhr, dayKey: thisWeek[0]),
                        log(.fajr, dayKey: stale)]

        let userID: UUID = me
        let service = CircleService(snapshot: CircleSnapshot.empty, outbox: CircleOutbox.empty,
                                    persists: false,
                                    currentUserID: { userID })
        service.host = appHost
        let transport = MirrorTransport()
        let net = Reachability()
        net.setOnline(false)
        let engine = CircleSync(host: nil, transport: transport, reachability: net,
                                outbox: CircleOutbox.empty, persists: false)
        service.attachSync(engine)
        XCTAssertNotNil(service.sync, "attachSync adopts the engine")

        service.applyEnteredCircle(circle(), me: me)
        guard let backfill = service.joinWeekBackfill else {
            return XCTFail("attachSync wires the join-week backfill")
        }
        await backfill(circle(), .joined)

        XCTAssertEqual(appHost.backfillReads, 1, "the week is read once, through the one opening")
        let mirrored: [RemotePost] = posts(engine)
        XCTAssertEqual(mirrored.count, 2, "this week's two logs, and not the 40-day-old one")
        XCTAssertEqual(Set(mirrored.map { $0.dayKey }), [thisWeek[0]])
        XCTAssertTrue(mirrored.allSatisfy { $0.circleID == self.circleID })
        XCTAssertTrue(mirrored.allSatisfy { $0.userID == self.me })
        XCTAssertFalse(ops(engine).contains { $0.kind == .uploadPhoto },
                       "the backfill shares the FACT of a prayer, not a week of JPEGs on cellular")
    }

    /// v4 Phase C REGRESSION: the backfill hands over the week's REST DAYS too.
    ///
    /// Someone who joins mid-period used to have that week's `excusedDayKeys`
    /// stay on their own device, so every empty cell rendered to their brand
    /// new circle as a plain `.missed` — the shaming outcome §3's gentle
    /// "resting" state exists to avoid. A bare flag per day, and still no
    /// field a reason could travel in.
    func testJoiningBackfillsThisWeeksRestDays() async {
        let now: Date = AppClock.now
        let thisWeek: [String] = BuddySimulator.weekDayKeys(for: now)
        let todayKey: String = AppClock.dayKey(for: now)
        let resting: [String] = thisWeek.filter { $0 <= todayKey }
        XCTAssertFalse(resting.isEmpty)

        let appHost = BackfillHost()
        appHost.excusedDayKeys = Set(resting)
        // Plus one from a fortnight ago, which is not this week's business.
        appHost.excusedDayKeys.insert(AppClock.dayKey(for: now.addingTimeInterval(-14 * 86_400)))

        let engine: CircleSync = await backfilledEngine(host: appHost)

        let flagged: [String] = ops(engine).compactMap { (op: CircleOp) -> String? in
            guard case .setExcused(let dayKey, let on) = op, on else { return nil }
            return dayKey
        }
        XCTAssertEqual(Set(flagged), Set(resting))
    }

    /// §3's time-travel guard, pointed at the one path that could smuggle
    /// through it. The guard pins `AppClock.offset` to zero the moment a real
    /// circle is active — but the backfill re-posts logs written BEHIND it, and
    /// `BuildEnv.showsDeveloperTools` is true in TestFlight. A tester who time
    /// travelled forward in demo mode and then joined a real circle would post
    /// fictional `logged_at` rows to real friends.
    func testTheBackfillRefusesLogsStampedInTheFuture() async {
        let now: Date = AppClock.now
        let thisWeek: [String] = BuddySimulator.weekDayKeys(for: now)
        let todayKey: String = AppClock.dayKey(for: now)
        let past: String = thisWeek.first(where: { $0 <= todayKey }) ?? todayKey

        let appHost = BackfillHost()
        appHost.logs = [
            log(.fajr, dayKey: past),
            // Same week, but stamped hours from now — only a clock offset
            // could have produced it.
            PrayerLog(id: UUID(), prayer: .dhuhr, dayKey: past,
                      loggedAt: now.addingTimeInterval(6 * 3600), tier: .onTime,
                      xp: 30, photoFilename: nil, jamaat: false,
                      placeTag: nil, placeName: nil),
        ]

        let engine: CircleSync = await backfilledEngine(host: appHost)
        let mirrored: [RemotePost] = posts(engine)
        XCTAssertEqual(mirrored.count, 1, "the future-stamped log is not shared")
        XCTAssertEqual(mirrored.first?.prayer, .fajr)
    }

    /// The `attachSync` → `applyEnteredCircle` → `joinWeekBackfill` sequence
    /// the two tests above both need.
    private func backfilledEngine(host appHost: BackfillHost) async -> CircleSync {
        let userID: UUID = me
        let service = CircleService(snapshot: CircleSnapshot.empty, outbox: CircleOutbox.empty,
                                    persists: false,
                                    currentUserID: { userID })
        service.host = appHost
        let net = Reachability()
        net.setOnline(false)
        let engine = CircleSync(host: nil, transport: MirrorTransport(), reachability: net,
                                outbox: CircleOutbox.empty, persists: false)
        service.attachSync(engine)
        service.applyEnteredCircle(circle(), me: me)
        await service.joinWeekBackfill?(circle(), .joined)
        return engine
    }

    /// The engine reads the mirror it is hosted on, so `CircleService` is what
    /// answers "who" and "which circle" — the wiring the app depends on.
    func testTheServiceIsTheSyncHost() {
        let userID: UUID = me
        let service = CircleService(snapshot: CircleSnapshot.empty, outbox: CircleOutbox.empty,
                                    persists: false,
                                    currentUserID: { userID })
        service.applyEnteredCircle(circle(), me: me)

        XCTAssertEqual(service.syncCircleID, circleID)
        XCTAssertEqual(service.syncUserID, me)
        XCTAssertEqual(service.syncSnapshot.circle?.id, circleID)
        XCTAssertEqual(service.syncIdentityGeneration, service.identityGeneration)
    }

    /// A merged mirror routed back through the service is the one the views
    /// get — the reason the engine is hosted here and not on `AppState`, whose
    /// copy the next `pull()` would overwrite.
    func testAdoptingASyncedSnapshotReachesTheHost() {
        let appHost = BackfillHost()
        let userID: UUID = me
        let service = CircleService(snapshot: CircleSnapshot.empty, outbox: CircleOutbox.empty,
                                    persists: false,
                                    currentUserID: { userID })
        service.host = appHost
        service.applyEnteredCircle(circle(), me: me)

        var merged: CircleSnapshot = service.snapshot
        merged.posts = [RemotePost(id: UUID(), userID: friend, circleID: circleID,
                                   dayKey: monday, prayer: .fajr, tier: .onTime,
                                   loggedAt: stamp(0))]
        service.applySyncedSnapshot(merged)

        XCTAssertEqual(service.snapshot.posts.count, 1)
        XCTAssertEqual(appHost.snapshots.last?.posts.count, 1)
    }

    /// And a mirror describing a circle this device has left is refused, so a
    /// pull in flight across a `leave` cannot put it back.
    func testASnapshotForAnotherCircleIsRefused() {
        let userID: UUID = me
        let service = CircleService(snapshot: CircleSnapshot.empty, outbox: CircleOutbox.empty,
                                    persists: false,
                                    currentUserID: { userID })
        service.applyEnteredCircle(circle(), me: me)

        let other = RemoteCircle(id: UUID(), code: "ZZZ999", name: "Elsewhere", emoji: "🚪")
        var foreign: CircleSnapshot = CircleSnapshot(circle: other, me: me)
        foreign.posts = [RemotePost(id: UUID(), userID: friend, circleID: other.id,
                                    dayKey: monday, prayer: .fajr, tier: .onTime,
                                    loggedAt: stamp(0))]
        service.applySyncedSnapshot(foreign)

        XCTAssertEqual(service.snapshot.circle?.id, circleID)
        XCTAssertTrue(service.snapshot.posts.isEmpty)
    }

    // MARK: - Grid entry ids (what a tile resolves a buddy photo from)

    func testGridEntryIDsRoundTrip() {
        let id: String = AppState.gridEntryID(memberID: friend.uuidString,
                                              dayKey: monday, prayer: .maghrib)
        let coords = AppState.gridEntryCoordinates(id)
        XCTAssertEqual(coords?.memberID, friend.uuidString)
        XCTAssertEqual(coords?.dayKey, monday)
        XCTAssertEqual(coords?.prayer, .maghrib)
        // A demo member id survives the trip too.
        let demo: String = AppState.gridEntryID(memberID: "buddy.Mina",
                                                dayKey: monday, prayer: .fajr)
        XCTAssertEqual(AppState.gridEntryCoordinates(demo)?.memberID, "buddy.Mina")
    }

    func testGridEntryCoordinatesRefuseAnythingElse() {
        XCTAssertNil(AppState.gridEntryCoordinates("1"), "a SwiftUI preview's id")
        XCTAssertNil(AppState.gridEntryCoordinates("buddy.Mina|2026-06-08"))
        XCTAssertNil(AppState.gridEntryCoordinates("buddy.Mina|2026-06-08|brunch"))
    }

    /// The lookup a tile makes: a buddy's post resolves to its Storage path,
    /// and YOUR row never does — your photos stay `PhotoStore`'s (§4).
    func testOnlyABuddysSquareResolvesToAStoragePath() {
        let path = "\(circleID.uuidString.lowercased())/\(friend.uuidString.lowercased())/a.jpg"
        let theirs = RemotePost(id: UUID(), userID: friend, circleID: circleID,
                                dayKey: monday, prayer: .fajr, tier: .onTime,
                                loggedAt: stamp(0), photoPath: path)
        let mine = RemotePost(id: UUID(), userID: me, circleID: circleID,
                              dayKey: monday, prayer: .fajr, tier: .onTime,
                              loggedAt: stamp(0), photoPath: "mine.jpg")
        let mirror: CircleSnapshot = snapshot(posts: [theirs, mine],
                                              members: [RemoteMember(circleID: circleID, userID: me),
                                                        RemoteMember(circleID: circleID, userID: friend)])
        let source = RemoteCircleDataSource(snapshot: mirror)

        XCTAssertEqual(source.photoPath(forMember: friend.uuidString, prayer: .fajr,
                                        dayKey: monday, asOf: .distantFuture),
                       path)
        XCTAssertNil(source.photoPath(forMember: me.uuidString, prayer: .fajr, dayKey: monday,
                                      asOf: .distantFuture),
                     "the source speaks for BUDDIES; your own tile draws from PhotoStore")
    }

    // MARK: - Leaderboard agreement (§7)

    /// Synthetic schedule: 5 90-minute windows through the day — the same
    /// shape `CircleSeamTests` and `V2CoreTests` use.
    private func schedule(dayKey: String, dayStart: Date) -> DaySchedule {
        let hours: [Double] = [5.5, 13.0, 16.5, 19.5, 21.0]
        let length: TimeInterval = 90 * 60
        var windows: [PrayerWindow] = []
        for (prayer, hour) in zip(Prayer.allCases, hours) {
            let start: Date = dayStart.addingTimeInterval(hour * 3600)
            windows.append(PrayerWindow(prayer: prayer, start: start,
                                        end: start.addingTimeInterval(length)))
        }
        return DaySchedule(dayKey: dayKey, dayStart: dayStart, windows: windows)
    }

    private func weekDays() -> [(dayKey: String, schedule: DaySchedule)] {
        let mondayStart = cal.startOfDay(for: date(2026, 6, 8))
        var days: [(dayKey: String, schedule: DaySchedule)] = []
        for offset in 0..<7 {
            let dayStart = cal.date(byAdding: .day, value: offset, to: mondayStart)!
            let key = AppClock.dayKey(for: dayStart)
            days.append((key, schedule(dayKey: key, dayStart: dayStart)))
        }
        return days
    }

    /// §7: "both clients must compute the same numbers".
    ///
    /// Take a simulated buddy's week, put those exact facts on the wire, and
    /// score them through the remote source. The two must agree to the point —
    /// they had better, because neither of them scores anything: both hand the
    /// same `PrayerLog`s to the same `GameEngine`.
    func testWeeklyXPAgreesBetweenTheSimulatedAndTheSyncedSource() {
        let days = weekDays()
        let asOf = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: date(2026, 6, 8)))!
        let simulated = SimulatedCircleDataSource(buddies: BuddySimulator.buddies)

        var compared: Int = 0
        for buddy in BuddySimulator.buddies {
            let memberID: String = BuddySimulator.member(for: buddy).id
            let theirLogs: [PrayerLog] = simulated.weekLogs(forMember: memberID, days: days,
                                                            asOf: asOf)
            let expected: Int = simulated.weeklyXP(forMember: memberID, days: days, asOf: asOf)

            // The same facts, as they would arrive from the server.
            var wire: [RemotePost] = []
            for entry in theirLogs {
                wire.append(RemotePost.from(log: entry, userID: friend, circleID: circleID))
            }
            let mirror = CircleSnapshot(circle: circle(), me: me, profiles: [],
                                        members: [RemoteMember(circleID: circleID, userID: me),
                                                  RemoteMember(circleID: circleID, userID: friend)],
                                        posts: wire)
            let remote = RemoteCircleDataSource(snapshot: mirror)
            let actual: Int = remote.weeklyXP(forMember: friend.uuidString, days: days, asOf: asOf)

            XCTAssertEqual(actual, expected,
                           "\(buddy.name)'s week scores the same from the wire as from the sim")
            compared += 1
        }
        XCTAssertEqual(compared, BuddySimulator.buddies.count)
        XCTAssertGreaterThan(compared, 0)
    }

    /// The same agreement one level down: the logs themselves round-trip, so
    /// the grid and the scoreboard are looking at identical facts.
    func testASyncedPostRoundTripsToTheSamePrayerLog() {
        let entry: PrayerLog = log(.asr, dayKey: monday, tier: .lastCall, jamaat: true)
        let post: RemotePost = RemotePost.from(log: entry, userID: friend, circleID: circleID)
        let back: PrayerLog = post.asPrayerLog()

        XCTAssertEqual(back.id, entry.id)
        XCTAssertEqual(back.prayer, entry.prayer)
        XCTAssertEqual(back.dayKey, entry.dayKey)
        XCTAssertEqual(back.tier, entry.tier)
        XCTAssertEqual(back.loggedAt, entry.loggedAt)
        XCTAssertEqual(back.jamaat, entry.jamaat)
        XCTAssertEqual(back.xp, entry.xp, "the jamaat FLOOR survives, because both sides run GameEngine")
        XCTAssertNil(back.photoFilename,
                     "a buddy's photo is a cache entry, never a PhotoStore file (§4)")
    }
}
