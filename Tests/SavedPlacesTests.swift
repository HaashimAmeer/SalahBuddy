import CoreLocation
import XCTest
@testable import SalahBuddy

/// v4.1: the four `AppState` methods behind the Saved places sheet —
/// `renamePlace`, `reanchorPlace`, `setPlaceRadius`, `forgetPlace` (plus
/// `clearSavedPlaces`).
///
/// `AppState` is orchestration and is not unit-tested elsewhere, and that rule
/// is right for logging and streaks, which are `GameEngine`'s math wearing a
/// thin coat. It is wrong for these. Each one edits ONE element of a list of
/// look-alike structs, addressed by `id` — two masjids differ by a UUID and
/// nothing else — and each one is only saved because `settings.didSet` happens
/// to fire. "Renamed the other masjid" and "the radius was never written down"
/// are both silent, both permanent, and neither shows up on screen until
/// somebody's Home is at the wrong address again. So: named per method, and
/// every test asserts what did NOT change as well as what did.
///
/// **How an `AppState` is built here.** It has no injection points — `init()`
/// reads `Store` and `settings.didSet` writes it back — so the disk IS the
/// seam, and the tests use it as one deliberately: `makeState` lays down a
/// `settings.json`, and `reload()` reads back what a cold launch would get.
/// That makes the persistence assertions real rather than a restatement of the
/// in-memory value. The one thing disk cannot supply is a location fix, so
/// `LocationProvider` grew a DEBUG-only `simulateDeviceFix`.
@MainActor
final class SavedPlacesTests: XCTestCase {

    // MARK: - Rig

    /// A whole-second date, so an `.iso8601` round-trip is lossless and
    /// `savedAt` can be compared exactly.
    private let anchoredAt = Date(timeIntervalSince1970: 1_760_000_000)

    /// Two masjids and a home. Two of one tag is the entire v4.1 point: any
    /// implementation that finds a place by TAG instead of by `id` gets the
    /// wrong one, and these fixtures are shaped to catch exactly that.
    private func fixture() -> [SavedPlace] {
        [
            SavedPlace(tag: .masjid, name: "Masjid Al-Noor",
                       latitude: 47.6101, longitude: -122.3421,
                       radiusMeters: 400, savedAt: anchoredAt),
            SavedPlace(tag: .masjid, name: "Downtown musalla",
                       latitude: 47.6045, longitude: -122.3350,
                       savedAt: anchoredAt),
            SavedPlace(tag: .home, latitude: 47.6062, longitude: -122.3321,
                       savedAt: anchoredAt),
        ]
    }

    /// An `AppState` whose `settings.json` starts as `places`.
    ///
    /// Also snapshots the files and restores them afterwards: the test host is
    /// a real app with a real Documents directory, and a suite that leaves
    /// saved places lying around there is a suite that edits the next run's
    /// world. `profile.json` is snapshotted too — constructing an `AppState`
    /// runs `refresh()`, which can reconcile a streak and restamp the profile,
    /// and none of that should outlive the suite on a shared simulator.
    private func makeState(_ places: [SavedPlace]) -> AppState {
        for file in [Store.settingsFile, Store.profileFile] {
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
        settings.savedPlaces = places
        Store.save(settings, to: Store.settingsFile)
        return AppState()
    }

    /// What a cold launch would load. Every mutation below is checked against
    /// this as well as against memory — `settings.didSet` is the only thing
    /// persisting any of it, and a mutation that skips it looks perfect until
    /// the app is relaunched.
    private func reload() -> [SavedPlace] {
        Store.load(Store.settingsFile, default: AppSettings()).savedPlaces
    }

    /// Put a device fix on the shared provider (`AppState.location`), and take
    /// it away again when the test ends.
    private func simulateFix(_ latitude: Double, _ longitude: Double) {
        addTeardownBlock { LocationProvider.shared.simulateDeviceFix(nil) }
        LocationProvider.shared.simulateDeviceFix(
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private func noFix() {
        LocationProvider.shared.simulateDeviceFix(nil)
    }

    // MARK: - The rig itself

    func testAStateBuiltFromDiskSeesTheSavedPlaces() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        XCTAssertEqual(state.settings.savedPlaces.map(\.id), places.map(\.id),
                       "the rig has to survive its own round-trip, or nothing below means anything")
        XCTAssertEqual(state.settings.savedPlaces.map(\.displayName),
                       ["Masjid Al-Noor", "Downtown musalla", "Home"])
        // Both masjids survived the list shape — the pre-v4.1 dictionary could
        // only ever hold one, and every test below leans on there being two.
        XCTAssertEqual(state.savedPlaceTags.sorted { $0.rawValue < $1.rawValue },
                       [.home, .masjid])
    }

    // MARK: - renamePlace

    func testRenamingTouchesOnlyTheTargetedPlace() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.renamePlace(id: places[1].id, to: "Musalla on 3rd")

        XCTAssertEqual(state.settings.savedPlaces.map(\.displayName),
                       ["Masjid Al-Noor", "Musalla on 3rd", "Home"],
                       "the OTHER masjid must not have been renamed — same tag, different place")
        XCTAssertEqual(state.settings.savedPlaces.map(\.id), places.map(\.id),
                       "a rename reorders nothing and replaces no identity")
        XCTAssertEqual(reload().map(\.name), [places[0].name, "Musalla on 3rd", nil])
    }

    func testRenamingTrimsSurroundingWhitespace() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.renamePlace(id: places[2].id, to: "  Dad's place \n")

        XCTAssertEqual(state.settings.savedPlaces[2].name, "Dad's place")
        XCTAssertEqual(reload()[2].name, "Dad's place")
    }

