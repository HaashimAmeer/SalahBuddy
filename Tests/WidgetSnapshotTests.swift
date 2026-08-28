import Foundation
import XCTest
@testable import SalahBuddy

/// v5 §3 (P2) — the widget file.
///
/// The widget itself is a renderer with no logic to test; ALL of the thinking
/// happens on this side of the container, in `WidgetSnapshotBuilder`, and this
/// is where it is pinned: the exact shape §3 specifies, the cap and the
/// ordering, which circle members count as prayed and which are nudge targets,
/// and — §7 — the two invariants that must survive contact with a home screen.
/// A reported photo must not come back, and `breakReason` must have nowhere to
/// travel.
///
/// The mirror-driven cases go through `RemoteCircleDataSource` and the demo ones
/// through `SimulatedCircleDataSource`, deliberately: §9-03 says the widget
/// renders the simulated circle too, and the way that promise is kept is by
/// both circles arriving at the builder as the same `[GridEntry]`.
@MainActor
final class WidgetSnapshotTests: XCTestCase {

    private let cal = Calendar.current
    private let circleID = UUID()

    // MARK: - Fixtures

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    /// Five 90-minute windows through the day — the same synthetic shape
    /// `CircleSeamTests` and `V2CoreTests` use, so every file agrees on what a
    /// day looks like.
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

    private func fixedDay() -> (dayKey: String, schedule: DaySchedule) {
        let dayStart = cal.startOfDay(for: date(2026, 6, 10))
        let key = AppClock.dayKey(for: dayStart)
        return (key, schedule(dayKey: key, dayStart: dayStart))
    }

    private func you(name: String = "Haashim") -> CircleMember {
        CircleMember(id: "you", name: name, emoji: "😄", isYou: true)
    }

    /// `AppState.gridEntries`, reproduced: buddies through the seam, you last.
    /// The builder is fed exactly what the Today grid is fed.
    private func entries(source: any CircleDataSource,
                         you: CircleMember, yourState: GridEntryState,
                         prayer: Prayer, dayKey: String,
                         window: PrayerWindow?, now: Date) -> [GridEntry] {
        var out: [GridEntry] = []
        for member in source.members {
            let result = source.entry(forMember: member.id, prayer: prayer,
                                      dayKey: dayKey, window: window, now: now)
            out.append(GridEntry(id: AppState.gridEntryID(memberID: member.id, dayKey: dayKey,
                                                          prayer: prayer),
                                 member: member, state: result.state,
                                 placeLabel: result.placeLabel))
        }
        out.append(GridEntry(id: AppState.gridEntryID(memberID: "you", dayKey: dayKey,
                                                      prayer: prayer),
                             member: you, state: yourState))
        return out
    }

    private func photoPaths(source: any CircleDataSource, prayer: Prayer,
                            dayKey: String, now: Date) -> [String: String] {
        var paths: [String: String] = [:]
        for member in source.members {
            if let path = source.photoPath(forMember: member.id, prayer: prayer,
                                           dayKey: dayKey, asOf: now) {
                paths[member.id] = path
            }
        }
        return paths
    }

    private func profile(_ id: UUID, _ name: String, _ emoji: String) -> RemoteProfile {
        RemoteProfile(id: id, name: name, avatarEmoji: emoji)
    }

    private func post(_ userID: UUID, _ prayer: Prayer, _ dayKey: String,
                      tier: LogTier, at: Date, photoPath: String? = nil) -> RemotePost {
        RemotePost(id: UUID(), userID: userID, circleID: circleID, dayKey: dayKey,
                   prayer: prayer, tier: tier, loggedAt: at, photoPath: photoPath)
    }

    private func mirror(me: UUID, friends: [UUID],
                        profiles: [RemoteProfile], posts: [RemotePost],
                        excused: [RemoteExcusedDay] = []) -> CircleSnapshot {
        let circle = RemoteCircle(id: circleID, code: "ABC234", name: "Test", emoji: "🤝")
        var members: [RemoteMember] = [RemoteMember(circleID: circleID, userID: me,
                                                    joinedAt: date(2026, 1, 1))]
        for (offset, friend) in friends.enumerated() {
            members.append(RemoteMember(circleID: circleID, userID: friend,
                                        joinedAt: date(2026, 1, 2, offset)))
        }
        return CircleSnapshot(circle: circle, me: me, profiles: profiles,
                              members: members, posts: posts, excusedDays: excused)
    }

