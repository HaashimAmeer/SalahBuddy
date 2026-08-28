import UIKit
import XCTest
@testable import SalahBuddy

/// v5 §3/§7 (P3) — the ~300px thumbnails, and the retention invariant they
/// have to live inside.
///
/// §3's photo problem is that buddy photos download lazily, so the newest post
/// is the one that is not on disk when a widget's timeline is built. The fix is
/// an eager fetch plus a thumbnail small enough for an extension to decode —
/// and the moment a second copy of somebody else's face exists on disk, §7's
/// sentence about the sweep is a claim about TWO files rather than one:
///
///     "buddy photos expire at 30 days and `BuddyPhotoCache.sweep()` matches;
///      the widget reads that same cache and honours the same sweep
///      (thumbnails included). Never a widget-only photo store."
///
/// So the tests that matter here are not the downscaling ones. They are: the
/// sweep reaches a thumbnail, a report takes both copies, and the two caps do
/// not eat each other. Everything else is arithmetic.
final class BuddyPhotoThumbnailTests: XCTestCase {

    private let day: TimeInterval = 24 * 60 * 60

    private var tempDirectories: [URL] = []
    private var cachedPaths: [String] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories = []
        // The prefetch test writes into the REAL cache (that is the whole
        // point — it is the directory the extension reads), so it takes its
        // files back out. The paths are per-run UUIDs, so nothing else is
        // touched.
        for path in cachedPaths { BuddyPhotoCache.removeEverywhere(forRemotePath: path) }
        cachedPaths = []
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuddyPhotoThumbnailTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    /// A real, decodable JPEG at a real size — `PhotoStore`'s own demo card,
    /// which is 600×600, i.e. twice the thumbnail's long edge.
    private func sampleJPEG(seed: UInt64 = 7) throws -> Data {
        try XCTUnwrap(PhotoStore.demoImage(seed: seed).jpegData(compressionQuality: 0.9))
    }

