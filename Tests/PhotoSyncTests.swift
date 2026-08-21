import XCTest
@testable import SalahBuddy

/// v4 Phase C — the photo half of SPEC-V4 §4.
///
/// Everything here is either a pure function (the Storage path builder, the
/// cache key, the eviction rule, the "already there" classifier) or a few
/// files in a temp directory. Nothing touches the network, and nothing touches
/// the app's real Documents directory except to read where two of its
/// subdirectories are — which is itself one of the things under test, because
/// the privacy line in §4 IS the fact that buddy photos and your photos live in
/// different places.
final class PhotoSyncTests: XCTestCase {

    // Fixed ids so a failure message is readable.
    private let circleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let objectID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private let day: TimeInterval = 24 * 60 * 60

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    /// Whole seconds only, so nothing here depends on sub-second rounding.
    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    private func entry(_ name: String, _ storedAt: Date) -> BuddyPhotoCache.Entry {
        BuddyPhotoCache.Entry(name: name, storedAt: storedAt)
    }

    @discardableResult
    private func writeCachedPhoto(remotePath: String, in directory: URL,
                                  storedAt: Date) throws -> URL {
        let target: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        try Data("jpeg-bytes-\(remotePath)".utf8).write(to: target, options: .atomic)
        let attributes: [FileAttributeKey: Any] = [.modificationDate: storedAt]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
        return target
    }

    // MARK: - Storage path builder

    func testStoragePathIsCircleThenUserThenObject() {
        let path: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                 objectID: objectID)
        let parts: [String] = path.components(separatedBy: "/")

