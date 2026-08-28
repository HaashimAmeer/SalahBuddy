import XCTest
@testable import SalahBuddy

/// v4.1: `AppState.postOutlook` — the one seam the camera confirm screen asks
/// what a tap on Post will actually do.
///
/// `AppState` is orchestration and mostly isn't unit-tested, which is the right
/// rule for logging and streaks (`GameEngine`'s math wearing a thin coat). It
/// is the wrong rule here. This function exists ONLY so a screen can promise
/// things, and every answer it gives becomes a sentence somebody reads:
/// "+30 XP", "saves as a make-up (+10 XP)", "there's nothing left here to save
/// it to". A wrong answer is not a wrong pixel — it is a false confirmation
/// that a prayer was recorded, and the bug this was written for looked perfect
/// on screen while writing nothing at all to disk.
///
/// **The rig.** `AppState` has no injection points — `init()` reads `Store` and
/// runs `refresh()` — so the disk is the seam, exactly as `SavedPlacesTests`
/// uses it. `makeState` lays down a settings file with FIXED coordinates (so
/// Adhan is deterministic and no stray device fix can move the windows) plus
/// whatever logs the test needs, and restores all three files afterwards.
///
/// **No time travel.** Every question here is asked with an explicit `at:`, and
/// the instants come out of the schedule the state just computed — so these
/// assertions hold whatever the wall clock says when the suite runs.
///
/// **Known tradeoff** (inherited, and the one `SavedPlacesTests` already
/// accepts): the seam is the test host's real Documents directory. A hard crash
/// mid-test skips `addTeardownBlock` and leaves the fixture as that simulator's
/// live state.
@MainActor
final class PostOutlookTests: XCTestCase {

    // MARK: - Rig

    /// The schedule day the fixtures belong to. `DaySchedule.dayKey` is
    /// `AppClock.dayKey` of the day containing `AppClock.now`, so this is the
    /// same string the state will derive — computed here because a seeded log
    /// has to be on disk BEFORE the state is built.
    private var todayKey: String { AppClock.dayKey(for: AppClock.now) }

    /// An already-logged prayer, in the shape a v3 save has: no zone recorded,
    /// which `GameEngine.loggedInstance` matches from anywhere.
    private func logged(_ prayer: Prayer) -> PrayerLog {
        PrayerLog(id: UUID(), prayer: prayer, dayKey: todayKey,
                  loggedAt: Date(timeIntervalSince1970: 0), tier: .prayed, xp: LogTier.prayed.xp,
                  utcOffset: nil)
    }

