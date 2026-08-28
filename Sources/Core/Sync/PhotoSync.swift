import Foundation
import Supabase
import UIKit

/// The ways a photo transfer can fail that no amount of retrying will fix.
///
/// The outbox owns retries, and it has no way to tell "the network blinked"
/// from "this op is impossible" unless the failure says so. Everything thrown
/// from `PhotoSync` that is NOT one of these is worth another attempt; these
/// are worth dropping immediately (see `PhotoSync.isPermanent(_:)`), because
/// eight backed-off attempts at a file that no longer exists is eight delays
/// in front of every write queued behind it.
enum PhotoSyncError: Error, Equatable {
    /// The `PhotoStore` JPEG this op was meant to send is gone — undone,
    /// reset, or never written (`PhotoStore.save` returns "" on failure).
    case missingLocalPhoto(String)
    /// An empty Storage path. A caller bug, not a server one.
    case emptyPath
}

/// v4 Phase C — moving prayer photos between the device and Storage (SPEC-V4 §4).
///
/// This is the ONLY file in the app that talks to Supabase Storage. That is a
/// deliberate blast radius: the sandbox this was written in cannot compile
/// Swift, CI is the compiler, and an SDK signature that turns out to be wrong
/// should be one file to fix rather than a hunt.
///
/// Three rules shape everything below.
///
/// 1. **Your photos never move.** `PhotoStore` semantics are untouched: the
///    file stays in `photos/` under `Store.directory`, Memories still finds it,
///    and the upload is a copy of the same bytes. Nothing here deletes a local
///    photo.
/// 2. **The bytes are already right.** `PhotoStore` downscaled to 1200px and
///    encoded at quality 0.7 when the photo was taken; this layer re-reads that
///    exact JPEG and sends it. It never loads a `UIImage` to send one — a
///    decode/re-encode round trip would cost quality, cost time, and silently
///    change the object the bucket's `image/jpeg` 5 MB limit was sized for.
/// 3. **Retries belong to the outbox.** These functions succeed or throw. They
///    hold no state, schedule nothing, and never swallow a failure the queue
///    needs to see — with the single exception of a replay landing on work
///    that is already done, which IS success (see `isAlreadyExists`).
enum PhotoSync {

    /// The bucket accepts `image/jpeg` and nothing else (see
    /// `backend/supabase/migrations/20260821000500_storage.sql`).
    static let contentType: String = "image/jpeg"

    // MARK: - Paths (pure)

    /// The Storage path for one of your photos: `<circle_id>/<user_id>/<uuid>.jpg`.
    ///
    /// **Lowercase is load-bearing, not cosmetic.** The RLS policies compare
    /// `(storage.foldername(name))[1]` against `public.current_circle_id()::text`
    /// and `[2]` against `auth.uid()::text`, and Postgres renders a `uuid` as
    /// lowercase. Swift's `UUID.uuidString` is UPPERCASE. Send the uppercase
    /// form and every single upload fails the insert policy with a 403 that
    /// looks exactly like a broken session.
    ///
    /// The object name is a fresh UUID and carries no meaning on purpose: a
    /// `PhotoStore` filename spells out the day and the prayer
    /// (`2026-06-08_fajr_ab12cd34.jpg`), and a Storage key is readable by
    /// everyone in the circle. What the photo is of is the picture's business;
    /// the path says only who may read it and who owns it.
    static func storagePath(circleID: UUID, userID: UUID, objectID: UUID = UUID()) -> String {
        let circle: String = circleID.uuidString.lowercased()
        let user: String = userID.uuidString.lowercased()
        let object: String = objectID.uuidString.lowercased()
        return "\(circle)/\(user)/\(object).jpg"
    }

    // MARK: - Failure classification (pure)

