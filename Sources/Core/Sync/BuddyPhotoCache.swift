import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// v4 Phase C — the **disposable** half of SPEC-V4 §4.
///
/// Two photo stores exist in this app and they are deliberately not the same
/// thing:
///
/// - `PhotoStore` (`photos/`) holds YOUR photos. They are yours
///   forever, they feed Memories, and nothing in the sync layer may add to it,
///   evict from it or otherwise change what it means. The server copy of one of
///   your photos is only the share.
/// - `BuddyPhotoCache` (`circlephotos/`) holds photos your circle
///   posted. They are a cache of somebody else's content: cheap to lose, wrong
///   to keep. They expire, they never reach Memories, and they never touch
///   `PhotoStore` — which is why they live behind a different type in a
///   different directory rather than behind a flag on the same one. A flag can
///   be passed wrongly; a separate directory cannot.
///
/// The split of this file is on purpose too: the key derivation and the
/// eviction decision are pure functions over plain values, and the filesystem
/// only appears in the thin wrappers underneath them. That is what lets the
/// tests exercise the rules with nothing but a temp directory.
enum BuddyPhotoCache {

    // MARK: - Policy

    /// v5 §3: named in `WidgetSnapshot.swift`, not here. The extension has to
    /// open these files and cannot compile this type, so the string lives in
    /// the one file both targets share — exactly as `appGroupID` does.
    static let directoryName: String = WidgetFile.photoDirectoryName
    static let fileExtension: String = "jpg"

    /// ~30 days, matching the server's retention sweep (§4). A cached copy that
    /// outlived the object it mirrors is a photo the poster believes is gone.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// A circle is 8 people × 5 prayers, so one fully-photographed week is 280
    /// objects. 400 leaves comfortable headroom for "this week plus change"
    /// while capping the cache at roughly 60 MB of quality-0.7 JPEGs.
    static let maxCount: Int = 400

    /// `circlephotos/` under `Store.directory`, created on demand — same shape
    /// as `PhotoStore.directory`, deliberately NOT the same path.
    static var directory: URL {
        let dir: URL = Store.directory.appendingPathComponent(directoryName, isDirectory: true)
        BuddyPhotoCache.ensureDirectory(dir)
        return dir
    }

    /// Every directory a cached buddy photo could be in, the live one first.
    ///
    /// v5 §2/§7. The container migration deletes `Documents/circlephotos/` the
    /// moment it has copied it, precisely because a second copy of somebody
    /// else's face in a directory nothing enumerates is a photo the poster
    /// believes is gone. But the migration can be OWED — a copy that ran out of
    /// disk retries next launch — and while it is, the old directory is still
    /// full. So the three paths that make a cached photo stop existing (the
    /// sweep, the report-hide, the wipe) visit both.
    ///
    /// One entry whenever there is no container, and nothing here creates a
    /// directory: these are erase paths.
    static var allDirectories: [URL] {
        Store.allDirectories.map {
            $0.appendingPathComponent(directoryName, isDirectory: true)
        }
    }

    // MARK: - Thumbnails (v5 §3, P3)

    /// The long edge of a widget thumbnail, in pixels.
    ///
    /// §3's "~300px". A systemMedium chip is 44pt at 3× — 132 pixels — so 300
    /// is generous even for the systemLarge families P4 may want, and small
    /// enough that four of them decoded at once are nowhere near an extension's
    /// memory ceiling (the full-size file behind each is 1200px, i.e. sixteen
    /// times the pixels, and four of THOSE is how a widget gets jetsammed).
    static let thumbnailMaxDimension: CGFloat = 300

    /// Slightly softer than `PhotoStore.jpegQuality`, because this is a copy of
    /// a copy that is drawn at 44pt.
    static let thumbnailQuality: CGFloat = 0.6

    /// `circlephotos/thumbs/` under `directory`. Created on demand, and only by
    /// the write path — see `directory`.
    static func thumbnailDirectory(under directory: URL) -> URL {
        directory.appendingPathComponent(WidgetFile.thumbnailDirectoryName, isDirectory: true)
    }

    static var thumbnailDirectory: URL {
        let dir: URL = BuddyPhotoCache.thumbnailDirectory(under: BuddyPhotoCache.directory)
        BuddyPhotoCache.ensureDirectory(dir)
        return dir
    }