    /// The sheet's `TextField` has the tag's name as its PLACEHOLDER, so
    /// emptying the field is a person saying "just call it Masjid". Storing
    /// `""` would satisfy that on screen for one render and then show a blank
    /// row everywhere `displayName` is used. It clears to nil instead.
    func testABlankNameFallsBackToTheTagsGenericName() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.renamePlace(id: places[0].id, to: "   \n ")

        XCTAssertNil(state.settings.savedPlaces[0].name,
                     "whitespace is not a name — it is a cleared field")
        XCTAssertEqual(state.settings.savedPlaces[0].displayName, PlaceTag.masjid.displayName)
        XCTAssertEqual(state.settings.savedPlaces[0].displayName, "Masjid")
        XCTAssertNil(reload()[0].name)
        // And the sibling masjid keeps its own name, which is now the only way
        // to tell the two rows apart.
        XCTAssertEqual(state.settings.savedPlaces[1].name, "Downtown musalla")
    }

    func testAnEmptyStringClearsANameJustLikeWhitespace() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        // Exactly what `PlaceCard.commitName` sends when the field is emptied
        // and focus moves away.
        state.renamePlace(id: places[0].id, to: "")

        XCTAssertNil(state.settings.savedPlaces[0].name)
        XCTAssertEqual(reload()[0].displayName, "Masjid")
    }

    /// "Masjid · praying here since Aug 12, 2026" is the one line on the card
    /// that says this is the SAME place you have been praying at for a year.
    /// A rename or a radius tap that restamped it would erase that silently —
    /// nothing else on the card changes, so nobody would ever notice.
    func testRenamingOrResizingLeavesTheAnchorAlone() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.renamePlace(id: places[0].id, to: "Al-Noor")
        state.setPlaceRadius(id: places[0].id, meters: 600)

        let edited: SavedPlace = state.settings.savedPlaces[0]
        XCTAssertEqual(edited.savedAt, anchoredAt,
                       "'praying here since' belongs to the ANCHOR — only re-anchoring may move it")
        XCTAssertEqual(edited.latitude, places[0].latitude)
        XCTAssertEqual(edited.longitude, places[0].longitude)
        XCTAssertEqual(edited.tag, .masjid)
        XCTAssertEqual(reload()[0].savedAt, anchoredAt)
    }

    func testRenamingAnUnknownPlaceChangesNothing() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.renamePlace(id: UUID(), to: "Nowhere")

        XCTAssertEqual(state.settings.savedPlaces.map(\.displayName),
                       ["Masjid Al-Noor", "Downtown musalla", "Home"])
        XCTAssertEqual(state.settings.savedPlaces.count, 3,
                       "an id that matches nothing appends nothing")
    }

    // MARK: - reanchorPlace

    /// The reason this screen exists at all: a Home anchored at a friend's
    /// house used to stay wrong forever.
    func testReanchoringMovesThePlaceToTheDeviceFix() throws {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.5480, -122.3110)
        let before: Date = AppClock.now

        XCTAssertTrue(state.reanchorPlace(id: places[2].id))

        let moved: SavedPlace = state.settings.savedPlaces[2]
        XCTAssertEqual(moved.latitude, 47.5480, accuracy: 0.000_001)
        XCTAssertEqual(moved.longitude, -122.3110, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(moved.savedAt), before,
                                    "'praying here since' is about the CURRENT anchor")
        // Identity and the settings you already tuned survive the move.
        XCTAssertEqual(moved.id, places[2].id)
        XCTAssertEqual(moved.tag, .home)
        XCTAssertNil(moved.name)
        XCTAssertEqual(moved.radiusMeters, SavedPlace.defaultRadiusMeters)
        // And nothing else moved.
        XCTAssertEqual(state.settings.savedPlaces[0].latitude, places[0].latitude)
        XCTAssertEqual(state.settings.savedPlaces[1].latitude, places[1].latitude)
        XCTAssertEqual(state.settings.savedPlaces[0].savedAt, anchoredAt)

        let persisted: SavedPlace = reload()[2]
        XCTAssertEqual(persisted.latitude, 47.5480, accuracy: 0.000_001)
        XCTAssertEqual(persisted.longitude, -122.3110, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(persisted.savedAt).timeIntervalSince1970,
                       try XCTUnwrap(moved.savedAt).timeIntervalSince1970,
                       accuracy: 1.0,
                       "iso8601 drops the fraction of a second, nothing more")
    }

    /// The behaviour, not the fields: the suggestion follows the place.
    func testAfterReanchoringTheSuggestionFollowsTheNewSpot() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        // Standing at the OLD home: suggested, as it always was.
        simulateFix(47.6062, -122.3321)
        XCTAssertEqual(state.suggestedPlaceTag(), .home)

        // Move house, and re-anchor from the new doorstep.
        simulateFix(47.5480, -122.3110)
        XCTAssertNil(state.suggestedPlace(), "the new address is not any saved place yet")
        XCTAssertTrue(state.reanchorPlace(id: places[2].id))
        XCTAssertEqual(state.suggestedPlace()?.id, places[2].id)

        // The old doorstep is somebody else's problem now.
        simulateFix(47.6062, -122.3321)
        XCTAssertNil(state.suggestedPlace(),
                     "re-anchoring MOVES a place; it does not add a second one")
        XCTAssertEqual(state.settings.savedPlaces.count, 3)
    }

    /// The home above is the only one of its tag, so moving it cannot tell an
    /// id-based implementation from a tag-based one. Two masjids can.
    func testReanchoringOneOfTwoMasjidsLeavesTheOtherWhereItIs() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.5480, -122.3110)

        XCTAssertTrue(state.reanchorPlace(id: places[1].id))

        XCTAssertEqual(state.settings.savedPlaces[1].latitude, 47.5480, accuracy: 0.000_001)
        XCTAssertEqual(state.settings.savedPlaces[0].latitude, places[0].latitude,
                       "a by-tag move takes whichever masjid comes first, and that is the wrong one")
        XCTAssertEqual(state.settings.savedPlaces[0].longitude, places[0].longitude)
        XCTAssertEqual(state.settings.savedPlaces[0].savedAt, anchoredAt)
        XCTAssertEqual(reload()[0].latitude, places[0].latitude)
    }

    func testReanchoringWithoutAFixFailsAndChangesNothing() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        noFix()

        XCTAssertFalse(state.reanchorPlace(id: places[2].id),
                       "false is what puts 'no location fix right now' on the card")

        XCTAssertEqual(state.settings.savedPlaces[2].latitude, places[2].latitude)
        XCTAssertEqual(state.settings.savedPlaces[2].longitude, places[2].longitude)
        XCTAssertEqual(state.settings.savedPlaces[2].savedAt, anchoredAt,
                       "a failed move must not restamp 'praying here since'")
    }

    func testReanchoringAnUnknownPlaceFailsEvenWithAFix() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.5480, -122.3110)

        XCTAssertFalse(state.reanchorPlace(id: UUID()))

        XCTAssertEqual(state.settings.savedPlaces.map(\.latitude), places.map(\.latitude),
                       "no place matched, so no place moved")
    }

    // MARK: - setPlaceRadius

    func testSettingTheRadiusAffectsOnlyThatPlace() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        // "Campus", the widest of the sheet's three presets.
        state.setPlaceRadius(id: places[1].id, meters: 1_500)

        XCTAssertEqual(state.settings.savedPlaces.map(\.radiusMeters),
                       [400, 1_500, SavedPlace.defaultRadiusMeters],
                       "the sibling masjid keeps the radius it was tuned to")
        XCTAssertEqual(reload().map(\.radiusMeters),
                       [400, 1_500, SavedPlace.defaultRadiusMeters],
                       "a radius that is not written down is a radius that resets on relaunch")
    }

    func testTheRadiusIsClampedToSomethingAPersonCouldMean() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.setPlaceRadius(id: places[0].id, meters: 5)
        XCTAssertEqual(state.settings.savedPlaces[0].radiusMeters, 50,
                       "below ~50 m a GPS fix cannot tell you are there at all")

        state.setPlaceRadius(id: places[0].id, meters: 250_000)
        XCTAssertEqual(state.settings.savedPlaces[0].radiusMeters, 5_000,
                       "a 'place' the size of a county would tag every prayer in the city")

        state.setPlaceRadius(id: places[0].id, meters: -1)
        XCTAssertEqual(state.settings.savedPlaces[0].radiusMeters, 50)

        XCTAssertEqual(reload()[0].radiusMeters, 50)
    }

    func testEachOfTheSheetsPresetsSurvivesUnchanged() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        // House / Building / Campus, as `PlaceCard.radiusOptions` sends them.
        for preset in [250.0, 600.0, 1_500.0] {
            state.setPlaceRadius(id: places[0].id, meters: preset)
            XCTAssertEqual(state.settings.savedPlaces[0].radiusMeters, preset,
                           "a preset inside the clamp must pass through exactly")
            XCTAssertEqual(reload()[0].radiusMeters, preset)
        }
    }

    /// A wider radius is not decoration — it is what "you are here" means.
    func testWideningTheRadiusWidensWhatCountsAsBeingThere() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        // ~350 m north of home: outside the default 250 m.
        simulateFix(47.6062 + (350.0 / 111_320.0), -122.3321)
        XCTAssertNil(state.suggestedPlace())

        state.setPlaceRadius(id: places[2].id, meters: 600)

        XCTAssertEqual(state.suggestedPlace()?.id, places[2].id)
    }

    func testSettingTheRadiusOfAnUnknownPlaceChangesNothing() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.setPlaceRadius(id: UUID(), meters: 1_500)

        XCTAssertEqual(state.settings.savedPlaces.map(\.radiusMeters),
                       [400, SavedPlace.defaultRadiusMeters, SavedPlace.defaultRadiusMeters])
    }

    // MARK: - forgetPlace

    func testForgettingRemovesExactlyTheTargetedPlace() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        // The FIRST of two masjids: a by-tag implementation takes both, and an
        // index-based one takes whichever row happened to be at that offset.
        state.forgetPlace(id: places[0].id)

        XCTAssertEqual(state.settings.savedPlaces.map(\.id), [places[1].id, places[2].id])
        XCTAssertEqual(state.settings.savedPlaces.map(\.displayName),
                       ["Downtown musalla", "Home"])
        XCTAssertEqual(reload().map(\.id), [places[1].id, places[2].id])
        // The tag itself is not forgotten — the other masjid still carries it.
        XCTAssertTrue(state.savedPlaceTags.contains(.masjid))
    }

    func testForgettingTheLastPlaceOfATagDropsTheTag() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.forgetPlace(id: places[0].id)
        state.forgetPlace(id: places[1].id)

        XCTAssertEqual(state.settings.savedPlaces.map(\.id), [places[2].id])
        XCTAssertFalse(state.savedPlaceTags.contains(.masjid))
        XCTAssertEqual(reload().count, 1)
    }

    func testForgettingSomethingAlreadyGoneRemovesNothingElse() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)

        state.forgetPlace(id: places[0].id)
        state.forgetPlace(id: places[0].id)   // the card is gone; a stale tap is not fatal
        state.forgetPlace(id: UUID())

        XCTAssertEqual(state.settings.savedPlaces.map(\.id), [places[1].id, places[2].id])
        XCTAssertEqual(reload().count, 2)
    }

    func testAForgottenPlaceStopsBeingSuggested() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.6062, -122.3321)
        XCTAssertEqual(state.suggestedPlaceTag(), .home)

        state.forgetPlace(id: places[2].id)

        XCTAssertNil(state.suggestedPlace(), "forgetting is what stops the suggestion")
    }

    // MARK: - clearSavedPlaces

    func testForgetAllEmptiesTheListAndSaysSo() {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.6062, -122.3321)

        state.clearSavedPlaces()

        XCTAssertTrue(state.settings.savedPlaces.isEmpty)
        XCTAssertTrue(state.savedPlaceTags.isEmpty)
        XCTAssertNil(state.suggestedPlaceTag(),
                     "no places means no suggestions — which is what the confirmation warns about")
        XCTAssertTrue(reload().isEmpty, "and it stays empty across a relaunch")
    }

    // MARK: - Persistence, end to end

    /// The disk assertions above read `settings.json` directly. This one goes
    /// the whole way round — a SECOND `AppState`, built from nothing but the
    /// file the first one left — because that is the path a relaunch takes,
    /// tolerant decoder and all.
    func testEveryEditSurvivesAColdLaunch() throws {
        let places: [SavedPlace] = fixture()
        let state: AppState = makeState(places)
        simulateFix(47.5480, -122.3110)
        let before: Date = AppClock.now

        state.renamePlace(id: places[0].id, to: "Al-Noor")
        state.setPlaceRadius(id: places[0].id, meters: 600)
        XCTAssertTrue(state.reanchorPlace(id: places[1].id))
        state.forgetPlace(id: places[2].id)

        let relaunched = AppState()
        let restored: [SavedPlace] = relaunched.settings.savedPlaces

        XCTAssertEqual(restored.count, 2, "the home was forgotten, the masjids were not")
        XCTAssertEqual(restored.map(\.id), [places[0].id, places[1].id],
                       "ids are what a rename and a re-anchor address next time")
        XCTAssertEqual(restored[0].name, "Al-Noor")
        XCTAssertEqual(restored[0].radiusMeters, 600)
        XCTAssertEqual(restored[0].latitude, places[0].latitude, accuracy: 0.000_001,
                       "only the SECOND masjid was re-anchored")
        XCTAssertEqual(restored[1].latitude, 47.5480, accuracy: 0.000_001)
        XCTAssertEqual(restored[1].longitude, -122.3110, accuracy: 0.000_001)
        // Compared against the clock rather than against `anchoredAt`, so this
        // says "the re-anchor restamped it" without also depending on where a
        // time-travelled `AppClock` happens to be standing.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored[1].savedAt),
                                    before.addingTimeInterval(-1),
                                    "iso8601 truncates to the second, and nothing else moved this")
        XCTAssertEqual(restored[1].name, "Downtown musalla")
    }

    /// Editing a place must not re-run Adhan. `settings.didSet` only calls
    /// `refresh()` when `affectsSchedule` says the windows moved, and that
    /// whitelist is the reason a radius tap is not a stutter — 770a4a8 landed
    /// it for exactly this kind of write.
    func testEditingAPlaceIsNotASchedulingChange() {
        var before = AppSettings()
        before.savedPlaces = fixture()
        var after = before
        after.savedPlaces[0].name = "Al-Noor"
        after.savedPlaces[0].radiusMeters = 600
        after.savedPlaces.removeLast()

        XCTAssertFalse(after.affectsSchedule(comparedTo: before),
                       "saved places have nothing to do with when a prayer window opens")
    }
}