    /// Whether a Storage failure means "that object is already there".
    ///
    /// Taken as SUCCESS. The path carries a UUID generated once, when the
    /// upload was queued, so the only writer that can ever collide with it is
    /// this same op replaying after a lost response — and the bytes it would
    /// write are byte-identical to the ones already stored. That is precisely
    /// what idempotence means, so a replay is finished, not failed.
    ///
    /// This is why the upload does NOT set `upsert: true`: overwriting would
    /// reach the same end state by re-sending a whole JPEG over the flaky link
    /// that lost the response in the first place.
    ///
    /// The string overload is the authority so the whole rule stays testable
    /// without a network, a server or the SDK — the same shape `CircleError`
    /// uses for its SQLSTATE table.
    static func isAlreadyExists(statusCode: String?, errorCode: String?) -> Bool {
        if statusCode == "409" { return true }
        if let errorCode, errorCode.caseInsensitiveCompare("Duplicate") == .orderedSame {
            return true
        }
        return false
    }

    /// Whether a Storage failure means "there is nothing there to act on".
    /// Taken as success by `delete`: a retraction whose object is already gone
    /// has achieved what it wanted.
    static func isNotFound(statusCode: String?, errorCode: String?) -> Bool {
        if statusCode == "404" { return true }
        if let errorCode, errorCode.caseInsensitiveCompare("NotFound") == .orderedSame {
            return true
        }
        return false
    }

    /// The op can never succeed, so the drain should discard it rather than
    /// spend its attempt budget. Anything else is a retry.
    static func isPermanent(_ error: any Error) -> Bool {
        error is PhotoSyncError
    }

    // MARK: - Transfers

    /// Sends one of YOUR photos to the circle's bucket.
    ///
    /// `filename` is the bare `PhotoStore` filename the log already references;
    /// `path` is the destination from `storagePath(circleID:userID:)`, fixed
    /// when the op was queued so a retry lands on the same object.
    ///
    /// The local file is read and passed as `data:` rather than handed over as
    /// `fileURL:` for a reason beyond convenience: the SDK's `fileURL:`
    /// overload puts `url.lastPathComponent` in the multipart part's filename,
    /// which would ship the `PhotoStore` name — day and prayer and all — to a
    /// server that has no business knowing it. The `data:` overload names the
    /// part after the storage path instead.
    static func upload(filename: String, to path: String) async throws {
        guard !path.isEmpty else { throw PhotoSyncError.emptyPath }
        guard !filename.isEmpty else { throw PhotoSyncError.missingLocalPhoto(filename) }

        let localURL: URL = PhotoStore.url(for: filename)
        guard let bytes: Data = try? Data(contentsOf: localURL), !bytes.isEmpty else {
            // Undo deletes the local JPEG, and undo can beat the drain to it.
            // Permanent by construction: no later attempt will find the file.
            throw PhotoSyncError.missingLocalPhoto(filename)
        }

        let options: FileOptions = FileOptions(cacheControl: "3600",
                                               contentType: PhotoSync.contentType,
                                               upsert: false)
        let bucket: StorageFileApi = Supa.client.storage.from(SupabaseConfig.photoBucket)
        do {
            try await bucket.upload(path, data: bytes, options: options)
        } catch {
            guard PhotoSync.isAlreadyExists(error) else { throw error }
            // Already stored by an earlier attempt — the op is done.
        }
    }

    /// Fetches one object's bytes. Throws on anything but success: the caller
    /// decides whether that means "retry" or "draw the illustration instead".
    static func download(path: String) async throws -> Data {
        guard !path.isEmpty else { throw PhotoSyncError.emptyPath }
        let bucket: StorageFileApi = Supa.client.storage.from(SupabaseConfig.photoBucket)
        return try await bucket.download(path: path)
    }

    /// Retracts an object you own.
    ///
    /// Deleting the post ROW is not enough on its own — the retention sweep
    /// enumerates paths from `posts`, so an object whose row is gone would
    /// never be collected (see `CircleOp.deletePhoto`). This is the other half.
    static func delete(path: String) async throws {
        guard !path.isEmpty else { throw PhotoSyncError.emptyPath }
        let bucket: StorageFileApi = Supa.client.storage.from(SupabaseConfig.photoBucket)
        do {
            _ = try await bucket.remove(paths: [path])
        } catch {
            guard PhotoSync.isNotFound(error) else { throw error }
            // Nothing there to retract — which is the state we wanted.
        }
    }

