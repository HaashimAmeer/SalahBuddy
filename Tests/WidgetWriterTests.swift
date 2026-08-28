import Foundation
import XCTest
@testable import SalahBuddy

/// v5 §3 (P2) — `AppState.publishWidgetSnapshot`, the WRITER.
///
/// `WidgetSnapshotTests` covers the shape: given a window and a list of grid
/// entries, what does the file say. That is the pure half, and it is the half a
/// test can hold still. It is not the half that breaks.
///
/// What breaks is the wiring, and the wiring is invisible to those tests
/// because they hand the builder its arguments themselves. Delete
/// `hiddenPhotoPaths:` from the one production call site — it defaults to `[]` —
/// and every §7 assertion over there still passes while every reported photo's
/// cache key is written onto somebody's home screen. The same holds for
/// dropping `photoPaths:`, for `nudgedMemberIDs:`, and for handing `gridEntries`
/// the wrong `dayKey` after midnight. So these tests never build a snapshot:
/// they drive an `AppState`, let it write, and read `widget.json` back off the
/// disk the extension would open.
///
/// **How an `AppState` is built here** is `SavedPlacesTests`' rig, and its
/// tradeoff is the same one, deliberately: `Store.directory` is not injectable,
/// so the test host's real container IS the seam. Every file touched is
/// snapshotted and put back in teardown; a hard crash mid-test skips that, and
/// a crash is already a failed run.
@MainActor
final class WidgetWriterTests: XCTestCase {

    /// Reported paths this test filed, to be forgotten again — `PhotoReports`
    /// is process-wide and the app deliberately has no unhide.
    private var hidesToForget: [String] = []
    private var reporterToRestore: (() -> UUID?)?

    override func tearDown() async throws {
        for path in hidesToForget { PhotoReports.shared.forgetHideForTesting(path) }
        hidesToForget = []
        if let reporterToRestore { PhotoReports.shared.currentUserID = reporterToRestore }
        reporterToRestore = nil
        try await super.tearDown()
    }

    // MARK: - Rig

    private var widgetURL: URL { Store.url(for: Store.widgetFile) }