    /// A thumbnail is filed under the SAME key as the photo it came from, in
    /// its own directory. That is what lets `widget.json` name a picture with
    /// one string that means the same thing on both sides of the container, and
    /// it is why `WidgetSnapshotBuilder.thumb` did not have to change shape.
    static func thumbnailURL(forRemotePath remotePath: String,
                             in directory: URL = BuddyPhotoCache.directory) -> URL {
        BuddyPhotoCache.thumbnailDirectory(under: directory)
            .appendingPathComponent(BuddyPhotoCache.key(forRemotePath: remotePath))
    }

    static func hasThumbnail(_ remotePath: String,
                             in directory: URL = BuddyPhotoCache.directory) -> Bool {
        guard !remotePath.isEmpty else { return false }
        let target: URL = BuddyPhotoCache.thumbnailURL(forRemotePath: remotePath, in: directory)
        return FileManager.default.fileExists(atPath: target.path)
    }

    /// Downscale a full-size JPEG to a widget thumbnail. PURE — bytes in, bytes
    /// out — so the whole rule is testable with no network and no container.
    ///
    /// ImageIO rather than `UIImage`/`UIGraphicsImageRenderer`, and the
    /// difference is not style: `CGImageSourceCreateThumbnailAtIndex` decodes
    /// straight to the requested size, so a 12-megapixel photo never exists as
    /// 48 MB of bitmap on the way to a 300px square. This runs off the main
    /// thread on a phone that is also drawing a grid.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` is what keeps a portrait
    /// photo portrait: EXIF orientation lives in the container, and a thumbnail
    /// generated without it comes out rotated for exactly the pictures people
    /// take of themselves.
    static func thumbnailData(from bytes: Data,
                              maxPixel: CGFloat = BuddyPhotoCache.thumbnailMaxDimension,
                              quality: CGFloat = BuddyPhotoCache.thumbnailQuality) -> Data? {
        guard !bytes.isEmpty, maxPixel > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source: CGImageSource = CGImageSourceCreateWithData(
                bytes as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image: CGImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination: CGImageDestination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Derive and store the thumbnail for a photo whose full-size bytes are in
    /// hand. False when the bytes are not an image this device can read, which
    /// is not an error: the home screen simply draws the emoji chip.
    @discardableResult
    static func storeThumbnail(from bytes: Data, forRemotePath remotePath: String,
                               in directory: URL = BuddyPhotoCache.directory) -> Bool {
        guard !remotePath.isEmpty,
              let thumb: Data = BuddyPhotoCache.thumbnailData(from: bytes) else { return false }
        let folder: URL = BuddyPhotoCache.thumbnailDirectory(under: directory)
        BuddyPhotoCache.ensureDirectory(folder)
        let target: URL = folder.appendingPathComponent(
            BuddyPhotoCache.key(forRemotePath: remotePath))
        do {
            try thumb.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keys (pure)

    /// The on-disk filename for a remote Storage path.
    ///
    /// The remote path (`<circle>/<user>/<uuid>.jpg`) contains slashes, so it
    /// cannot be a filename; hashing it makes one that is flat, fixed-length
    /// and filesystem-safe by construction — lowercase hex has no separator, no
    /// `..`, no case-folding surprise on a case-insensitive volume, and no
    /// length limit to trip over.
    ///
    /// The hash is `Nonce.sha256Hex`, the one already in the tree, rather than
    /// a second digest implementation. A truncated hash would be prettier and
    /// strictly worse: the full 64 characters cost nothing and remove
    /// collisions from the list of things that can go wrong here.
    static func key(forRemotePath remotePath: String) -> String {
        "\(Nonce.sha256Hex(remotePath)).\(BuddyPhotoCache.fileExtension)"
    }

    static func url(forRemotePath remotePath: String,
                    in directory: URL = BuddyPhotoCache.directory) -> URL {
        directory.appendingPathComponent(BuddyPhotoCache.key(forRemotePath: remotePath))
    }

    // MARK: - Read / write

    static func contains(_ remotePath: String,
                         in directory: URL = BuddyPhotoCache.directory) -> Bool {
        guard !remotePath.isEmpty else { return false }
        let target: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        return FileManager.default.fileExists(atPath: target.path)
    }

    static func data(forRemotePath remotePath: String,
                     in directory: URL = BuddyPhotoCache.directory) -> Data? {
        guard !remotePath.isEmpty else { return nil }
        let target: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        return try? Data(contentsOf: target)
    }

    static func image(forRemotePath remotePath: String,
                      in directory: URL = BuddyPhotoCache.directory) -> UIImage? {
        guard let bytes: Data = BuddyPhotoCache.data(forRemotePath: remotePath,
                                                     in: directory) else { return nil }
        return UIImage(data: bytes)
    }

    /// Writes the downloaded bytes as-is. No decode, no re-encode: what the
    /// poster's device downscaled is what every other device shows, and a byte
    /// that never passes through `UIImage` cannot pick up a rotation or a
    /// colour-space surprise on the way through.
    @discardableResult
    static func store(_ bytes: Data, forRemotePath remotePath: String,
                      in directory: URL = BuddyPhotoCache.directory) -> Bool {
        guard !remotePath.isEmpty, !bytes.isEmpty else { return false }
        BuddyPhotoCache.ensureDirectory(directory)
        let target: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        do {
            try bytes.write(to: target, options: .atomic)
            return true
        } catch {
            // A cache that cannot write is still a working app: the next read
            // just downloads again. Never propagate this.
            return false
        }
    }

    /// Drops one cached photo — the call for a post that vanished server-side
    /// (a buddy's undo), where the bytes are now something nobody may see.
    ///
    /// **Both files.** v5 §3 gave every cached photo a ~300px twin, and a
    /// thumbnail is the same face at a smaller size: a report that took the
    /// photo away and left the thumbnail would put it straight back on the home
    /// screen, which §7 calls worse than never having offered the report. The
    /// two are deleted together here rather than at the two call sites, so
    /// there is nowhere to forget one.
    static func remove(forRemotePath remotePath: String,
                       in directory: URL = BuddyPhotoCache.directory) {
        guard !remotePath.isEmpty else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: BuddyPhotoCache.url(forRemotePath: remotePath,
                                                        in: directory))
        try? manager.removeItem(at: BuddyPhotoCache.thumbnailURL(forRemotePath: remotePath,
                                                                 in: directory))
    }

    /// The same drop, from every directory the photo could be in — the call for
    /// a report (SPEC-V5 §7: "a hidden photo reappearing is worse than it never
    /// having been hideable") and for a buddy's undo. See `allDirectories`.
    static func removeEverywhere(forRemotePath remotePath: String) {
        guard !remotePath.isEmpty else { return }
        for directory in BuddyPhotoCache.allDirectories {
            BuddyPhotoCache.remove(forRemotePath: remotePath, in: directory)
        }
    }

    /// Deletes the whole cache — leaving a circle, signing out, deleting the
    /// account, reset-all-data. Mirrors `PhotoStore.deleteAll()` in name so the
    /// two are obviously siblings, and in nothing else: this one is called on
    /// paths where `PhotoStore` must be left completely alone.
    ///
    /// Every directory, not just the live one: an ex-member of a circle keeping
    /// every face in it, in a copy the app no longer looks at, is the worst
    /// version of the bug this whole type exists to avoid. `thumbs/` is inside
    /// what is removed here, so v5's thumbnails need no line of their own — the
    /// reason they live in a SUBdirectory rather than a sibling one.
    static func deleteAll() {
        for directory in BuddyPhotoCache.allDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Eviction

    /// One cached file, as the eviction rule sees it. `storedAt` is the file's
    /// modification date, i.e. when it was DOWNLOADED.
    struct Entry: Equatable, Sendable {
        let name: String
        let storedAt: Date

        init(name: String, storedAt: Date) {
            self.name = name
            self.storedAt = storedAt
        }
    }

    /// Which files must go, oldest first.
    ///
    /// v4 DECISION: **age is measured from the download, and reading a photo
    /// does not refresh it.** An LRU would keep a much-looked-at photo alive
    /// past the server's 30-day sweep, which is exactly the state §4 forbids —
    /// a local copy outliving the original. So the clock on a cached photo runs
    /// from the moment it arrived and cannot be reset, and the count cap
    /// evicts by that same date. The cache is a mirror with an expiry, not a
    /// library.
    ///
    /// Two rules, applied in order:
    /// 1. anything older than `maxAge` goes, however small the cache is;
    /// 2. whatever survives is trimmed to `maxCount`, oldest first.
    static func victims(among entries: [Entry],
                        now: Date,
                        maxAge: TimeInterval = BuddyPhotoCache.maxAge,
                        maxCount: Int = BuddyPhotoCache.maxCount) -> [String] {
        // Name as a tie-break so the answer never depends on the order the
        // filesystem happened to enumerate — a test that passes on one device
        // and fails on another is worse than no test.
        let ordered: [Entry] = entries.sorted { (lhs: Entry, rhs: Entry) -> Bool in
            if lhs.storedAt != rhs.storedAt { return lhs.storedAt < rhs.storedAt }
            return lhs.name < rhs.name
        }

        var doomed: [String] = []
        var survivors: [Entry] = []
        for entry in ordered {
            // A `storedAt` in the future (a clock that moved, a copied file)
            // yields a negative age and therefore survives. Better a photo
            // kept slightly too long than a cache emptied by a bad timestamp.
            let age: TimeInterval = now.timeIntervalSince(entry.storedAt)
            if age > maxAge {
                doomed.append(entry.name)
            } else {
                survivors.append(entry)
            }
        }

        let cap: Int = max(0, maxCount)
        let overflow: Int = survivors.count - cap
        if overflow > 0 {
            for index in 0..<overflow {
                doomed.append(survivors[index].name)
            }
        }
        return doomed
    }

    /// The cache's current contents. A file with no readable modification date
    /// is dated to the epoch, so it is treated as ancient and swept — an
    /// unreadable entry is not one worth keeping.
    static func entries(in directory: URL = BuddyPhotoCache.directory) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls: [URL] = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else {
            return []
        }

        var result: [Entry] = []
        for fileURL in urls where fileURL.pathExtension == BuddyPhotoCache.fileExtension {
            let values: URLResourceValues? = try? fileURL.resourceValues(forKeys: Set(keys))
            let modified: Date = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            result.append(Entry(name: fileURL.lastPathComponent, storedAt: modified))
        }
        return result
    }

    /// Applies `victims` to disk. Returns how many files were removed.
    ///
    /// Time comes from `AppClock.now` like everything else, so a demo-mode
    /// session that time-travels forward sweeps the cache it would have swept
    /// had that much time really passed. (A real circle pins the offset to
    /// zero anyway — SPEC-V4 §3.)
    ///
    /// **v5 §7: the thumbnails go through the same rule.** They are somebody
    /// else's face at 300px, so "buddy photos expire at 30 days and the widget
    /// honours the same sweep" is a claim about them too — and the surest way
    /// to keep it is for the sweep to be one function that visits both, rather
    /// than a second call somebody has to remember. `thumbs/` gets its OWN
    /// count cap rather than sharing one, because the two hold different things
    /// (a 1200px photo against a 300px copy of it) and a shared count would
    /// halve the age at which real photos start disappearing out of the app's
    /// own grid. The 30-day half is identical, and that is the half §7 pins.
    ///
    /// A thumbnail can therefore outlive a photo the COUNT cap evicted. That is
    /// deliberate and harmless: it is still inside the thirty days, and it is
    /// still the file the home screen is naming.
    @discardableResult
    static func sweep(in directory: URL = BuddyPhotoCache.directory,
                      now: Date = AppClock.now,
                      maxAge: TimeInterval = BuddyPhotoCache.maxAge,
                      maxCount: Int = BuddyPhotoCache.maxCount) -> Int {
        BuddyPhotoCache.sweepOneDirectory(directory, now: now,
                                          maxAge: maxAge, maxCount: maxCount)
            + BuddyPhotoCache.sweepOneDirectory(
                BuddyPhotoCache.thumbnailDirectory(under: directory),
                now: now, maxAge: maxAge, maxCount: maxCount)
    }

    private static func sweepOneDirectory(_ directory: URL, now: Date,
                                          maxAge: TimeInterval, maxCount: Int) -> Int {
        let present: [Entry] = BuddyPhotoCache.entries(in: directory)
        let doomed: [String] = BuddyPhotoCache.victims(among: present, now: now,
                                                       maxAge: maxAge, maxCount: maxCount)
        var removed: Int = 0
        for name in doomed {
            let target: URL = directory.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: target)
                removed += 1
            } catch {
                // Already gone is a fine outcome; nothing here is worth a log.
            }
        }
        return removed
    }

    /// The sweep, over every directory the cache could be in. This is what the
    /// app calls; `sweep(in:)` is the rule applied to one of them.
    ///
    /// The extra directory only exists while the v5 migration is still owed
    /// (see `allDirectories`), and a photo aging out in a directory nothing
    /// enumerates is exactly the retention breach §7 names.
    @discardableResult
    static func sweepEverywhere(now: Date = AppClock.now,
                                maxAge: TimeInterval = BuddyPhotoCache.maxAge,
                                maxCount: Int = BuddyPhotoCache.maxCount) -> Int {
        BuddyPhotoCache.allDirectories.reduce(0) { total, directory in
            total + BuddyPhotoCache.sweep(in: directory, now: now,
                                          maxAge: maxAge, maxCount: maxCount)
        }
    }

    // MARK: - Internals

    private static func ensureDirectory(_ directory: URL) {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