    // MARK: - Buddy photos

    /// What is already on disk, with no network and no waiting — the answer a
    /// grid cell wants on its first render so a cached photo never flashes an
    /// illustration first.
    static func cachedBuddyPhoto(path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        return BuddyPhotoCache.image(forRemotePath: path)
    }

    /// Cache first, then one download, then the cache again.
    ///
    /// Deliberately non-throwing: a buddy photo that will not load is not an
    /// error anybody should be shown. `RemoteCircleDataSource` already draws a
    /// seeded illustration for a post with no picture, so `nil` lands on a
    /// tile that already looks finished.
    ///
    /// Downloads are coalesced per path, because the same photo legitimately
    /// appears in more than one place at once (the Today grid and the week
    /// grid), and fetching a JPEG twice to draw it twice is pure waste.
    static func buddyPhoto(path: String) async -> UIImage? {
        guard !path.isEmpty else { return nil }
        if let cached: UIImage = BuddyPhotoCache.image(forRemotePath: path) {
            return cached
        }
        guard let bytes: Data = await PhotoSync.downloads.data(for: path) else { return nil }
        return UIImage(data: bytes)
    }

    /// The coalescer also owns the cache's housekeeping — see
    /// `BuddyPhotoDownloads`.
    fileprivate static let downloads: BuddyPhotoDownloads = BuddyPhotoDownloads()

    // MARK: - Internals

    private static func isAlreadyExists(_ error: any Error) -> Bool {
        // `StorageError` is the shape the SDK produces whenever the server
        // sends a JSON error body, which Supabase Storage always does. A
        // non-JSON failure is a proxy or a transport problem — retryable, and
        // therefore correctly NOT matched here.
        guard let storage = error as? StorageError else { return false }
        return PhotoSync.isAlreadyExists(statusCode: storage.statusCode, errorCode: storage.error)
    }

    private static func isNotFound(_ error: any Error) -> Bool {
        guard let storage = error as? StorageError else { return false }
        return PhotoSync.isNotFound(statusCode: storage.statusCode, errorCode: storage.error)
    }
}

/// One download per path at a time, plus the cache's self-maintenance.
///
/// An actor rather than a lock because the state is tiny and the access is all
/// `async` anyway. It is also the only place in the photo layer that holds
/// mutable state at all — `PhotoSync` and `BuddyPhotoCache` are otherwise
/// stateless by design.
///
/// v4 DECISION: **the sweep is driven from here, not only from a lifecycle
/// hook.** A foreground hook is the right place to sweep and should still exist,
/// but a cache that only shrinks when someone remembers to call it is a cache
/// that grows forever the first time a call site is forgotten. Counting
/// downloads inside the actor that performs them costs one integer and makes
/// the bound self-enforcing.
fileprivate actor BuddyPhotoDownloads {

    /// Sweep after this many stored photos: often enough that the count cap is
    /// real, rare enough that a directory scan is nowhere near a hot path.
    private static let sweepInterval: Int = 25

    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var storesSinceSweep: Int = 0

    func data(for path: String) async -> Data? {
        if let existing: Task<Data?, Never> = inFlight[path] {
            return await existing.value
        }

        let task: Task<Data?, Never> = Task<Data?, Never> {
            let bytes: Data? = try? await PhotoSync.download(path: path)
            guard let bytes, !bytes.isEmpty else { return nil }
            BuddyPhotoCache.store(bytes, forRemotePath: path)
            return bytes
        }
        inFlight[path] = task

        let result: Data? = await task.value
        inFlight.removeValue(forKey: path)
        if result != nil {
            storesSinceSweep += 1
            if storesSinceSweep >= BuddyPhotoDownloads.sweepInterval {
                storesSinceSweep = 0
                BuddyPhotoCache.sweepEverywhere()
            }
        }
        return result
    }
}