    /// An `AppState` on fixed coordinates holding exactly `logs`.
    private func makeState(logs: [PrayerLog] = []) -> AppState {
        for file in [Store.settingsFile, Store.profileFile, Store.logsFile] {
            let url: URL = Store.url(for: file)
            let original: Data? = try? Data(contentsOf: url)
            addTeardownBlock {
                if let original {
                    try? original.write(to: url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        var settings = AppSettings()
        // Fixed, not the device: a location fix left behind by another suite
        // would move every window in here.
        settings.useDeviceLocation = false
        settings.fixedLatitude = 47.6062
        settings.fixedLongitude = -122.3321
        Store.save(settings, to: Store.settingsFile)
        Store.save(logs, to: Store.logsFile)

        return AppState()
    }

    private func window(_ state: AppState, _ prayer: Prayer,
                        file: StaticString = #filePath, line: UInt = #line) throws -> PrayerWindow {
        try XCTUnwrap(state.todaySchedule?.window(for: prayer),
                      "the rig needs a schedule, or nothing below means anything",
                      file: file, line: line)
    }

    func testTheRigHasAScheduleAndTheLogsItWasGiven() throws {
        let state: AppState = makeState()
        XCTAssertEqual(state.todaySchedule?.dayKey, todayKey)
        XCTAssertTrue(state.logs.isEmpty, "a leftover log would refuse the taps asked about below")

        let seeded: AppState = makeState(logs: [logged(.asr)])
        XCTAssertEqual(seeded.logs.map(\.prayer), [.asr])
    }

    // MARK: - An ordinary window: the make-up promise is true

    /// One second before the end the tap still earns in-window XP; AT the end
    /// it books a make-up. That pair of answers is what the countdown card is
    /// built on, and they flip at `GameEngine.tier`'s boundary to the second,
    /// because the card is a promise about the very next tap.
    func testAnOrdinaryWindowBooksAMakeUpOnceItCloses() throws {
        let state: AppState = makeState()
        let dhuhr = try window(state, .dhuhr)

        let before = try XCTUnwrap(state.postOutlook(prayer: .dhuhr,
                                                     at: dhuhr.end.addingTimeInterval(-1)))
        XCTAssertTrue(before.tier.isInWindow, "a second early still keeps the XP")
        XCTAssertEqual(before.prayers, [.dhuhr])

        let after = try XCTUnwrap(state.postOutlook(prayer: .dhuhr, at: dhuhr.end))
        XCTAssertEqual(after.tier, .qada, "past the end the log lands as a make-up — it still lands")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.makeUpXP, LogTier.qada.xp, "what the closing card may promise")
        XCTAssertEqual(after.name, "Dhuhr")
    }

    /// A prayer already logged is a refusal too — `log` no-ops on a double-log,
    /// and a screen offering XP for that tap is offering nothing.
    func testAnAlreadyLoggedPrayerWritesNothing() throws {
        let state: AppState = makeState(logs: [logged(.dhuhr)])
        let dhuhr = try window(state, .dhuhr)

        XCTAssertNil(state.postOutlook(prayer: .dhuhr, at: dhuhr.start))
    }

    // MARK: - The pre-fajr isha block: there is no make-up to promise

    /// THE BUG THE CARD MUST NOT REPEAT. Before fajr the Today block is
    /// YESTERDAY's isha and its deadline is today's fajr — but a tap at that
    /// deadline is not a make-up, it is a REFUSAL. `targetWindow` stops
    /// answering with yesterday's still-open isha at exactly `fajr.start` and
    /// falls through to TONIGHT's isha, which has not opened, so `log` appends
    /// nothing: no log, no XP, no photo. A card reading "+5 XP, it still
    /// counts" over that is a false confirmation of a save, on the one screen
    /// this whole feature exists to make honest.
    ///
    /// `nil` is how `postOutlook` says so, and it is the entire reason the card
    /// asks instead of assuming.
    func testAPreFajrIshaTapIsRefusedTheInstantFajrArrives() throws {
        let state: AppState = makeState()
        let fajr = try window(state, .fajr)

        // A second before the deadline the block is genuinely live: yesterday's
        // isha is still open and the countdown on screen is telling the truth.
        let before = try XCTUnwrap(state.postOutlook(prayer: .isha,
                                                     at: fajr.start.addingTimeInterval(-1)),
                                   "yesterday's isha is still open one second before fajr")
        XCTAssertTrue(before.tier.isInWindow)
        XCTAssertEqual(before.name, "Isha")

        // At the deadline, and after it, the tap writes NOTHING.
        XCTAssertNil(state.postOutlook(prayer: .isha, at: fajr.start),
                     "tonight's isha hasn't opened — there is no make-up to promise here")
        XCTAssertNil(state.postOutlook(prayer: .isha, at: fajr.start.addingTimeInterval(60)))
    }

    /// The other half of `nil`, and the reason the screen can treat them alike:
    /// a window that has not opened yet writes nothing either. Both mean the
    /// same thing to a card and to the Post button — do not promise a save.
    func testAWindowThatHasNotOpenedYetAlsoWritesNothing() throws {
        let state: AppState = makeState()
        let fajr = try window(state, .fajr)

        XCTAssertNil(state.postOutlook(prayer: .fajr, at: fajr.start.addingTimeInterval(-1)))
        XCTAssertNotNil(state.postOutlook(prayer: .fajr, at: fajr.start),
                        "at the open it is loggable, and on time")
    }

    // MARK: - Travel pairs: one tap, two logs, ONE window

    /// v3.3 travel: the pair is judged against the COMBINED window, exactly as
    /// `logCombined` judges it. Asked at the LEAD prayer's own end — the moment
    /// the XP line used to vanish, priced off Dhuhr's window while the countdown
    /// beside it ran on the pair's — the tap is still very much in-window and
    /// still pays.
    func testATravelPairIsPricedOnThePairsWindowNotTheLeads() throws {
        let state: AppState = makeState()
        let dhuhr = try window(state, .dhuhr)
        let asr = try window(state, .asr)

        let atLeadsEnd = try XCTUnwrap(state.postOutlook(prayer: .dhuhr, combinedLead: .dhuhr,
                                                         at: dhuhr.end))
        XCTAssertTrue(atLeadsEnd.tier.isInWindow,
                      "the pair runs to Asr's end — Dhuhr's end is the middle of it")
        XCTAssertEqual(atLeadsEnd.prayers, [.dhuhr, .asr])
        XCTAssertEqual(atLeadsEnd.name, "Dhuhr + Asr")
        XCTAssertEqual(atLeadsEnd.xp(jamaat: false),
                       2 * GameEngine.prayerXP(tier: atLeadsEnd.tier, jamaat: false),
                       "one tap writes two logs, and the line names what the tap earns")

        // The single-prayer answer at the same instant is a make-up — precisely
        // the disagreement a pair-aware seam removes.
        XCTAssertEqual(state.postOutlook(prayer: .dhuhr, at: dhuhr.end)?.tier, .qada)

        // And at the pair's real deadline: two make-ups from one tap, worth 10.
        let lapsed = try XCTUnwrap(state.postOutlook(prayer: .dhuhr, combinedLead: .dhuhr,
                                                     at: asr.end))
        XCTAssertEqual(lapsed.tier, .qada)
        XCTAssertEqual(lapsed.count, 2)
        XCTAssertEqual(lapsed.makeUpXP, 2 * LogTier.qada.xp,
                       "the closing card used to say 5 for this tap while the after-screen said 10")
    }

    /// `logCombined` writes only the halves that are not logged yet, so the
    /// screen has to price and name THAT — not a pair, and not nothing.
    func testAPairWithOneHalfAlreadyLoggedDescribesTheHalfItWillWrite() throws {
        let state: AppState = makeState(logs: [logged(.asr)])
        let dhuhr = try window(state, .dhuhr)

        let outlook = try XCTUnwrap(state.postOutlook(prayer: .dhuhr, combinedLead: .dhuhr,
                                                      at: dhuhr.end))
        XCTAssertEqual(outlook.prayers, [.dhuhr], "Asr is already down — this tap writes one log")
        XCTAssertEqual(outlook.name, "Dhuhr")
        XCTAssertEqual(outlook.makeUpXP, LogTier.qada.xp, "one make-up, not two")
    }

    /// Both halves already logged: `logCombined` appends nothing and returns,
    /// so the outlook is a refusal like any other.
    func testAPairWithBothHalvesLoggedWritesNothing() throws {
        let state: AppState = makeState(logs: [logged(.dhuhr), logged(.asr)])
        let dhuhr = try window(state, .dhuhr)

        XCTAssertNil(state.postOutlook(prayer: .dhuhr, combinedLead: .dhuhr, at: dhuhr.end))
    }
}
