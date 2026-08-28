import Foundation
import XCTest
@testable import SalahBuddy

/// v5 §2 — the shared container: where `Store` decides its files live, and the
/// one-time move that gets the v4 data there.
///
/// This is the riskiest edit of the cycle and it is also the one that is
/// hardest to watch happen: it runs once, on the first launch of an update, on
/// a phone that already has a year of somebody's prayers on it. It is not
/// re-runnable in the real world and there is no second chance at it. So every
/// rule it depends on is a function that takes plain values or plain
/// directories, and every one of them is exercised here against a temp
/// directory rather than against the app's real container.
///
/// What the tests below actually protect:
///
/// - **the fallback** — a build with no App Group entitlement must land on
///   Documents, not on nothing;
/// - **idempotency** — the migration runs on EVERY launch until it succeeds
///   completely, so the second run must copy nothing;
/// - **newer-file protection** — a file already in the container is never
///   overwritten by an older one in Documents;
/// - **partial-copy safety** — a run that died half-way finishes next time
///   without touching what already landed;
/// - **modification dates survive** — `BuddyPhotoCache` ages photos by file
///   date and sweeps at 30 days to match the server (SPEC-V5 §7). Restamping
///   them on the way across would give every cached photo another month.
final class SharedContainerTests: XCTestCase {