        XCTAssertEqual(parts.count, 3, "the RLS policies read folder 1 and folder 2 by position")
        XCTAssertEqual(parts[0], circleID.uuidString.lowercased())
        XCTAssertEqual(parts[1], userID.uuidString.lowercased())
        XCTAssertEqual(parts[2], objectID.uuidString.lowercased() + ".jpg")
    }

    /// Postgres renders a uuid as lowercase and Swift's `uuidString` is
    /// uppercase, so an uppercase path fails `(storage.foldername(name))[1] =
    /// public.current_circle_id()::text` and every upload 403s.
    func testStoragePathIsLowercased() {
        let path: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                 objectID: objectID)
        XCTAssertEqual(path, path.lowercased())
    }

    /// §4's privacy line at the path level: a `PhotoStore` filename spells out
    /// the day and the prayer, and a Storage key is readable by everyone in the
    /// circle. The object name is a bare UUID and nothing else.
    func testStoragePathNeverCarriesAPhotoStoreFilename() {
        let localFilename: String = "2026-06-08_fajr_ab12cd34.jpg"
        let path: String = PhotoSync.storagePath(circleID: circleID, userID: userID)

        XCTAssertFalse(path.contains(localFilename))
        XCTAssertFalse(path.contains("fajr"))
        XCTAssertFalse(path.contains("2026-06-08"))
        // PhotoStore filenames always contain "_"; a storage path never does.
        XCTAssertFalse(path.contains("_"))

        let object: String = path.components(separatedBy: "/").last ?? ""
        XCTAssertTrue(object.hasSuffix(".jpg"))
        let stem: String = String(object.dropLast(4))
        XCTAssertNotNil(UUID(uuidString: stem), "the object name must be a bare UUID")
    }

    func testStoragePathObjectIDIsFreshPerCallButStableWhenGiven() {
        let first: String = PhotoSync.storagePath(circleID: circleID, userID: userID)
        let second: String = PhotoSync.storagePath(circleID: circleID, userID: userID)
        XCTAssertNotEqual(first, second, "each photo gets its own object")

        // A retry must land on the object the op was queued with, which is why
        // the caller pins `objectID` in the outbox rather than rebuilding it.
        let pinnedA: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                    objectID: objectID)
        let pinnedB: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                    objectID: objectID)
        XCTAssertEqual(pinnedA, pinnedB)
    }

    // MARK: - Failure classification

    func testDuplicateUploadCountsAsSuccess() {
        XCTAssertTrue(PhotoSync.isAlreadyExists(statusCode: "409", errorCode: nil))
        XCTAssertTrue(PhotoSync.isAlreadyExists(statusCode: nil, errorCode: "Duplicate"))
        XCTAssertTrue(PhotoSync.isAlreadyExists(statusCode: nil, errorCode: "duplicate"))

        XCTAssertFalse(PhotoSync.isAlreadyExists(statusCode: "404", errorCode: "NotFound"))
        XCTAssertFalse(PhotoSync.isAlreadyExists(statusCode: "403", errorCode: nil))
        XCTAssertFalse(PhotoSync.isAlreadyExists(statusCode: nil, errorCode: nil))
    }

    func testMissingObjectCountsAsADoneDelete() {
        XCTAssertTrue(PhotoSync.isNotFound(statusCode: "404", errorCode: nil))
        XCTAssertTrue(PhotoSync.isNotFound(statusCode: nil, errorCode: "NotFound"))
        XCTAssertFalse(PhotoSync.isNotFound(statusCode: "409", errorCode: "Duplicate"))
        XCTAssertFalse(PhotoSync.isNotFound(statusCode: nil, errorCode: nil))
    }

    /// The drain uses this to tell "spend another attempt" from "drop the op".
    func testPermanentFailuresAreOnlyOurOwn() {
        XCTAssertTrue(PhotoSync.isPermanent(PhotoSyncError.emptyPath))
        XCTAssertTrue(PhotoSync.isPermanent(PhotoSyncError.missingLocalPhoto("a.jpg")))
        XCTAssertFalse(PhotoSync.isPermanent(URLError(.notConnectedToInternet)))
        XCTAssertFalse(PhotoSync.isPermanent(CircleError.offline))
    }

    func testUploadWithNoLocalPhotoFailsPermanentlyWithoutNetworking() async {
        // "" is what `PhotoStore.save` returns when the write failed, and undo
        // can delete the JPEG before the drain reaches its op. Neither may
        // reach the network, and neither is worth a retry.
        do {
            try await PhotoSync.upload(filename: "", to: "c/u/o.jpg")
            XCTFail("an empty filename must not be uploadable")
        } catch {
            XCTAssertTrue(PhotoSync.isPermanent(error))
        }

        do {
            try await PhotoSync.upload(filename: "definitely-not-on-disk.jpg", to: "")
            XCTFail("an empty storage path must not be uploadable")
        } catch {
            XCTAssertEqual(error as? PhotoSyncError, PhotoSyncError.emptyPath)
        }
    }

    // MARK: - Cache keys

    func testCacheKeyIsStableAndFilesystemSafe() {
        let remotePath: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                       objectID: objectID)
        let key: String = BuddyPhotoCache.key(forRemotePath: remotePath)

        XCTAssertEqual(key, BuddyPhotoCache.key(forRemotePath: remotePath),
                       "the same remote path must always name the same file")
        XCTAssertNotEqual(key, BuddyPhotoCache.key(forRemotePath: remotePath + "x"))

        XCTAssertTrue(key.hasSuffix(".jpg"))
        let stem: String = String(key.dropLast(4))
        XCTAssertEqual(stem.count, 64, "a full SHA-256, not a truncated one")

        let hex: Set<Character> = Set("0123456789abcdef")
        XCTAssertTrue(stem.allSatisfy { hex.contains($0) })

        // The whole point of hashing: the remote path's separators cannot
        // escape the cache directory.
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains(".."))
        XCTAssertFalse(key.contains(":"))
        XCTAssertFalse(key.contains(" "))
    }

    func testCacheKeyDistinguishesPathsThatDifferOnlyInTheOwner() {
        let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let mine: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                 objectID: objectID)
        let theirs: String = PhotoSync.storagePath(circleID: circleID, userID: other,
                                                   objectID: objectID)
        XCTAssertNotEqual(BuddyPhotoCache.key(forRemotePath: mine),
                          BuddyPhotoCache.key(forRemotePath: theirs))
    }

    // MARK: - The privacy line

    /// SPEC-V4 §4: buddy photos are disposable and must never enter
    /// `PhotoStore`, because `PhotoStore` is what Memories reads.
    func testBuddyCacheDirectoryIsNotPhotoStore() {
        let cache: URL = BuddyPhotoCache.directory.standardizedFileURL
        let photos: URL = PhotoStore.directory.standardizedFileURL

        XCTAssertNotEqual(cache, photos)
        XCTAssertEqual(cache.lastPathComponent, "circlephotos")
        XCTAssertEqual(photos.lastPathComponent, "photos")
        XCTAssertFalse(cache.path.hasPrefix(photos.path + "/"),
                       "the buddy cache must not nest inside PhotoStore")
        XCTAssertFalse(photos.path.hasPrefix(cache.path + "/"))
    }

    func testCachedBuddyPhotoNeverLandsInPhotoStore() {
        let remotePath: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                       objectID: objectID)
        let cached: URL = BuddyPhotoCache.url(forRemotePath: remotePath)
        let photos: URL = PhotoStore.directory.standardizedFileURL

        XCTAssertNotEqual(cached.deletingLastPathComponent().standardizedFileURL, photos)
        XCTAssertEqual(cached.deletingLastPathComponent().standardizedFileURL,
                       BuddyPhotoCache.directory.standardizedFileURL)
        // And it could not collide with a PhotoStore name even if it were
        // there: those carry the day and prayer, these are hex.
        XCTAssertFalse(cached.lastPathComponent.contains("_"))
    }

    // MARK: - Eviction (pure)

    func testEvictionByAgeDropsAnythingPastRetention() {
        let now: Date = stamp(0)
        let entries: [BuddyPhotoCache.Entry] = [
            entry("fresh.jpg", now),
            entry("recent.jpg", now.addingTimeInterval(-29 * day)),
            entry("stale.jpg", now.addingTimeInterval(-31 * day)),
            entry("ancient.jpg", now.addingTimeInterval(-400 * day))
        ]

        let doomed: [String] = BuddyPhotoCache.victims(among: entries, now: now,
                                                       maxAge: 30 * day, maxCount: 100)
        XCTAssertEqual(doomed, ["ancient.jpg", "stale.jpg"],
                       "oldest first, and only what outlived the server's copy")
    }

    func testEvictionByCountDropsTheOldestSurvivors() {
        let now: Date = stamp(0)
        let entries: [BuddyPhotoCache.Entry] = [
            entry("a.jpg", now.addingTimeInterval(-5 * day)),
            entry("b.jpg", now.addingTimeInterval(-4 * day)),
            entry("c.jpg", now.addingTimeInterval(-3 * day)),
            entry("d.jpg", now.addingTimeInterval(-2 * day)),
            entry("e.jpg", now.addingTimeInterval(-1 * day))
        ]

        let doomed: [String] = BuddyPhotoCache.victims(among: entries, now: now,
                                                       maxAge: 30 * day, maxCount: 3)
        XCTAssertEqual(doomed, ["a.jpg", "b.jpg"])
    }

    func testEvictionAppliesAgeFirstThenCount() {
        let now: Date = stamp(0)
        let entries: [BuddyPhotoCache.Entry] = [
            entry("expired.jpg", now.addingTimeInterval(-40 * day)),
            entry("old.jpg", now.addingTimeInterval(-9 * day)),
            entry("mid.jpg", now.addingTimeInterval(-8 * day)),
            entry("new.jpg", now.addingTimeInterval(-7 * day))
        ]

        let doomed: [String] = BuddyPhotoCache.victims(among: entries, now: now,
                                                       maxAge: 30 * day, maxCount: 2)
        // The expired one goes on age; the count cap then trims the oldest of
        // what is left, so exactly `maxCount` files survive.
        XCTAssertEqual(doomed, ["expired.jpg", "old.jpg"])
        XCTAssertEqual(entries.count - doomed.count, 2)
    }

    func testEvictionKeepsEverythingInsideBothLimits() {
        let now: Date = stamp(0)
        let entries: [BuddyPhotoCache.Entry] = [
            entry("a.jpg", now.addingTimeInterval(-1 * day)),
            entry("b.jpg", now)
        ]
        XCTAssertEqual(BuddyPhotoCache.victims(among: entries, now: now,
                                               maxAge: 30 * day, maxCount: 10), [])
        XCTAssertEqual(BuddyPhotoCache.victims(among: [], now: now,
                                               maxAge: 30 * day, maxCount: 10), [])
    }

    /// A timestamp in the future yields a negative age. Better a photo kept a
    /// little too long than a cache emptied by a clock that moved.
    func testEvictionIgnoresFutureTimestamps() {
        let now: Date = stamp(0)
        let entries: [BuddyPhotoCache.Entry] = [entry("future.jpg", now.addingTimeInterval(day))]
        XCTAssertEqual(BuddyPhotoCache.victims(among: entries, now: now,
                                               maxAge: 30 * day, maxCount: 10), [])
    }

    /// Ties are broken by name so the answer never depends on the order the
    /// filesystem happened to enumerate.
    func testEvictionIsDeterministicWhenTimestampsTie() {
        let now: Date = stamp(0)
        let tied: Date = now.addingTimeInterval(-day)
        let forwards: [BuddyPhotoCache.Entry] = [
            entry("b.jpg", tied), entry("a.jpg", tied), entry("c.jpg", tied)
        ]
        let backwards: [BuddyPhotoCache.Entry] = [
            entry("c.jpg", tied), entry("a.jpg", tied), entry("b.jpg", tied)
        ]

        XCTAssertEqual(BuddyPhotoCache.victims(among: forwards, now: now,
                                               maxAge: 30 * day, maxCount: 1),
                       ["a.jpg", "b.jpg"])
        XCTAssertEqual(BuddyPhotoCache.victims(among: forwards, now: now,
                                               maxAge: 30 * day, maxCount: 1),
                       BuddyPhotoCache.victims(among: backwards, now: now,
                                               maxAge: 30 * day, maxCount: 1))
    }

    // MARK: - Cache I/O (temp directory)

    func testStoreAndReadRoundTrip() throws {
        let directory: URL = try makeTempDirectory()
        let remotePath: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                       objectID: objectID)
        let bytes = Data("pretend-jpeg".utf8)

        XCTAssertFalse(BuddyPhotoCache.contains(remotePath, in: directory))
        XCTAssertTrue(BuddyPhotoCache.store(bytes, forRemotePath: remotePath, in: directory))
        XCTAssertTrue(BuddyPhotoCache.contains(remotePath, in: directory))
        XCTAssertEqual(BuddyPhotoCache.data(forRemotePath: remotePath, in: directory), bytes)

        let written: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        XCTAssertEqual(written.lastPathComponent,
                       BuddyPhotoCache.key(forRemotePath: remotePath))
        XCTAssertEqual(written.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)

        BuddyPhotoCache.remove(forRemotePath: remotePath, in: directory)
        XCTAssertFalse(BuddyPhotoCache.contains(remotePath, in: directory))
        XCTAssertNil(BuddyPhotoCache.data(forRemotePath: remotePath, in: directory))
    }

    func testStoreRefusesNothingToStore() throws {
        let directory: URL = try makeTempDirectory()
        XCTAssertFalse(BuddyPhotoCache.store(Data(), forRemotePath: "c/u/o.jpg", in: directory))
        XCTAssertFalse(BuddyPhotoCache.store(Data("x".utf8), forRemotePath: "", in: directory))
        XCTAssertFalse(BuddyPhotoCache.contains("", in: directory))
    }

    func testStoreCreatesTheDirectoryItNeeds() throws {
        let parent: URL = try makeTempDirectory()
        let missing: URL = parent.appendingPathComponent("not-yet", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        XCTAssertTrue(BuddyPhotoCache.store(Data("x".utf8), forRemotePath: "c/u/o.jpg",
                                            in: missing))
        XCTAssertTrue(BuddyPhotoCache.contains("c/u/o.jpg", in: missing))
    }

    func testEntriesReadTheModificationDate() throws {
        let directory: URL = try makeTempDirectory()
        let when: Date = stamp(-3 * day)
        try writeCachedPhoto(remotePath: "c/u/one.jpg", in: directory, storedAt: when)

        let entries: [BuddyPhotoCache.Entry] = BuddyPhotoCache.entries(in: directory)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, BuddyPhotoCache.key(forRemotePath: "c/u/one.jpg"))
        XCTAssertEqual(entries.first?.storedAt.timeIntervalSince1970 ?? 0,
                       when.timeIntervalSince1970, accuracy: 1)
    }

    func testSweepRemovesExpiredFilesAndLeavesTheRest() throws {
        let directory: URL = try makeTempDirectory()
        let now: Date = stamp(0)

        let fresh: URL = try writeCachedPhoto(remotePath: "c/u/fresh.jpg", in: directory,
                                              storedAt: now)
        let recent: URL = try writeCachedPhoto(remotePath: "c/u/recent.jpg", in: directory,
                                               storedAt: now.addingTimeInterval(-10 * day))
        let expired: URL = try writeCachedPhoto(remotePath: "c/u/expired.jpg", in: directory,
                                                storedAt: now.addingTimeInterval(-40 * day))

        let removed: Int = BuddyPhotoCache.sweep(in: directory, now: now,
                                                 maxAge: 30 * day, maxCount: 100)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    }

    func testSweepEnforcesTheCountCapOnDisk() throws {
        let directory: URL = try makeTempDirectory()
        let now: Date = stamp(0)

        var written: [URL] = []
        for index in 0..<5 {
            let age: TimeInterval = TimeInterval(5 - index) * day
            let stored: URL = try writeCachedPhoto(remotePath: "c/u/\(index).jpg",
                                                   in: directory,
                                                   storedAt: now.addingTimeInterval(-age))
            written.append(stored)
        }

        let removed: Int = BuddyPhotoCache.sweep(in: directory, now: now,
                                                 maxAge: 30 * day, maxCount: 2)

        XCTAssertEqual(removed, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[2].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[3].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[4].path))
        XCTAssertEqual(BuddyPhotoCache.entries(in: directory).count, 2)
    }

    func testSweepOfAnEmptyOrMissingDirectoryIsHarmless() throws {
        let directory: URL = try makeTempDirectory()
        XCTAssertEqual(BuddyPhotoCache.sweep(in: directory, now: stamp(0)), 0)

        let missing: URL = directory.appendingPathComponent("gone", isDirectory: true)
        XCTAssertEqual(BuddyPhotoCache.sweep(in: missing, now: stamp(0)), 0)
        XCTAssertEqual(BuddyPhotoCache.entries(in: missing), [])
    }

    // MARK: - Policy sanity

    func testRetentionPolicyMatchesTheServerSweep() {
        XCTAssertEqual(BuddyPhotoCache.maxAge, 30 * day, "§4: ~30 days, matching the server")
        XCTAssertGreaterThan(BuddyPhotoCache.maxCount, 8 * 5 * 7,
                             "one fully-photographed circle week must fit without eviction")
    }
}