    /// Every file an `AppState` reads or writes, put back afterwards.
    ///
    /// `reports.json` is spelled out because `PhotoReports.file` is private —
    /// and it has to be here, since filing a report to prove §7 writes it.
    private func preserveFiles() {
        for file in [Store.settingsFile, Store.profileFile, Store.logsFile,
                     Store.circleFile, Store.widgetFile, "reports.json"] {
            let url: URL = Store.url(for: file)
            let original: Data? = try? Data(contentsOf: url)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: url)
                if let original { try? original.write(to: url, options: .atomic) }
            }
        }
        addTeardownBlock {
            // Order matters: a pinned clock refuses every move except back to
            // real time, so hand time travel back BEFORE clearing the offset.
            AppClock.isTimeTravelAllowed = true
            AppClock.offset = 0
        }
    }

    /// A known-empty disk: fixed Seattle coordinates (no CoreLocation, so the
    /// schedule is a pure function of the clock), a profile old enough that
    /// nothing is "before you joined", and a demo circle with buddies in it —
    /// `UserProfile.fresh` starts SOLO, which would leave every test below
    /// with a circle of one.
    private func prepareDisk(circleMode: CircleMode = .demo) {
        preserveFiles()
        AppClock.isTimeTravelAllowed = true
        AppClock.offset = 0
        #if DEBUG
        LocationProvider.shared.simulateDeviceFix(nil)
        #endif
        for file in [Store.profileFile, Store.logsFile, Store.circleFile, Store.widgetFile] {
            try? FileManager.default.removeItem(at: Store.url(for: file))
        }
        var profile: UserProfile = .fresh(now: Date().addingTimeInterval(-90 * 86_400))
        profile.startedSolo = false
        Store.save(profile, to: Store.profileFile)

        var settings = AppSettings()
        settings.circleMode = circleMode
        settings.useDeviceLocation = false
        Store.save(settings, to: Store.settingsFile)
    }

    /// Move the app's clock to `target` and let it catch up. `refresh()` is
    /// what recomputes the schedule and republishes, exactly as a foreground
    /// or a day change would.
    private func travel(to target: Date, _ state: AppState) {
        AppClock.offset = target.timeIntervalSince(Date())
        state.refresh()
    }

    private func prayed(_ entry: GridEntry) -> Bool {
        switch entry.state {
        case .posted, .qada: return true
        case .waiting, .missed, .excused: return false
        }
    }

    private func published() -> WidgetSnapshot? {
        WidgetFile.read(at: widgetURL)
    }

    // MARK: - Where the file goes

    /// The app writes through `Store.url(for:)` and the extension opens
    /// `WidgetFile.url`. Nothing else asserts those are the same place — and if
    /// they ever part (a `Store.directory` moved into a subdirectory, say)
    /// every widget on every home screen goes blank with a fully green suite.
    func testTheAppWritesTheFileTheExtensionOpens() throws {
        prepareDisk()

        XCTAssertEqual(widgetURL.lastPathComponent, WidgetFile.name)
        if let container: URL = WidgetFile.containerURL {
            // Entitled builds only — a test host without the App Group falls
            // back to Documents by design, and the widget, which has no
            // fallback, simply renders empty there.
            XCTAssertEqual(Store.directory.standardizedFileURL, container.standardizedFileURL)
            XCTAssertEqual(widgetURL.standardizedFileURL, WidgetFile.url?.standardizedFileURL)
        }

        let state = AppState()
        state.publishWidgetSnapshot()

        let file: WidgetSnapshot = try XCTUnwrap(published(), "no file where the widget looks")
        XCTAssertEqual(file.mode, .demo)
        XCTAssertEqual(file.circle.memberCount, state.circleMembers.count)
        XCTAssertEqual(file.you.streak, state.profile.streak)
    }

    // MARK: - SPEC-V5 §7 — the report hide, through the real writer

    /// The invariant §7 calls worse-than-never-offering-the-report, asserted
    /// on the bytes that actually land in the container.
    ///
    /// Both halves matter and they fail differently: without `photoPaths:` the
    /// first half fails (no photo ever reaches the file, so P3 has nothing to
    /// draw), and without `hiddenPhotoPaths:` the second does (a reported photo
    /// keeps its name, and the home screen brings it back).
    func testAReportedPhotoCannotReachTheFileThroughTheRealWriter() throws {
        prepareDisk(circleMode: .real)
        // No session, so `hide` files the local half and queues nothing —
        // and, more to the point, never reaches for the Supabase client.
        reporterToRestore = PhotoReports.shared.currentUserID
        PhotoReports.shared.currentUserID = { nil }

        let state = AppState()
        state.publishWidgetSnapshot()
        let opening: WidgetSnapshot = try XCTUnwrap(published())
        // Which window the home screen is about right now is the app's answer,
        // not this test's — so the mirror below is built INTO it and the test
        // holds at any hour of any day.
        let window: WidgetSnapshot.Window = try XCTUnwrap(opening.window)

        let path: String = "circle/widget-writer-test/one.jpg"
        let circleID = UUID(), me = UUID(), mina = UUID()
        let minaPost = RemotePost(id: UUID(), userID: mina, circleID: circleID,
                                  dayKey: window.dayKey, prayer: window.prayer,
                                  tier: .onTime,
                                  loggedAt: opening.writtenAt.addingTimeInterval(-60),
                                  photoPath: path)
        let mirror = CircleSnapshot(
            circle: RemoteCircle(id: circleID, code: "ABC234", name: "Test", emoji: "🤝"),
            me: me,
            profiles: [RemoteProfile(id: me, name: "Haashim", avatarEmoji: "😄"),
                       RemoteProfile(id: mina, name: "Mina", avatarEmoji: "🌸")],
            members: [RemoteMember(circleID: circleID, userID: me,
                                   joinedAt: Date(timeIntervalSince1970: 1)),
                      RemoteMember(circleID: circleID, userID: mina,
                                   joinedAt: Date(timeIntervalSince1970: 2))],
            posts: [minaPost], excusedDays: [])
        state.applyCircleSnapshot(mirror)

        let visible: WidgetSnapshot = try XCTUnwrap(published())
        let before = try XCTUnwrap(visible.circle.posts.first { $0.name == "Mina" },
                                   "the mirror's post never reached the file")
        XCTAssertEqual(before.thumb, BuddyPhotoCache.key(forRemotePath: path),
                       "the seam's photo path has to arrive as a cache key")

        hidesToForget.append(path)
        PhotoReports.shared.hide(minaPost)
        state.publishWidgetSnapshot()

        let hidden: WidgetSnapshot = try XCTUnwrap(published())
        let after = try XCTUnwrap(hidden.circle.posts.first { $0.name == "Mina" },
                                  "the POST stays — she prayed, and the count must not lie")
        XCTAssertNil(after.thumb)
        XCTAssertEqual(hidden.circle.prayedCount, visible.circle.prayedCount)

        // And the file on disk names neither the photo nor its cache key.
        let raw: String = try XCTUnwrap(String(data: try Data(contentsOf: widgetURL),
                                               encoding: .utf8))
        XCTAssertFalse(raw.contains(path))
        XCTAssertFalse(raw.contains(BuddyPhotoCache.key(forRemotePath: path)))
    }

    // MARK: - SPEC-V5 §7/§9-02 — the widget photo setting, through the real writer

    /// A real circle in which Mina has posted the CURRENT window with a photo.
    /// Which window that is is the app's own answer, not the test's, so
    /// everything built on this holds at any hour of any day.
    @discardableResult
    private func minaPosts(into state: AppState) throws
    -> (path: String, window: WidgetSnapshot.Window) {
        state.publishWidgetSnapshot()
        let opening: WidgetSnapshot = try XCTUnwrap(published())
        let window: WidgetSnapshot.Window = try XCTUnwrap(opening.window)

        let path = "circle/widget-style-test/one.jpg"
        let circleID = UUID(), me = UUID(), mina = UUID()
        let minaPost = RemotePost(id: UUID(), userID: mina, circleID: circleID,
                                  dayKey: window.dayKey, prayer: window.prayer,
                                  tier: .onTime,
                                  loggedAt: opening.writtenAt.addingTimeInterval(-60),
                                  photoPath: path)
        state.applyCircleSnapshot(CircleSnapshot(
            circle: RemoteCircle(id: circleID, code: "ABC234", name: "Test", emoji: "🤝"),
            me: me,
            profiles: [RemoteProfile(id: me, name: "Haashim", avatarEmoji: "😄"),
                       RemoteProfile(id: mina, name: "Mina", avatarEmoji: "🌸")],
            members: [RemoteMember(circleID: circleID, userID: me,
                                   joinedAt: Date(timeIntervalSince1970: 1)),
                      RemoteMember(circleID: circleID, userID: mina,
                                   joinedAt: Date(timeIntervalSince1970: 2))],
            posts: [minaPost], excusedDays: []))
        return (path, window)
    }

    private func style(_ style: WidgetPhotoStyle, on state: AppState) {
        var settings: AppSettings = state.settings
        settings.widgetPhotoStyle = style
        state.settings = settings
    }

    /// §9-02's setting has to reach the file through the PRODUCTION call site,
    /// which is the half `WidgetSnapshotTests` cannot see: it hands the builder
    /// its arguments itself, and `photoStyle:` defaults to `.photos`. Drop it
    /// from `AppState.publishWidgetSnapshot` and every assertion over there
    /// still passes while somebody who asked for no faces on their home screen
    /// keeps getting them.
    func testTheWidgetPhotoSettingReachesTheFileThroughTheRealWriter() throws {
        prepareDisk(circleMode: .real)
        let state = AppState()
        let posted = try minaPosts(into: state)
        let key: String = BuddyPhotoCache.key(forRemotePath: posted.path)

        // Photos — §9-02's default, and what a save with no opinion means.
        XCTAssertEqual(state.settings.widgetPhotoStyle, .photos)
        let shown: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(shown.photoStyle, .photos)
        XCTAssertEqual(shown.circle.posts.first { $0.name == "Mina" }?.thumb, key)

        // Names only — applied by the WRITER, so the name is not in the bytes
        // at all rather than being in them and trusted not to be drawn.
        style(.namesAndTier, on: state)
        let names: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(names.photoStyle, .namesAndTier)
        XCTAssertNotNil(names.circle.posts.first { $0.name == "Mina" },
                        "the POST stays — she prayed, and the count must not lie")
        XCTAssertNil(names.circle.posts.first { $0.name == "Mina" }?.thumb)
        let raw: String = try XCTUnwrap(String(data: try Data(contentsOf: widgetURL),
                                               encoding: .utf8))
        XCTAssertFalse(raw.contains(key))
        XCTAssertFalse(raw.contains(posted.path))

        // Blurred — the RENDERER's, so the name comes back AND the setting
        // travels with it. A pre-blurred file on disk would be the widget-only
        // photo store §7 forbids.
        style(.blurred, on: state)
        let blurred: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(blurred.photoStyle, .blurred)
        XCTAssertEqual(blurred.circle.posts.first { $0.name == "Mina" }?.thumb, key)
    }

    /// Changing the setting has to REWRITE the file, and nothing else in the
    /// app was going to.
    ///
    /// `settings.didSet` only calls `refresh()` when the change moves the prayer
    /// windows, and this one does not — so without the publish beside it,
    /// somebody could turn photos off in Settings and watch their home screen
    /// keep showing faces until the next time a friend prayed.
    func testTurningPhotosOffRewritesTheFileImmediately() throws {
        prepareDisk(circleMode: .real)
        let state = AppState()
        try minaPosts(into: state)
        let before: WidgetSnapshot = try XCTUnwrap(published())

        // Nothing but the setting moves — no log, no pull, no clock.
        style(.namesAndTier, on: state)

        let after: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(after.photoStyle, .namesAndTier)
        XCTAssertEqual(after.circle.prayedCount, before.circle.prayedCount)
        XCTAssertEqual(after.circle.memberCount, before.circle.memberCount)
        XCTAssertFalse(before.hasSameContent(as: after),
                       "if the two files said the same thing this test proves nothing")
    }

    // MARK: - What the file names is what the app caches (§3, P3)

    /// The prefetch's list, taken off a real `AppState` and checked against the
    /// bytes that real `AppState` just wrote.
    ///
    /// This is the wiring half, and it is the half that breaks. The builder's
    /// own tests prove `orderedPosts` and `make` agree when handed the same
    /// arguments; nothing over there notices if `AppState` asks one of them for
    /// a different window, a different dayKey, or a photo set built without the
    /// report hide. What that failure looks like in production is a home screen
    /// naming four pictures the app never cached — four emoji where there
    /// should be faces, on somebody else's phone, with a fully green suite.
    ///
    /// The DOWNLOAD is deliberately not exercised: `prefetchWidgetPhotos` sits
    /// behind the same `circleSync` fence as every other outbound call in
    /// `AppState`, so a unit test reaches no network — which is why the list is
    /// a function of its own.
    func testTheAppCachesExactlyThePhotosTheFileNames() throws {
        prepareDisk(circleMode: .real)
        reporterToRestore = PhotoReports.shared.currentUserID
        PhotoReports.shared.currentUserID = { nil }

        let state = AppState()
        let posted = try minaPosts(into: state)

        let file: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(state.widgetPhotoPathsToCache(), [posted.path])
        XCTAssertEqual(file.circle.posts.compactMap { $0.thumb },
                       state.widgetPhotoPathsToCache()
                           .map { BuddyPhotoCache.key(forRemotePath: $0) },
                       "the file names a picture the app was never going to cache")

        // §7: a reported photo is not fetched either. Downloading it again
        // would put the bytes somebody just hid straight back on the disk the
        // extension reads.
        hidesToForget.append(posted.path)
        PhotoReports.shared.hide(RemotePost(id: UUID(), userID: UUID(), circleID: UUID(),
                                            dayKey: posted.window.dayKey,
                                            prayer: posted.window.prayer, tier: .onTime,
                                            loggedAt: file.writtenAt,
                                            photoPath: posted.path))
        XCTAssertEqual(state.widgetPhotoPathsToCache(), [])

        // ...and neither is anything, under "Names only": no network, no disk,
        // nothing cached for a tile that will not draw it.
        PhotoReports.shared.forgetHideForTesting(posted.path)
        XCTAssertEqual(state.widgetPhotoPathsToCache(), [posted.path])
        style(.namesAndTier, on: state)
        XCTAssertEqual(state.widgetPhotoPathsToCache(), [])
    }

    // MARK: - The dayKey the entries are fetched for

    /// After midnight the live window is YESTERDAY's isha (it ends at today's
    /// fajr), and `dayKey` means the schedule day, so the writer has to ask
    /// `gridEntries` for yesterday. Getting the window right and the entries
    /// wrong is a silent, plausible-looking failure: the tile says "Isha" over
    /// a circle where nobody has prayed.
    ///
    /// Which night is used is SEARCHED. A demo buddy's outcome is a pure
    /// function of (name, dayKey, prayer), so "somebody had prayed isha by
    /// 1 AM" is true on most nights and false on some, and a test that assumed
    /// tonight would fail on those nights only.
    func testAfterMidnightTheFileIsYesterdaysIshaAndYesterdaysEntries() throws {
        prepareDisk()
        let state = AppState()
        let calendar = Calendar.current

        var chosen: (now: Date, yesterday: String)?
        for dayOffset in 0..<14 {
            guard let midnight = calendar.date(byAdding: .day, value: dayOffset,
                                               to: calendar.startOfDay(for: Date())),
                  let oneAM = calendar.date(byAdding: .hour, value: 1, to: midnight) else {
                continue
            }
            travel(to: oneAM, state)
            // Stepped by the CALENDAR, exactly as `AppState.previousDayKey` is
            // — 86,400 seconds is a different day on a DST boundary.
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: AppClock.now) else {
                continue
            }
            let yesterday: String = AppClock.dayKey(for: dayBefore)
            let posted: Int = state.gridEntries(for: .isha, dayKey: yesterday).filter(prayed).count
            if posted > 0 {
                chosen = (oneAM, yesterday)
                break
            }
        }
        let night = try XCTUnwrap(chosen,
                                  "no night in a fortnight had an isha post standing at 1 AM")

        travel(to: night.now, state)
        state.publishWidgetSnapshot()
        let file: WidgetSnapshot = try XCTUnwrap(published())

        XCTAssertEqual(file.window?.prayer, .isha)
        XCTAssertEqual(file.window?.dayKey, night.yesterday)
        XCTAssertNotEqual(night.yesterday, state.todayKey)

        // What makes the count below load-bearing: TODAY's isha has not
        // happened at 1 AM, so a writer that passed the wrong dayKey would
        // report an empty circle rather than a differently-shaped one.
        let today: [GridEntry] = state.gridEntries(for: .isha, dayKey: state.todayKey)
        XCTAssertEqual(today.filter(prayed).count, 0)

        let yesterday: [GridEntry] = state.gridEntries(for: .isha, dayKey: night.yesterday)
        XCTAssertGreaterThan(file.circle.prayedCount, 0)
        XCTAssertEqual(file.circle.prayedCount, yesterday.filter(prayed).count)
        XCTAssertEqual(file.circle.memberCount, yesterday.count)
        XCTAssertEqual(file.circle.posts.count,
                       min(yesterday.filter(prayed).count, WidgetSnapshot.postCap))
        let expected: Set<String> = Set(yesterday.filter(prayed).map { $0.member.name })
        XCTAssertTrue(Set(file.circle.posts.map { $0.name }).isSubset(of: expected))

        // §3/§4: 1 AM is nobody's reminder hour, and the app refuses to nudge
        // in this block. So does the file.
        XCTAssertTrue(file.circle.waiting.isEmpty)
    }

    // MARK: - Nudges

    /// The two halves of `waiting[]` that only the writer can get wrong: the
    /// gate that decides whether anybody is in it, and `nudgesSent` reaching
    /// `nudgedThisWindow` — `sendNudge` is the ONLY path that moves that flag,
    /// and it never goes through `persist()`.
    func testTheNudgeGateAndTheNudgeItselfReachTheFile() throws {
        prepareDisk()
        let state = AppState()
        let calendar = Calendar.current
        let grace: TimeInterval = WidgetSnapshotBuilder.nudgeGrace

        // A window where somebody in the demo circle is still to pray half an
        // hour in — searched for the same reason as above.
        var slot: (window: PrayerWindow, dayKey: String, member: CircleMember)?
        search: for dayOffset in 0..<14 {
            guard let midnight = calendar.date(byAdding: .day, value: dayOffset,
                                               to: calendar.startOfDay(for: Date())),
                  let noon = calendar.date(byAdding: .hour, value: 12, to: midnight) else {
                continue
            }
            travel(to: noon, state)
            guard let schedule: DaySchedule = state.todaySchedule else { continue }
            for window in schedule.windows {
                let at: Date = window.start.addingTimeInterval(grace + 60)
                guard at < window.end else { continue }
                travel(to: at, state)
                let entries: [GridEntry] = state.gridEntries(for: window.prayer,
                                                             dayKey: state.todayKey)
                if let owing = entries.first(where: { !$0.member.isYou && $0.state == .waiting }) {
                    slot = (window, state.todayKey, owing.member)
                    break search
                }
            }
        }
        let found = try XCTUnwrap(slot,
                                  "no window in a fortnight left the demo circle owing a prayer")

        // Twenty minutes in, nobody is late and nobody is a nudge target —
        // v3.6's rule, which the Today screen has always applied and which the
        // home screen now applies to the same minute.
        travel(to: found.window.start.addingTimeInterval(20 * 60), state)
        let early: WidgetSnapshot = try XCTUnwrap(published())
        XCTAssertEqual(early.window?.prayer, found.window.prayer)
        XCTAssertTrue(early.circle.waiting.isEmpty,
                      "offered too soon: \(early.circle.waiting.map { $0.name })")

        // Half an hour in, they are.
        travel(to: found.window.start.addingTimeInterval(grace + 60), state)
        let live: WidgetSnapshot = try XCTUnwrap(published())
        let target = try XCTUnwrap(live.circle.waiting.first { $0.userID == found.member.id })
        XCTAssertFalse(target.nudgedThisWindow)

        state.sendNudge(to: found.member, prayer: found.window.prayer, dayKey: found.dayKey)

        let after: WidgetSnapshot = try XCTUnwrap(published())
        let nudged = try XCTUnwrap(after.circle.waiting.first { $0.userID == found.member.id })
        XCTAssertTrue(nudged.nudgedThisWindow,
                      "sendNudge is the only thing that moves this, and it moves it here")
        XCTAssertTrue(after.circle.waiting.filter { $0.userID != found.member.id }
                        .allSatisfy { !$0.nudgedThisWindow },
                      "one nudge, one person")
    }

    // MARK: - The unchanged-content memo

    /// The memo says what is ON DISK, so a write that failed must not earn it.
    ///
    /// The failure it guards is quiet and permanent: one throw (no space, or —
    /// as here — `widget.json` occupied by something that is not a file) and
    /// every later publish of the same content takes the unchanged early-out,
    /// leaving the home screen on the previous file with no way back short of
    /// the circle actually changing.
    func testAFailedWriteIsRetriedRatherThanRememberedAsDone() throws {
        prepareDisk()

        // Occupy the path with a directory, BEFORE the state's first publish,
        // so the very first write is the one that fails.
        let blocked: URL = widgetURL
        try? FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked) }

        let state = AppState()          // init → refresh → publish → throws
        state.publishWidgetSnapshot()
        XCTAssertNil(published(), "the rig has to actually block the write")

        // The path works again, and the content has not moved. A memo taken on
        // trust would call this publish redundant and skip it forever.
        try FileManager.default.removeItem(at: widgetURL)
        state.publishWidgetSnapshot()

        let recovered: WidgetSnapshot = try XCTUnwrap(published(),
                                                      "a failed write was memoised as done")
        XCTAssertEqual(recovered.mode, .demo)
    }
}