    // MARK: - Rig

    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v5-container-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Documents", isDirectory: true)
        destination = root.appendingPathComponent("AppGroup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let scratch: URL = root
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A whole-second date so a modification-date comparison is exact rather
    /// than filesystem-precision-dependent.
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    @discardableResult
    private func write(_ contents: String, to directory: URL, named name: String,
                       modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url: URL = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    private func read(_ directory: URL, _ name: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func modificationDate(_ directory: URL, _ name: String) throws -> Date {
        let path: String = directory.appendingPathComponent(name).path
        let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(
            atPath: path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// A `UserDefaults` of this test's own, so the marker under test is never
    /// the simulator's real one.
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "v5-container-tests-\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Where the data lives

    func testTheGroupContainerWinsWhenThereIsOne() {
        let group = URL(fileURLWithPath: "/group", isDirectory: true)
        let documents = URL(fileURLWithPath: "/documents", isDirectory: true)
        XCTAssertEqual(SharedContainer.resolveDirectory(group: group, fallback: documents), group)
    }

    /// The branch that keeps `make test`, Xcode Cloud and a mis-provisioned
    /// build alive. Nil is a normal answer, not a failure.
    func testNoContainerFallsBackToDocuments() {
        let documents = URL(fileURLWithPath: "/documents", isDirectory: true)
        XCTAssertEqual(SharedContainer.resolveDirectory(group: nil, fallback: documents), documents)
    }

    /// `Store` has to actually be usable wherever it landed — the seam change
    /// is worth nothing if the directory it picked cannot be written to.
    func testStoreWritesAndReadsWhereverItLanded() throws {
        XCTAssertEqual(Store.url(for: "probe.json").deletingLastPathComponent().path,
                       Store.directory.path,
                       "every file path in the app derives from this one property")

        let probe: URL = Store.url(for: "v5-probe-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: probe) }
        try Data("{}".utf8).write(to: probe, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: probe), Data("{}".utf8))
    }

    // MARK: - shouldCopy (pure)

    func testAMissingDestinationIsAlwaysCopied() {
        XCTAssertTrue(ContainerMigration.shouldCopy(source: epoch, destination: nil,
                                                    destinationExists: false))
        XCTAssertTrue(ContainerMigration.shouldCopy(source: nil, destination: nil,
                                                    destinationExists: false),
                      "an unreadable date is no reason to leave the data behind")
    }

    func testAStrictlyNewerSourceWins() {
        XCTAssertTrue(ContainerMigration.shouldCopy(source: epoch.addingTimeInterval(60),
                                                    destination: epoch,
                                                    destinationExists: true))
    }

    /// The rule the migration exists to not break.
    func testANewerDestinationIsNeverOverwritten() {
        XCTAssertFalse(ContainerMigration.shouldCopy(source: epoch,
                                                     destination: epoch.addingTimeInterval(60),
                                                     destinationExists: true))
    }

    /// Equal dates are what a completed copy leaves behind, which is what makes
    /// the second run a no-op.
    func testAnIdenticalDateIsNotNewerEnough() {
        XCTAssertFalse(ContainerMigration.shouldCopy(source: epoch, destination: epoch,
                                                     destinationExists: true))
    }

    /// A modification date survives a `timespec` and a `Double` on the way
    /// through the filesystem, so "the same instant" is only ever the same to
    /// within a rounding error. A nanosecond of that is not a newer file — and
    /// treating it as one would re-copy the whole photo library every launch.
    func testASplitSecondOfClockWobbleIsNotANewerFile() {
        XCTAssertFalse(ContainerMigration.shouldCopy(source: epoch.addingTimeInterval(0.000_001),
                                                     destination: epoch,
                                                     destinationExists: true))
        XCTAssertFalse(ContainerMigration.shouldCopy(source: epoch.addingTimeInterval(0.9),
                                                     destination: epoch,
                                                     destinationExists: true))
    }

    /// "No date" and "no file" are different facts. Collapsing them would make
    /// an existing file with an unreadable date look absent — i.e. overwrite it.
    func testAnUnknownDateOverSomethingPresentIsRefused() {
        XCTAssertFalse(ContainerMigration.shouldCopy(source: nil, destination: epoch,
                                                     destinationExists: true))
        XCTAssertFalse(ContainerMigration.shouldCopy(source: epoch, destination: nil,
                                                     destinationExists: true))
    }

    // MARK: - The move

    func testEverythingDocumentsHeldArrivesInTheContainer() throws {
        try write("{\"name\":\"Haashim\"}", to: source, named: Store.profileFile)
        try write("[]", to: source, named: Store.logsFile)
        try write("{}", to: source, named: Store.settingsFile)
        try write("{}", to: source, named: Store.circleFile)
        try write("[]", to: source, named: Store.outboxFile)
        let photos: URL = source.appendingPathComponent(PhotoStore.directoryName,
                                                        isDirectory: true)
        let circlePhotos: URL = source.appendingPathComponent(BuddyPhotoCache.directoryName,
                                                              isDirectory: true)
        try write("jpeg-a", to: photos, named: "2026-08-01_fajr_aaaa.jpg")
        try write("jpeg-b", to: photos, named: "2026-08-02_asr_bbbb.jpg")
        try write("cached", to: circlePhotos, named: "deadbeef.jpg")

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 8, skipped: 0, failed: 0))
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(read(destination, Store.profileFile), "{\"name\":\"Haashim\"}")
        XCTAssertEqual(read(destination.appendingPathComponent(PhotoStore.directoryName),
                            "2026-08-02_asr_bbbb.jpg"), "jpeg-b")
        XCTAssertEqual(read(destination.appendingPathComponent(BuddyPhotoCache.directoryName),
                            "deadbeef.jpg"), "cached")
    }

    /// The source is left alone on purpose. A migration that deletes as it goes
    /// has no way back if the container later turns out to be unavailable — the
    /// app would fall back to Documents and find them empty.
    func testTheOriginalsAreLeftWhereTheyWere() throws {
        try write("{}", to: source, named: Store.settingsFile)

        ContainerMigration.migrate(from: source, to: destination)

        XCTAssertEqual(read(source, Store.settingsFile), "{}",
                       "a copy, not a move — the fallback still needs something to read")
    }

    /// Run twice: the second run must copy nothing at all.
    func testASecondRunIsANoOp() throws {
        try write("{}", to: source, named: Store.settingsFile)
        try write("jpeg", to: source.appendingPathComponent(PhotoStore.directoryName),
                  named: "a.jpg")

        let first: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                         to: destination)
        let second: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(first, ContainerMigration.Report(copied: 2, skipped: 0, failed: 0))
        XCTAssertEqual(second, ContainerMigration.Report(copied: 0, skipped: 2, failed: 0),
                       "the copy carries the source's date over, so nothing is newer any more")
    }

    /// The app has been running out of the container for a week. Documents
    /// still holds the frozen v4 copy. Nothing may travel.
    func testAWeekOldDocumentsCopyCannotOverwriteLiveContainerData() throws {
        try write("{\"xp\":100}", to: source, named: Store.profileFile, modified: epoch)
        try write("{\"xp\":4200}", to: destination, named: Store.profileFile,
                  modified: epoch.addingTimeInterval(7 * 24 * 60 * 60))

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 0, skipped: 1, failed: 0))
        XCTAssertEqual(read(destination, Store.profileFile), "{\"xp\":4200}",
                       "a week of prayers is not overwritten by the snapshot they started from")
    }