    private func touch(_ url: URL, at when: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: when],
                                              ofItemAtPath: url.path)
    }

    // MARK: - Deriving one

    func testAThumbnailIsASmallerDecodableJPEG() throws {
        let full: Data = try sampleJPEG()
        let thumb: Data = try XCTUnwrap(BuddyPhotoCache.thumbnailData(from: full))

        let image: UIImage = try XCTUnwrap(UIImage(data: thumb))
        let longEdge: CGFloat = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(longEdge, BuddyPhotoCache.thumbnailMaxDimension)
        // Not a token shrink — the point is that four of these decoded at once
        // are nowhere near a widget's memory ceiling, and a 1200px original is
        // sixteen times the pixels.
        XCTAssertGreaterThan(longEdge, 0)
        XCTAssertLessThan(thumb.count, full.count)
    }

    /// A ceiling, not a target. A friend on an old phone whose photo is already
    /// smaller than 300px must not have it blown up — that costs bytes to make
    /// the picture worse.
    func testABiggerCeilingThanTheOriginalDoesNotUpscaleIt() throws {
        let full: Data = try sampleJPEG()
        let source: CGFloat = try XCTUnwrap(UIImage(data: full)).size.width
        let thumb: Data = try XCTUnwrap(
            BuddyPhotoCache.thumbnailData(from: full, maxPixel: source * 4))
        let image: UIImage = try XCTUnwrap(UIImage(data: thumb))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), source)
    }

    /// A photo that will not decode is not an error anybody should be shown —
    /// the chip draws its emoji, exactly as P2 shipped it.
    func testBytesThatAreNotAnImageAreNilRatherThanACrash() {
        XCTAssertNil(BuddyPhotoCache.thumbnailData(from: Data()))
        XCTAssertNil(BuddyPhotoCache.thumbnailData(from: Data("not a jpeg at all".utf8)))
    }

    // MARK: - Where it goes

    func testAThumbnailIsFiledUnderTheSameKeyInItsOwnDirectory() throws {
        let directory: URL = try makeTempDirectory()
        let path = "circle/mina/one.jpg"

        XCTAssertFalse(BuddyPhotoCache.hasThumbnail(path, in: directory))
        XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: try sampleJPEG(),
                                                     forRemotePath: path, in: directory))
        XCTAssertTrue(BuddyPhotoCache.hasThumbnail(path, in: directory))

        let written: URL = BuddyPhotoCache.thumbnailURL(forRemotePath: path, in: directory)
        // Same key as the full-size file — which is what lets `widget.json`
        // name a picture with ONE string that means the same thing to both
        // processes, and why P2's `thumb` field did not have to change shape.
        XCTAssertEqual(written.lastPathComponent, BuddyPhotoCache.key(forRemotePath: path))
        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent,
                       WidgetFile.thumbnailDirectoryName)
        // INSIDE the cache directory, not beside it: that is what makes
        // `deleteAll()` (which removes the whole tree) cover thumbnails with no
        // line of its own.
        XCTAssertEqual(written.deletingLastPathComponent()
                        .deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    /// The app writes where the extension looks. Nothing else asserts it, and
    /// if the two ever part every photo on every home screen silently becomes
    /// an emoji with a fully green suite.
    func testTheAppWritesTheThumbnailTheExtensionOpens() throws {
        let path = "circle/mina/one.jpg"
        let key: String = BuddyPhotoCache.key(forRemotePath: path)

        XCTAssertEqual(BuddyPhotoCache.directoryName, WidgetFile.photoDirectoryName)
        guard let container: URL = WidgetFile.containerURL else {
            // A test host with no App Group falls back to Documents by design,
            // and the widget — which has no fallback — renders empty there.
            return
        }
        XCTAssertEqual(Store.directory.standardizedFileURL, container.standardizedFileURL)
        XCTAssertEqual(
            BuddyPhotoCache.thumbnailURL(forRemotePath: path).standardizedFileURL,
            try XCTUnwrap(WidgetFile.thumbnailURL(forKey: key)).standardizedFileURL)
    }

    /// `thumb` is a string out of a JSON file, and this is the one place it
    /// becomes a path. A widget that would happily open `../../Library/…`
    /// because the file said so is not something to leave to the writer's good
    /// behaviour.
    func testTheExtensionRefusesAKeyThatIsAPath() {
        XCTAssertNil(WidgetFile.thumbnailURL(forKey: "", in: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(WidgetFile.thumbnailURL(forKey: "../secrets.plist",
                                             in: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(WidgetFile.thumbnailURL(forKey: "a/b.jpg",
                                             in: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(WidgetFile.thumbnailURL(forKey: "..", in: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(WidgetFile.thumbnailURL(forKey: "x.jpg", in: nil))
        XCTAssertEqual(WidgetFile.thumbnailURL(forKey: "abc.jpg",
                                               in: URL(fileURLWithPath: "/tmp"))?
                        .lastPathComponent,
                       "abc.jpg")
    }

    // MARK: - SPEC-V5 §7 — the sweep reaches them

    /// THE test of this phase. A thumbnail is somebody else's face at 300px, so
    /// a cached copy that outlives the thirty days is a photo the poster
    /// believes is gone — the exact state §4 forbade and §7 restated for the
    /// home screen.
    func testAnExpiredThumbnailIsSweptLikeAnyOtherBuddyPhoto() throws {
        let directory: URL = try makeTempDirectory()
        let now: Date = stamp(0)
        let bytes: Data = try sampleJPEG()

        for path in ["c/u/fresh.jpg", "c/u/expired.jpg"] {
            XCTAssertTrue(BuddyPhotoCache.store(bytes, forRemotePath: path, in: directory))
            XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: bytes, forRemotePath: path,
                                                         in: directory))
        }
        let expiredFull: URL = BuddyPhotoCache.url(forRemotePath: "c/u/expired.jpg",
                                                   in: directory)
        let expiredThumb: URL = BuddyPhotoCache.thumbnailURL(forRemotePath: "c/u/expired.jpg",
                                                             in: directory)
        try touch(expiredFull, at: now.addingTimeInterval(-40 * day))
        try touch(expiredThumb, at: now.addingTimeInterval(-40 * day))

        let removed: Int = BuddyPhotoCache.sweep(in: directory, now: now,
                                                 maxAge: 30 * day, maxCount: 100)

        XCTAssertEqual(removed, 2, "the photo AND its thumbnail")
        XCTAssertFalse(BuddyPhotoCache.contains("c/u/expired.jpg", in: directory))
        XCTAssertFalse(BuddyPhotoCache.hasThumbnail("c/u/expired.jpg", in: directory))
        XCTAssertTrue(BuddyPhotoCache.contains("c/u/fresh.jpg", in: directory))
        XCTAssertTrue(BuddyPhotoCache.hasThumbnail("c/u/fresh.jpg", in: directory))
    }

    /// A thumbnail whose photo has already gone still expires on its own clock.
    /// The two files are swept independently — nothing looks up one from the
    /// other — so the thirty days has to hold for a thumbnail sitting alone.
    func testAnOrphanedThumbnailStillExpires() throws {
        let directory: URL = try makeTempDirectory()
        let now: Date = stamp(0)
        XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: try sampleJPEG(),
                                                     forRemotePath: "c/u/alone.jpg",
                                                     in: directory))
        try touch(BuddyPhotoCache.thumbnailURL(forRemotePath: "c/u/alone.jpg", in: directory),
                  at: now.addingTimeInterval(-31 * day))

        XCTAssertEqual(BuddyPhotoCache.sweep(in: directory, now: now,
                                             maxAge: 30 * day, maxCount: 100), 1)
        XCTAssertFalse(BuddyPhotoCache.hasThumbnail("c/u/alone.jpg", in: directory))
    }

    /// The COUNT caps are separate, and deliberately.
    ///
    /// Sharing one would have been the smaller change and a visible regression:
    /// a fully-photographed week is 280 objects against a cap of 400, so every
    /// photo in the app's own grid would start disappearing at roughly half the
    /// age it does today — for the sake of files the app does not draw. The
    /// thirty-day rule, which is the half §7 pins, is identical for both.
    func testThumbnailsDoNotEatThePhotoCountCap() throws {
        let directory: URL = try makeTempDirectory()
        let now: Date = stamp(0)
        let bytes: Data = try sampleJPEG()

        for index in 0..<5 {
            let path = "c/u/\(index).jpg"
            XCTAssertTrue(BuddyPhotoCache.store(bytes, forRemotePath: path, in: directory))
            XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: bytes, forRemotePath: path,
                                                         in: directory))
            let age: TimeInterval = TimeInterval(5 - index) * day
            try touch(BuddyPhotoCache.url(forRemotePath: path, in: directory),
                      at: now.addingTimeInterval(-age))
            try touch(BuddyPhotoCache.thumbnailURL(forRemotePath: path, in: directory),
                      at: now.addingTimeInterval(-age))
        }

        // A cap of 2, applied to each directory rather than to their sum. Share
        // one and the newest photo goes with the oldest.
        let removed: Int = BuddyPhotoCache.sweep(in: directory, now: now,
                                                 maxAge: 30 * day, maxCount: 2)

        XCTAssertEqual(removed, 6, "three of each, not three between them")
        XCTAssertEqual(BuddyPhotoCache.entries(in: directory).count, 2)
        XCTAssertEqual(BuddyPhotoCache.entries(
            in: BuddyPhotoCache.thumbnailDirectory(under: directory)).count, 2)
        XCTAssertTrue(BuddyPhotoCache.contains("c/u/4.jpg", in: directory),
                      "the newest photo survives a cap it was never competing for")
        XCTAssertTrue(BuddyPhotoCache.hasThumbnail("c/u/4.jpg", in: directory))
    }

    /// `entries` counts the photos and not the directory sitting among them —
    /// the thing that makes the cap above honest.
    func testTheThumbnailDirectoryIsNotItselfACachedPhoto() throws {
        let directory: URL = try makeTempDirectory()
        let bytes: Data = try sampleJPEG()
        XCTAssertTrue(BuddyPhotoCache.store(bytes, forRemotePath: "c/u/one.jpg", in: directory))
        XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: bytes, forRemotePath: "c/u/one.jpg",
                                                     in: directory))

        XCTAssertEqual(BuddyPhotoCache.entries(in: directory).count, 1)
    }

    // MARK: - SPEC-V5 §7 — a report takes both copies

    /// The report path deletes the photo. If it left the thumbnail, the picture
    /// somebody just reported would be sitting on their home screen at 44pt —
    /// which §7 calls worse than never having offered the report at all.
    ///
    /// Both files go from ONE call, rather than from two call sites remembering
    /// to pair up.
    func testRemovingAPhotoRemovesItsThumbnail() throws {
        let directory: URL = try makeTempDirectory()
        let bytes: Data = try sampleJPEG()
        let path = "circle/mina/one.jpg"

        XCTAssertTrue(BuddyPhotoCache.store(bytes, forRemotePath: path, in: directory))
        XCTAssertTrue(BuddyPhotoCache.storeThumbnail(from: bytes, forRemotePath: path,
                                                     in: directory))

        BuddyPhotoCache.remove(forRemotePath: path, in: directory)

        XCTAssertFalse(BuddyPhotoCache.contains(path, in: directory))
        XCTAssertFalse(BuddyPhotoCache.hasThumbnail(path, in: directory))
    }

    // MARK: - The eager prefetch (§3)

    /// The branch that runs in the ordinary case: the Today grid already
    /// downloaded this photo, so the prefetch is a decode and a write with no
    /// network in it at all. (The downloading branch is `PhotoSync.download`,
    /// which is the one thing in this layer a unit test cannot reach.)
    func testPrefetchDerivesAThumbnailFromAPhotoThatIsAlreadyCached() async throws {
        let path = "circle/prefetch-test/\(UUID().uuidString).jpg"
        cachedPaths.append(path)
        XCTAssertTrue(BuddyPhotoCache.store(try sampleJPEG(), forRemotePath: path))
        XCTAssertFalse(BuddyPhotoCache.hasThumbnail(path))

        let written: Int = await PhotoSync.prefetchWidgetPhotos(paths: [path])

        XCTAssertEqual(written, 1)
        XCTAssertTrue(BuddyPhotoCache.hasThumbnail(path))
        let thumb: Data = try Data(contentsOf: BuddyPhotoCache.thumbnailURL(forRemotePath: path))
        let image: UIImage = try XCTUnwrap(UIImage(data: thumb))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height),
                                 BuddyPhotoCache.thumbnailMaxDimension)
    }

    /// A pull that changed nothing must cost nothing. The second pass is one
    /// `stat` per path — no decode, no write, and (in the case that matters)
    /// no download.
    func testPrefetchSkipsWhatItHasAlreadyDone() async throws {
        let path = "circle/prefetch-test/\(UUID().uuidString).jpg"
        cachedPaths.append(path)
        XCTAssertTrue(BuddyPhotoCache.store(try sampleJPEG(), forRemotePath: path))

        // Hoisted rather than inlined: `XCTAssertEqual` takes autoclosures, and
        // an autoclosure cannot be `async`.
        let first: Int = await PhotoSync.prefetchWidgetPhotos(paths: [path])
        let second: Int = await PhotoSync.prefetchWidgetPhotos(paths: [path])
        let none: Int = await PhotoSync.prefetchWidgetPhotos(paths: [])
        let empty: Int = await PhotoSync.prefetchWidgetPhotos(paths: [""])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "a pull that changed nothing has to cost nothing")
        XCTAssertEqual(none, 0)
        XCTAssertEqual(empty, 0)
    }
}
