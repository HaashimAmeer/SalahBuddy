import Foundation
import UIKit

/// v4 Phase C — the **disposable** half of SPEC-V4 §4.
///
/// Two photo stores exist in this app and they are deliberately not the same
/// thing:
///
/// - `PhotoStore` (`Documents/photos/`) holds YOUR photos. They are yours
///   forever, they feed Memories, and nothing in the sync layer may add to it,
///   evict from it or otherwise change what it means. The server copy of one of
///   your photos is only the share.
/// - `BuddyPhotoCache` (`Documents/circlephotos/`) holds photos your circle
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

    static let directoryName: String = "circlephotos"
    static let fileExtension: String = "jpg"

    /// ~30 days, matching the server's retention sweep (§4). A cached copy that
    /// outlived the object it mirrors is a photo the poster believes is gone.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// A circle is 8 people × 5 prayers, so one fully-photographed week is 280
    /// objects. 400 leaves comfortable headroom for "this week plus change"
    /// while capping the cache at roughly 60 MB of quality-0.7 JPEGs.
    static let maxCount: Int = 400

    /// `Documents/circlephotos/`, created on demand — same shape as
    /// `PhotoStore.directory`, deliberately NOT the same path.
    static var directory: URL {
        let dir: URL = Store.directory.appendingPathComponent(directoryName, isDirectory: true)
        BuddyPhotoCache.ensureDirectory(dir)
        return dir
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
    static func remove(forRemotePath remotePath: String,
                       in directory: URL = BuddyPhotoCache.directory) {
        guard !remotePath.isEmpty else { return }
        let target: URL = BuddyPhotoCache.url(forRemotePath: remotePath, in: directory)
        try? FileManager.default.removeItem(at: target)
    }

    /// Deletes the whole cache — leaving a circle, signing out, deleting the
    /// account, reset-all-data. Mirrors `PhotoStore.deleteAll()` in name so the
    /// two are obviously siblings, and in nothing else: this one is called on
    /// paths where `PhotoStore` must be left completely alone.
    static func deleteAll() {
        let dir: URL = Store.directory.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
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
    @discardableResult
    static func sweep(in directory: URL = BuddyPhotoCache.directory,
                      now: Date = AppClock.now,
                      maxAge: TimeInterval = BuddyPhotoCache.maxAge,
                      maxCount: Int = BuddyPhotoCache.maxCount) -> Int {
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

    // MARK: - Internals

    private static func ensureDirectory(_ directory: URL) {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