    /// The other direction, which is the self-healing one: a build that fell
    /// back to Documents and was used there is now the newer copy.
    func testANewerDocumentsCopyDoesTravel() throws {
        try write("{\"xp\":100}", to: destination, named: Store.profileFile, modified: epoch)
        try write("{\"xp\":4200}", to: source, named: Store.profileFile,
                  modified: epoch.addingTimeInterval(60))

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 1, skipped: 0, failed: 0))
        XCTAssertEqual(read(destination, Store.profileFile), "{\"xp\":4200}")
    }

    /// A run killed half-way: one photo landed, the rest did not. Nothing that
    /// already arrived is re-copied, and everything owed is finished.
    func testAPartialCopyIsFinishedWithoutRedoingWhatLanded() throws {
        let photos: URL = source.appendingPathComponent(PhotoStore.directoryName,
                                                        isDirectory: true)
        try write("{}", to: source, named: Store.settingsFile)
        try write("jpeg-a", to: photos, named: "a.jpg", modified: epoch)
        try write("jpeg-b", to: photos, named: "b.jpg", modified: epoch)
        // What the interrupted run had already written.
        try write("jpeg-a", to: destination.appendingPathComponent(PhotoStore.directoryName),
                  named: "a.jpg", modified: epoch)

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 2, skipped: 1, failed: 0))
        XCTAssertEqual(read(destination.appendingPathComponent(PhotoStore.directoryName),
                            "b.jpg"), "jpeg-b")
    }

    /// SPEC-V5 §7: the widget reads the same cache, swept on the same 30-day
    /// clock as the server's retention. That clock is the file's modification
    /// date, and an atomic write stamps "now" unless something puts it back.
    func testCachedBuddyPhotosKeepTheirAgeAcrossTheMove() throws {
        let cache: URL = source.appendingPathComponent(BuddyPhotoCache.directoryName,
                                                       isDirectory: true)
        let downloadedAt: Date = epoch.addingTimeInterval(-25 * 24 * 60 * 60)
        try write("bytes", to: cache, named: "deadbeef.jpg", modified: downloadedAt)

        ContainerMigration.migrate(from: source, to: destination)

        let moved: Date = try modificationDate(
            destination.appendingPathComponent(BuddyPhotoCache.directoryName), "deadbeef.jpg")
        XCTAssertEqual(moved.timeIntervalSince1970, downloadedAt.timeIntervalSince1970,
                       accuracy: 1.0,
                       "age is measured from the DOWNLOAD; a restamp buys 30 more days")

        // And the sweep still agrees with that date afterwards.
        let entries: [BuddyPhotoCache.Entry] = BuddyPhotoCache.entries(
            in: destination.appendingPathComponent(BuddyPhotoCache.directoryName))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(BuddyPhotoCache.victims(among: entries,
                                               now: downloadedAt.addingTimeInterval(31 * 24 * 60 * 60)),
                       ["deadbeef.jpg"])
    }

    /// Only `.json` at the top level, and only files. A stray directory in
    /// Documents is not data this app owns.
    func testOnlyJSONFilesAndTheTwoPhotoDirectoriesTravel() throws {
        try write("{}", to: source, named: Store.settingsFile)
        try write("scratch", to: source, named: "notes.txt")
        try write("nested", to: source.appendingPathComponent("Inbox", isDirectory: true),
                  named: "thing.json")

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 1, skipped: 0, failed: 0))
        XCTAssertNil(read(destination, "notes.txt"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Inbox").path))
    }

    func testAnEmptyDocumentsDirectoryIsNotAFailure() {
        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                          to: destination)
        XCTAssertEqual(report, ContainerMigration.Report())
        XCTAssertTrue(report.isComplete)
    }

    func testAMissingSourceIsNotAFailure() {
        let absent: URL = root.appendingPathComponent("gone", isDirectory: true)
        let report: ContainerMigration.Report = ContainerMigration.migrate(from: absent,
                                                                          to: destination)
        XCTAssertEqual(report, ContainerMigration.Report())
    }

    /// The fallback build hands the same directory in twice — and the two URLs
    /// will not necessarily arrive spelled the same way.
    func testOneDirectoryIsRecognisedThroughEverySpelling() {
        XCTAssertTrue(ContainerMigration.sameDirectory(source, source))
        XCTAssertTrue(ContainerMigration.sameDirectory(source, source.appendingPathComponent(".")),
                      "a `.` component is the same directory")
        XCTAssertTrue(ContainerMigration.sameDirectory(source,
                                                       URL(fileURLWithPath: source.path)),
                      "a trailing slash is not a different directory")
        XCTAssertFalse(ContainerMigration.sameDirectory(source, destination))
    }

    func testMigratingADirectoryOntoItselfDoesNothing() throws {
        try write("{}", to: source, named: Store.settingsFile)

        let report: ContainerMigration.Report = ContainerMigration.migrate(
            from: source, to: URL(fileURLWithPath: source.path))

        XCTAssertEqual(report, ContainerMigration.Report())
        XCTAssertEqual(read(source, Store.settingsFile), "{}")
    }

    // MARK: - prepareOnLaunch (the marker)

    func testTheFirstLaunchMovesTheDataAndRemembersIt() throws {
        let defaults: UserDefaults = try scratchDefaults()
        try write("{}", to: source, named: Store.settingsFile)

        let report: ContainerMigration.Report = SharedContainer.prepareOnLaunch(
            from: source, to: destination, defaults: defaults)

        XCTAssertEqual(report, ContainerMigration.Report(copied: 1, skipped: 0, failed: 0))
        XCTAssertTrue(defaults.bool(forKey: SharedContainer.migrationDoneKey))
        XCTAssertEqual(read(destination, Store.settingsFile), "{}")
    }

    /// The marker is what makes launch two cost one `UserDefaults` read instead
    /// of a walk of the whole photo library.
    func testASecondLaunchDoesNotLookAtTheFilesAtAll() throws {
        let defaults: UserDefaults = try scratchDefaults()
        try write("{}", to: source, named: Store.settingsFile)
        SharedContainer.prepareOnLaunch(from: source, to: destination, defaults: defaults)

        // Something the second run would certainly copy, if it ran.
        try write("{\"new\":true}", to: source, named: Store.profileFile)
        let report: ContainerMigration.Report = SharedContainer.prepareOnLaunch(
            from: source, to: destination, defaults: defaults)

        XCTAssertEqual(report, ContainerMigration.Report())
        XCTAssertNil(read(destination, Store.profileFile))
    }

    /// The trap this guard exists for: a build with no container would
    /// otherwise record a migration it never performed, and the NEXT launch —
    /// the correctly provisioned one, the only one with work to do — would skip
    /// it and strand the data in Documents forever.
    func testABuildWithNoContainerRemembersNothing() throws {
        let defaults: UserDefaults = try scratchDefaults()
        try write("{}", to: source, named: Store.settingsFile)

        let report: ContainerMigration.Report = SharedContainer.prepareOnLaunch(
            from: source, to: source, defaults: defaults)

        XCTAssertEqual(report, ContainerMigration.Report())
        XCTAssertFalse(defaults.bool(forKey: SharedContainer.migrationDoneKey),
                       "nothing moved, so nothing is done")

        // And the launch after it, on a build that DOES have the container,
        // still does the whole job.
        let later: ContainerMigration.Report = SharedContainer.prepareOnLaunch(
            from: source, to: destination, defaults: defaults)
        XCTAssertEqual(later, ContainerMigration.Report(copied: 1, skipped: 0, failed: 0))
        XCTAssertTrue(defaults.bool(forKey: SharedContainer.migrationDoneKey))
    }

    /// A run that could not finish stays owed. `destination` is a plain FILE
    /// here, so the container directory cannot be created at all.
    func testAnUnfinishedRunIsNotRemembered() throws {
        let defaults: UserDefaults = try scratchDefaults()
        try write("{}", to: source, named: Store.settingsFile)
        let blocked: URL = try write("not a directory", to: root, named: "AppGroupBlocked")

        let report: ContainerMigration.Report = SharedContainer.prepareOnLaunch(
            from: source, to: blocked, defaults: defaults)

        XCTAssertFalse(report.isComplete)
        XCTAssertFalse(defaults.bool(forKey: SharedContainer.migrationDoneKey),
                       "a partial move must be retried, so the marker stays clear")
    }
}