    /// Every key in an encoded snapshot, flattened, so a field added later
    /// cannot slip in unnoticed.
    private func keys(in object: Any) -> Set<String> {
        var found: Set<String> = []
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                found.insert(key)
                found.formUnion(keys(in: value))
            }
        } else if let array = object as? [Any] {
            for value in array { found.formUnion(keys(in: value)) }
        }
        return found
    }

    private func json(_ snapshot: WidgetSnapshot) throws -> [String: Any] {
        let data: Data = try XCTUnwrap(WidgetFile.encode(snapshot))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleSnapshot(thumb: String? = "abc.jpg") -> WidgetSnapshot {
        let now = date(2026, 6, 10, 17, 0)
        return WidgetSnapshot(
            writtenAt: now,
            mode: .real,
            window: WidgetSnapshot.Window(prayer: .asr, dayKey: "2026-06-10",
                                          opensAt: now.addingTimeInterval(-3600),
                                          endsAt: now.addingTimeInterval(3600)),
            you: WidgetSnapshot.You(logged: true, streak: 41),
            circle: WidgetSnapshot.Circle(
                prayedCount: 2, memberCount: 3,
                posts: [WidgetSnapshot.Post(name: "Mina", emoji: "🌸", tier: .onTime,
                                            loggedAt: now, thumb: thumb)],
                waiting: [WidgetSnapshot.Waiting(userID: "u1", name: "Harun", emoji: "🧢",
                                                 nudgedThisWindow: false)]))
    }

    // MARK: - The shape §3 specifies

    func testFileCarriesExactlyTheKeysSpecV5Section3Names() throws {
        let object = try json(sampleSnapshot())

        XCTAssertEqual(Set(object.keys), ["writtenAt", "mode", "window", "you", "circle"])

        let window = try XCTUnwrap(object["window"] as? [String: Any])
        XCTAssertEqual(Set(window.keys), ["prayer", "dayKey", "opensAt", "endsAt"])
        XCTAssertEqual(window["prayer"] as? String, "asr")

        let you = try XCTUnwrap(object["you"] as? [String: Any])
        XCTAssertEqual(Set(you.keys), ["logged", "streak"])

        let circle = try XCTUnwrap(object["circle"] as? [String: Any])
        XCTAssertEqual(Set(circle.keys), ["prayedCount", "memberCount", "posts", "waiting"])

        let posts = try XCTUnwrap(circle["posts"] as? [[String: Any]])
        XCTAssertEqual(Set(posts[0].keys), ["name", "emoji", "tier", "loggedAt", "thumb"])
        XCTAssertEqual(posts[0]["tier"] as? String, "onTime")

        let waiting = try XCTUnwrap(circle["waiting"] as? [[String: Any]])
        XCTAssertEqual(Set(waiting[0].keys), ["userID", "name", "emoji", "nudgedThisWindow"])

        XCTAssertEqual(object["mode"] as? String, "real")
    }

    func testAPhotolessPostWritesNoThumbKeyAtAll() throws {
        let object = try json(sampleSnapshot(thumb: nil))
        let circle = try XCTUnwrap(object["circle"] as? [String: Any])
        let posts = try XCTUnwrap(circle["posts"] as? [[String: Any]])
        XCTAssertEqual(Set(posts[0].keys), ["name", "emoji", "tier", "loggedAt"])
    }

    /// SPEC-V5 §7: `breakReason` never enters `widget.json`.
    ///
    /// It is enforced by the SHAPE of the type — there is no field it could
    /// travel in — and this is what keeps that true. A later phase adding a
    /// `reason`, a `note` or a `breakReason` anywhere in this file fails here
    /// before it can reach anybody's home screen, which is a surface the user
    /// cannot even see to check.
    func testNoKeyAnywhereCouldCarryABreakReason() throws {
        let found: Set<String> = keys(in: try json(sampleSnapshot()))
        let allowed: Set<String> = ["writtenAt", "mode", "window", "you", "circle",
                                    "prayer", "dayKey", "opensAt", "endsAt",
                                    "logged", "streak",
                                    "prayedCount", "memberCount", "posts", "waiting",
                                    "name", "emoji", "tier", "loggedAt", "thumb",
                                    "userID", "nudgedThisWindow"]
        XCTAssertTrue(found.isSubset(of: allowed),
                      "unexpected keys in widget.json: \(found.subtracting(allowed))")
        for key in found {
            let lowered: String = key.lowercased()
            XCTAssertFalse(lowered.contains("reason"), "\(key) could carry a break reason")
            XCTAssertFalse(lowered.contains("break"), "\(key) could carry a break reason")
            XCTAssertFalse(lowered.contains("excused"), "\(key) leaks the rest-day flag")
        }
    }

    // MARK: - The coder the two processes share

    func testRoundTripsThroughTheFilesOwnCoder() throws {
        let original = sampleSnapshot()
        let data: Data = try XCTUnwrap(WidgetFile.encode(original))
        let decoded: WidgetSnapshot = try XCTUnwrap(WidgetFile.decode(data))
        XCTAssertEqual(decoded, original)
    }

    func testWritesAndReadsBackFromDisk() throws {
        let directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url: URL = directory.appendingPathComponent(WidgetFile.name)
        XCTAssertTrue(WidgetFile.write(sampleSnapshot(), to: url))
        XCTAssertEqual(WidgetFile.read(at: url), sampleSnapshot())
        XCTAssertNil(WidgetFile.read(at: directory.appendingPathComponent("nothing.json")))
    }

    /// The app and the widget are separately versioned binaries: iOS keeps
    /// running the installed extension while the app updates underneath it. A
    /// file with fields this build has never seen — or missing ones it expects —
    /// has to render.
    func testDecodesAFileWrittenByAnotherVersion() throws {
        let raw = """
        {
          "writtenAt": "2026-06-10T17:00:00Z",
          "mode": "real",
          "somethingFromTheFuture": 7,
          "window": { "prayer": "asr", "dayKey": "2026-06-10",
                      "opensAt": "2026-06-10T16:00:00Z", "endsAt": "2026-06-10T18:00:00Z" },
          "you": { "streak": 3 },
          "circle": { "memberCount": 2,
                      "posts": [ { "name": "Mina", "tier": "someNewTier",
                                   "loggedAt": "2026-06-10T16:30:00Z" } ] }
        }
        """
        let decoded: WidgetSnapshot = try XCTUnwrap(WidgetFile.decode(Data(raw.utf8)))
        XCTAssertEqual(decoded.window?.prayer, .asr)
        XCTAssertFalse(decoded.you.logged)          // absent → the safe default
        XCTAssertEqual(decoded.you.streak, 3)
        XCTAssertEqual(decoded.circle.prayedCount, 0)
        XCTAssertEqual(decoded.circle.waiting, [])
        // A tier nobody here has heard of still means somebody prayed.
        XCTAssertEqual(decoded.circle.posts.first?.tier, .prayed)
        XCTAssertEqual(decoded.circle.posts.first?.emoji, "🙂")
    }

    func testAnUnusableWindowLeavesTheRestOfTheFileReadable() throws {
        let raw = """
        {
          "writtenAt": "2026-06-10T17:00:00Z", "mode": "demo",
          "window": { "dayKey": "2026-06-10" },
          "you": { "logged": true, "streak": 9 },
          "circle": { "prayedCount": 1, "memberCount": 2, "posts": [], "waiting": [] }
        }
        """
        let decoded: WidgetSnapshot = try XCTUnwrap(WidgetFile.decode(Data(raw.utf8)))
        XCTAssertNil(decoded.window)
        XCTAssertEqual(decoded.you.streak, 9)
    }

    func testGarbageIsNilRatherThanACrash() {
        XCTAssertNil(WidgetFile.decode(Data("not json at all".utf8)))
        XCTAssertNil(WidgetFile.decode(Data()))
    }

    // MARK: - Building from a real circle's mirror

    /// Three friends and you, on the fixed day's Asr: Mina posted on time with a
    /// photo, Harun posted late without one, Zayd has not prayed yet.
    private func realFixture(now: Date, yourState: GridEntryState = .waiting,
                             hidden: Set<String> = [],
                             extraPosts: [RemotePost] = [],
                             excused: [RemoteExcusedDay] = [],
                             nudged: Set<String> = []) -> WidgetSnapshot {
        let day = fixedDay()
        let window: PrayerWindow = day.schedule.window(for: .asr)!
        let me = UUID(), mina = UUID(), harun = UUID(), zayd = UUID()
        var posts: [RemotePost] = [
            post(mina, .asr, day.dayKey, tier: .onTime,
                 at: window.start.addingTimeInterval(5 * 60),
                 photoPath: "circle/mina/one.jpg"),
            post(harun, .asr, day.dayKey, tier: .lastCall,
                 at: window.start.addingTimeInterval(70 * 60)),
        ]
        posts.append(contentsOf: extraPosts)
        let mirrorSnapshot = mirror(
            me: me, friends: [mina, harun, zayd],
            profiles: [profile(me, "Haashim", "😄"), profile(mina, "Mina", "🌸"),
                       profile(harun, "Harun", "🧢"), profile(zayd, "Zayd", "🎧")],
            posts: posts, excused: excused)
        let source = RemoteCircleDataSource(snapshot: mirrorSnapshot)
        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .real, streak: 41,
            window: (window, day.dayKey),
            entries: entries(source: source, you: you(), yourState: yourState,
                             prayer: .asr, dayKey: day.dayKey, window: window, now: now),
            photoPaths: photoPaths(source: source, prayer: .asr, dayKey: day.dayKey, now: now),
            nudgedMemberIDs: nudged,
            hiddenPhotoPaths: hidden)
        return built
    }

    func testCountsTheWholeCircleYouIncluded() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let built = realFixture(now: now)

        XCTAssertEqual(built.circle.memberCount, 4)     // three friends and you
        XCTAssertEqual(built.circle.prayedCount, 2)     // Mina and Harun
        XCTAssertFalse(built.you.logged)
        XCTAssertEqual(built.you.streak, 41)
        XCTAssertEqual(built.mode, .real)
        XCTAssertEqual(built.window?.prayer, .asr)
        XCTAssertEqual(built.window?.dayKey, day.dayKey)
        XCTAssertEqual(built.window?.opensAt, window.start)
        XCTAssertEqual(built.window?.endsAt, window.end)
    }

    func testYourOwnPostCountsAndYouAreNeverANudgeTarget() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let mine: GridEntryState = .posted(.illustration(seed: 1), tier: .prayed,
                                           at: window.start.addingTimeInterval(60 * 60))
        let built = realFixture(now: now, yourState: mine)

        XCTAssertTrue(built.you.logged)
        XCTAssertEqual(built.circle.prayedCount, 3)
        XCTAssertTrue(built.circle.posts.contains { $0.name == "Haashim" })
        XCTAssertFalse(built.circle.waiting.contains { $0.name == "Haashim" })
    }

    func testPostsAreNewestFirstAndCappedAtFour() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.end.addingTimeInterval(-60)
        // Six people have prayed: four friends by post, plus you.
        let extra: [UUID] = [UUID(), UUID(), UUID()]
        var posts: [RemotePost] = []
        for (offset, id) in extra.enumerated() {
            posts.append(post(id, .asr, day.dayKey, tier: .prayed,
                              at: window.start.addingTimeInterval(Double(20 + offset * 5) * 60)))
        }
        let me = UUID(), mina = UUID()
        var profiles: [RemoteProfile] = [profile(me, "Haashim", "😄"), profile(mina, "Mina", "🌸")]
        for (offset, id) in extra.enumerated() {
            profiles.append(profile(id, "Friend\(offset)", "🙂"))
        }
        posts.append(post(mina, .asr, day.dayKey, tier: .onTime,
                          at: window.start.addingTimeInterval(2 * 60)))
        let mirrorSnapshot = mirror(me: me, friends: [mina] + extra,
                                    profiles: profiles, posts: posts)
        let source = RemoteCircleDataSource(snapshot: mirrorSnapshot)
        let mine: GridEntryState = .posted(.illustration(seed: 2), tier: .prayed,
                                           at: window.start.addingTimeInterval(75 * 60))
        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .real, streak: 1, window: (window, day.dayKey),
            entries: entries(source: source, you: you(), yourState: mine,
                             prayer: .asr, dayKey: day.dayKey, window: window, now: now))

        XCTAssertEqual(built.circle.prayedCount, 5)
        XCTAssertEqual(built.circle.memberCount, 5)
        XCTAssertEqual(built.circle.posts.count, WidgetSnapshot.postCap)
        // Newest first — and the OLDEST (Mina, two minutes in) is the one the
        // cap drops, never the newest.
        let times: [Date] = built.circle.posts.map { $0.loggedAt }
        XCTAssertEqual(times, times.sorted(by: >))
        XCTAssertEqual(built.circle.posts.first?.name, "Haashim")
        XCTAssertFalse(built.circle.posts.contains { $0.name == "Mina" })
    }

    func testTiesBreakOnNameSoTwoDevicesNeverDisagree() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let at = window.start.addingTimeInterval(30 * 60)
        let members: [CircleMember] = [
            CircleMember(id: "b", name: "Bilal", emoji: "🙂", isYou: false),
            CircleMember(id: "a", name: "Amina", emoji: "🌸", isYou: false),
        ]
        let entries: [GridEntry] = members.map {
            GridEntry(id: $0.id, member: $0,
                      state: .posted(.illustration(seed: 0), tier: .onTime, at: at))
        }
        let built = WidgetSnapshotBuilder.make(
            writtenAt: at, mode: .demo, streak: 0, window: (window, day.dayKey),
            entries: entries)
        XCTAssertEqual(built.circle.posts.map { $0.name }, ["Amina", "Bilal"])
    }

    func testWaitingIsOnlyFriendsWhoseWindowIsStillOpenAndStillEmpty() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let built = realFixture(now: now)

        XCTAssertEqual(built.circle.waiting.map { $0.name }, ["Zayd"])
        XCTAssertEqual(built.circle.waiting.first?.emoji, "🎧")
        XCTAssertFalse(built.circle.waiting[0].nudgedThisWindow)
    }

    func testAMissedWindowIsNotANudgeTarget() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        // After the window has closed, Zayd has not missed the chance to be
        // nudged — he has missed the window, and there is nothing to ask for.
        let built = realFixture(now: window.end.addingTimeInterval(60))
        XCTAssertTrue(built.circle.waiting.isEmpty)
        XCTAssertEqual(built.circle.prayedCount, 2)
        XCTAssertEqual(built.circle.memberCount, 4)
    }

    /// SPEC-V5 §7 / SPEC-V4 §3: a rest day travels as a bare flag, and the one
    /// thing the home screen must not do with it is turn it into a nudge.
    func testSomebodyRestingIsNeitherPrayedNorWaiting() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let me = UUID(), zayd = UUID()
        let mirrorSnapshot = mirror(
            me: me, friends: [zayd],
            profiles: [profile(me, "Haashim", "😄"), profile(zayd, "Zayd", "🎧")],
            posts: [],
            excused: [RemoteExcusedDay(userID: zayd, circleID: circleID, dayKey: day.dayKey)])
        let source = RemoteCircleDataSource(snapshot: mirrorSnapshot)
        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .real, streak: 0, window: (window, day.dayKey),
            entries: entries(source: source, you: you(), yourState: .waiting,
                             prayer: .asr, dayKey: day.dayKey, window: window, now: now))

        XCTAssertEqual(built.circle.memberCount, 2)
        XCTAssertEqual(built.circle.prayedCount, 0)
        XCTAssertTrue(built.circle.waiting.isEmpty)
        XCTAssertTrue(built.circle.posts.isEmpty)
    }

    func testAMakeUpStillCountsAsPrayed() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.end.addingTimeInterval(30 * 60)
        let qadaAt = window.end.addingTimeInterval(10 * 60)
        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .demo, streak: 4, window: (window, day.dayKey),
            entries: [GridEntry(id: "you", member: you(), state: .qada(at: qadaAt))])

        XCTAssertTrue(built.you.logged)
        XCTAssertEqual(built.circle.prayedCount, 1)
        XCTAssertEqual(built.circle.posts.first?.tier, .qada)
        XCTAssertEqual(built.circle.posts.first?.loggedAt, qadaAt)
    }

    func testNudgeAlreadySentTravelsWithTheWaitingEntry() throws {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let zayd: String = try XCTUnwrap(realFixture(now: now).circle.waiting.first).userID
        let again = realFixture(now: now, nudged: [zayd])
        XCTAssertEqual(again.circle.waiting.count, 1)
        XCTAssertTrue(again.circle.waiting[0].nudgedThisWindow)
    }

    // MARK: - SPEC-V5 §7 — photos

    func testAVisiblePhotoBecomesItsBuddyCacheKey() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let built = realFixture(now: now)
        let mina = built.circle.posts.first { $0.name == "Mina" }

        XCTAssertEqual(mina?.thumb, BuddyPhotoCache.key(forRemotePath: "circle/mina/one.jpg"))
        // Never the path itself: a widget resolves a cache filename, and the
        // Storage path is not one.
        XCTAssertNotEqual(mina?.thumb, "circle/mina/one.jpg")
        XCTAssertNil(built.circle.posts.first { $0.name == "Harun" }?.thumb)
    }

    /// SPEC-V5 §7, reports. A photo this device reported is hidden in the app
    /// by a set of paths on disk; the home screen is a second surface for the
    /// same bytes, and the hide has to reach it. The POST stays — the person
    /// still prayed, and the count must not lie about it — only the picture goes.
    func testAReportedPhotoLosesItsThumbAndKeepsItsPost() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let now = window.start.addingTimeInterval(80 * 60)
        let built = realFixture(now: now, hidden: ["circle/mina/one.jpg"])
        let mina = built.circle.posts.first { $0.name == "Mina" }

        XCTAssertNotNil(mina)
        XCTAssertNil(mina?.thumb)
        XCTAssertEqual(built.circle.prayedCount, 2)
        // And the name of the hidden file appears nowhere in what gets written.
        let encoded: String = String(data: WidgetFile.encode(built)!, encoding: .utf8)!
        XCTAssertFalse(encoded.contains(BuddyPhotoCache.key(forRemotePath: "circle/mina/one.jpg")))
        XCTAssertFalse(encoded.contains("circle/mina/one.jpg"))
    }

    func testTheHideRuleItself() {
        XCTAssertNil(WidgetSnapshotBuilder.thumb(forPhotoPath: nil, hiddenPaths: []))
        XCTAssertNil(WidgetSnapshotBuilder.thumb(forPhotoPath: "", hiddenPaths: []))
        XCTAssertNil(WidgetSnapshotBuilder.thumb(forPhotoPath: "a/b.jpg", hiddenPaths: ["a/b.jpg"]))
        XCTAssertEqual(WidgetSnapshotBuilder.thumb(forPhotoPath: "a/b.jpg", hiddenPaths: ["other"]),
                       BuddyPhotoCache.key(forRemotePath: "a/b.jpg"))
    }

    /// Your own photo is a `PhotoStore` file — a different store with a
    /// different lifetime (SPEC-V4 §4) and no cache key. P3 decides how it
    /// reaches the extension; until then it is deliberately absent rather than
    /// wrongly named.
    func testYourOwnPostCarriesNoThumb() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let at = window.start.addingTimeInterval(10 * 60)
        let built = WidgetSnapshotBuilder.make(
            writtenAt: at, mode: .demo, streak: 0, window: (window, day.dayKey),
            entries: [GridEntry(id: "you", member: you(),
                                state: .posted(.photo(filename: "mine.jpg"), tier: .onTime, at: at))],
            photoPaths: ["you": "circle/me/one.jpg"])
        XCTAssertNil(built.circle.posts.first?.thumb)
    }

    // MARK: - The demo circle renders through the identical path (§9-03)

    func testDemoCircleFoldsThroughTheSameBuilderAsARealOne() {
        let day = fixedDay()
        let window: PrayerWindow = day.schedule.window(for: .asr)!
        let now = window.end.addingTimeInterval(-60)
        let roster: [BuddySimulator.Buddy] = BuddySimulator.buddies
        let source = SimulatedCircleDataSource(buddies: roster)

        // What the simulator itself says, asked directly — the parity style
        // `CircleSeamTests` uses.
        var expectedPrayed: Int = 0
        for buddy in roster {
            switch BuddySimulator.outcome(for: buddy, dayKey: day.dayKey, window: window) {
            case .inWindow(_, let at, _): if now >= at { expectedPrayed += 1 }
            case .qada(let at): if now >= at { expectedPrayed += 1 }
            case .missed: break
            }
        }

        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .demo, streak: 7, window: (window, day.dayKey),
            entries: entries(source: source, you: you(), yourState: .waiting,
                             prayer: .asr, dayKey: day.dayKey, window: window, now: now),
            photoPaths: photoPaths(source: source, prayer: .asr, dayKey: day.dayKey, now: now))

        XCTAssertEqual(built.mode, .demo)
        XCTAssertEqual(built.circle.memberCount, roster.count + 1)
        XCTAssertEqual(built.circle.prayedCount, expectedPrayed)
        XCTAssertTrue(built.circle.posts.count <= WidgetSnapshot.postCap)
        let times: [Date] = built.circle.posts.map { $0.loggedAt }
        XCTAssertEqual(times, times.sorted(by: >))
        // Simulated posts are seeded illustrations, never files — so a demo
        // circle names no photos, and the seam is what says so (the default
        // `photoPath` answers nil).
        XCTAssertTrue(built.circle.posts.allSatisfy { $0.thumb == nil })
    }

    func testASoloCircleIsJustYou() {
        let day = fixedDay()
        let window = day.schedule.window(for: .asr)!
        let source = SimulatedCircleDataSource(buddies: [])
        let now = window.start.addingTimeInterval(10 * 60)
        let built = WidgetSnapshotBuilder.make(
            writtenAt: now, mode: .demo, streak: 3, window: (window, day.dayKey),
            entries: entries(source: source, you: you(), yourState: .waiting,
                             prayer: .asr, dayKey: day.dayKey, window: window, now: now))
        XCTAssertEqual(built.circle.memberCount, 1)
        XCTAssertEqual(built.circle.prayedCount, 0)
        XCTAssertTrue(built.circle.waiting.isEmpty)
    }

    // MARK: - Which window the home screen is about

    func testTheOpenWindowWins() {
        let day = fixedDay()
        let asr = day.schedule.window(for: .asr)!
        let picked = WidgetSnapshotBuilder.window(in: day.schedule, carryOver: nil,
                                                  now: asr.start.addingTimeInterval(60))
        XCTAssertEqual(picked?.window.prayer, .asr)
        XCTAssertEqual(picked?.dayKey, day.dayKey)
    }

    func testBetweenWindowsItIsTheNextOneToOpen() {
        let day = fixedDay()
        let fajr = day.schedule.window(for: .fajr)!
        // The real gap between sunrise and dhuhr — hours long, and the widget
        // has to say something during it.
        let picked = WidgetSnapshotBuilder.window(in: day.schedule, carryOver: nil,
                                                  now: fajr.end.addingTimeInterval(60))
        XCTAssertEqual(picked?.window.prayer, .dhuhr)
    }

    func testBeforeTheFirstWindowItIsFajr() {
        let day = fixedDay()
        let picked = WidgetSnapshotBuilder.window(in: day.schedule, carryOver: nil,
                                                  now: day.schedule.dayStart)
        XCTAssertEqual(picked?.window.prayer, .fajr)
    }

    /// A schedule everyone has walked past — an app that has not been opened
    /// since yesterday. "The day's last window, closed" is truthful; nothing at
    /// all is not.
    func testAFullyElapsedDayHoldsItsLastWindow() {
        let day = fixedDay()
        let isha = day.schedule.window(for: .isha)!
        let picked = WidgetSnapshotBuilder.window(in: day.schedule, carryOver: nil,
                                                  now: isha.end.addingTimeInterval(3600))
        XCTAssertEqual(picked?.window.prayer, .isha)
    }

    /// Yesterday's isha ends at TODAY's fajr, so between midnight and fajr the
    /// window a person is standing in belongs to yesterday's schedule day.
    func testYesterdaysIshaWinsWhileItIsStillOpen() {
        let day = fixedDay()
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: day.schedule.dayStart)!
        let yesterdayKey = AppClock.dayKey(for: yesterdayStart)
        let carryOver = PrayerWindow(prayer: .isha,
                                     start: yesterdayStart.addingTimeInterval(21 * 3600),
                                     end: day.schedule.dayStart.addingTimeInterval(5.5 * 3600))
        let oneAM = day.schedule.dayStart.addingTimeInterval(3600)

        let picked = WidgetSnapshotBuilder.window(in: day.schedule,
                                                  carryOver: (carryOver, yesterdayKey), now: oneAM)
        XCTAssertEqual(picked?.window.prayer, .isha)
        XCTAssertEqual(picked?.dayKey, yesterdayKey)

        // Once it closes, today's schedule takes over again.
        let afterFajrOpens = carryOver.end.addingTimeInterval(60)
        let next = WidgetSnapshotBuilder.window(in: day.schedule,
                                                carryOver: (carryOver, yesterdayKey),
                                                now: afterFajrOpens)
        XCTAssertEqual(next?.window.prayer, .fajr)
        XCTAssertEqual(next?.dayKey, day.dayKey)
    }

    func testNoScheduleMeansNoWindow() {
        XCTAssertNil(WidgetSnapshotBuilder.window(in: nil, carryOver: nil, now: Date()))
        let built = WidgetSnapshotBuilder.make(writtenAt: Date(), mode: .demo, streak: 0,
                                               window: nil, entries: [])
        XCTAssertNil(built.window)
        XCTAssertEqual(built.circle.memberCount, 0)
    }

    // MARK: - The timeline the widget builds from this file

    func testEntriesLandOnTheWindowBoundaries() throws {
        let now = date(2026, 6, 10, 12, 0)
        let opens = now.addingTimeInterval(3600)
        let ends = now.addingTimeInterval(3 * 3600)
        let snapshot = WidgetSnapshot(
            writtenAt: now, mode: .real,
            window: WidgetSnapshot.Window(prayer: .asr, dayKey: "2026-06-10",
                                          opensAt: opens, endsAt: ends),
            you: WidgetSnapshot.You(logged: false, streak: 0),
            circle: .empty)

        XCTAssertEqual(snapshot.timelineDates(from: now), [now, opens, ends])
        // Mid-window: the boundary already passed is not scheduled again.
        let midway = opens.addingTimeInterval(60)
        XCTAssertEqual(snapshot.timelineDates(from: midway), [midway, ends])
        XCTAssertEqual(snapshot.reloadDate(from: midway), ends)
    }

    func testAClosedWindowAsksAgainLaterRatherThanImmediately() {
        let now = date(2026, 6, 10, 12, 0)
        let snapshot = WidgetSnapshot(
            writtenAt: now, mode: .real,
            window: WidgetSnapshot.Window(prayer: .asr, dayKey: "2026-06-10",
                                          opensAt: now.addingTimeInterval(-7200),
                                          endsAt: now.addingTimeInterval(-3600)),
            you: WidgetSnapshot.You(logged: false, streak: 0),
            circle: .empty)

        XCTAssertEqual(snapshot.timelineDates(from: now), [now])
        XCTAssertEqual(snapshot.reloadDate(from: now),
                       now.addingTimeInterval(WidgetSnapshot.stalePeriod))
    }

    /// A DEBUG clock that has time-travelled forward writes boundaries days
    /// away. Without the clamp the home screen would freeze until the next
    /// launch.
    func testATimeTravelledFileCannotParkTheWidgetForever() {
        let now = date(2026, 6, 10, 12, 0)
        let snapshot = WidgetSnapshot(
            writtenAt: now, mode: .demo,
            window: WidgetSnapshot.Window(prayer: .isha, dayKey: "2026-06-14",
                                          opensAt: now.addingTimeInterval(4 * 86_400),
                                          endsAt: now.addingTimeInterval(5 * 86_400)),
            you: WidgetSnapshot.You(logged: false, streak: 0),
            circle: .empty)

        XCTAssertEqual(snapshot.timelineDates(from: now), [now])
        XCTAssertEqual(snapshot.reloadDate(from: now),
                       now.addingTimeInterval(WidgetSnapshot.stalePeriod))
    }

    func testABoundaryASecondAwayStillCostsAWholeMinute() {
        let now = date(2026, 6, 10, 12, 0)
        let snapshot = WidgetSnapshot(
            writtenAt: now, mode: .real,
            window: WidgetSnapshot.Window(prayer: .asr, dayKey: "2026-06-10",
                                          opensAt: now.addingTimeInterval(-3600),
                                          endsAt: now.addingTimeInterval(1)),
            you: WidgetSnapshot.You(logged: false, streak: 0),
            circle: .empty)
        XCTAssertEqual(snapshot.reloadDate(from: now),
                       now.addingTimeInterval(WidgetSnapshot.minWait))
    }

    func testNoWindowStillSchedulesALookLater() {
        let now = date(2026, 6, 10, 12, 0)
        let snapshot = WidgetSnapshot(writtenAt: now, mode: .demo, window: nil,
                                      you: WidgetSnapshot.You(logged: false, streak: 0),
                                      circle: .empty)
        XCTAssertEqual(snapshot.timelineDates(from: now), [now])
        XCTAssertEqual(snapshot.reloadDate(from: now),
                       now.addingTimeInterval(WidgetSnapshot.stalePeriod))
    }

    // MARK: - Writing only when something changed

    func testOnlyTheTimestampChangingIsNotAChange() {
        let first = sampleSnapshot()
        var second = first
        second.writtenAt = first.writtenAt.addingTimeInterval(600)
        XCTAssertTrue(first.hasSameContent(as: second))

        var third = second
        third.circle.prayedCount += 1
        XCTAssertFalse(first.hasSameContent(as: third))
    }
}
