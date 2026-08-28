import Foundation

/// v5 §2 — the App Group container, and the one-time move into it.
///
/// A widget is a separate process with its own sandbox: it cannot read the
/// app's Documents directory, ever. So everything the app persists moves into a
/// container both processes are entitled to, and because **every file path in
/// this app funnels through `Store.directory`** (SPEC-V5 §1), repointing that
/// one property moves the mirror, the outbox, the settings, your photos and the
/// buddy photo cache in a single edit.
///
/// Two things this type is careful about, because both are how a shared
/// container usually goes wrong:
///
/// - **The container can be absent.** `containerURL(forSecurityApplicationGroupIdentifier:)`
///   answers nil in a unit-test host with no entitlement, on CI, and in any
///   build whose provisioning profile lost the capability. That is a normal
///   answer, not a crash: `resolveDirectory` falls back to Documents, which is
///   exactly where the data already was, so a mis-provisioned build degrades to
///   the v4 app rather than to an empty one.
/// - **The move must be safe to interrupt.** A copy that dies half-way (disk
///   full, killed on launch) must be finishable next launch without losing the
///   half that landed, and without an older file overwriting a newer one. See
///   `ContainerMigration`.
enum SharedContainer {

    // MARK: - Identifiers

    /// The App Group the app claims today and the widget extension will claim
    /// in P2. Declared in `SalahBuddy.entitlements` and — the part no build can
    /// do for itself — toggled on for the App ID in the developer portal.
    static let appGroupID: String = "group.org.amacvoters.salahbuddymock"

    /// The shared keychain access group (SPEC-V5 §2: `<TeamID>.group.…`).
    ///
    /// App Groups and keychain access groups are **different entitlements** for
    /// different subsystems that happen to share a name here on purpose — one
    /// identifier is easier to keep straight than two.
    ///
    /// The entitlements file writes this as `$(AppIdentifierPrefix)group.…`,
    /// which is a build-time substitution that nothing can read back at
    /// runtime, so the resolved string is spelled out once, here. The team id is
    /// not a secret: `project.yml` has carried `DEVELOPMENT_TEAM: 852AXZ2B57`
    /// in this public repo since v4.
    static let keychainAccessGroup: String = "852AXZ2B57.group.org.amacvoters.salahbuddymock"

    /// Where every Keychain item this app wrote BEFORE v5 landed:
    /// `$(AppIdentifierPrefix)$(CFBundleIdentifier)`, resolved. With no
    /// `keychain-access-groups` entitlement at all — which is what v4 shipped —
    /// that is the default group, and the Supabase SDK named no group, so this
    /// is where the session is. `SessionKeychain` reads it from here exactly
    /// once.
    static let legacyKeychainAccessGroup: String = "852AXZ2B57.org.amacvoters.salahbuddymock"

    // MARK: - Where the data lives

    /// The group container, or nil when this build is not entitled to one.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// PURE. Which of the two homes wins.
    ///
    /// Separated from `containerURL` so the fallback — the branch that only
    /// happens on the machines where it is hardest to observe — is a function a
    /// test can call with nil.
    static func resolveDirectory(group: URL?, fallback: URL) -> URL {
        group ?? fallback
    }

    /// PURE. Every directory an ERASE has to visit, live one first.
    ///
    /// The counterpart to `resolveDirectory`, and the reason it is a separate
    /// question: reading and writing have exactly one answer, but deleting has
    /// as many as there are copies. The migration is a copy (see
    /// `ContainerMigration`), so a v4 install that updated has a full second
    /// set of files in Documents that nothing else in the app enumerates —
    /// and a delete that misses them leaves content the user believes is gone,
    /// one nil `containerURL` away from being live again.
    ///
    /// Collapses to one entry when the two are the same place, so the fallback
    /// build and the test host never do anything twice.
    static func erasableDirectories(live: URL, fallback: URL) -> [URL] {
        guard !ContainerMigration.sameDirectory(live, fallback) else { return [live] }
        return [live, fallback]
    }

    // MARK: - Launch

    /// Set once the migration has run with nothing left owed. `UserDefaults`
    /// rather than `Store`: it is bookkeeping ABOUT the store, and it has to be
    /// readable before the store is trusted.
    static let migrationDoneKey: String = "v5.containerMigrationComplete"

    /// How the photo half of the move is run.
    ///
    /// The split exists because of WHERE this is called from:
    /// `SalahBuddyApp.init()`, on the main thread, before the first frame, on
    /// the one launch immediately after an update. The five JSON files have to
    /// have arrived by the time `AppState()` reads them a few lines later, and
    /// they are small. The photo library has no such deadline and no ceiling:
    /// `photos/` never prunes (§4 — they are yours forever, they feed Memories)
    /// and `circlephotos/` runs to 400 objects, so a phone that has held a year
    /// of somebody's prayers is a few hundred megabytes of read-and-rewrite.
    /// Doing that in `init()` is how an update earns a launch watchdog kill on
    /// the one launch that has no second chance.
    ///
    /// Nothing goes missing while it is in flight: `PhotoStore.load` reads the
    /// Documents copy when the container has not got one yet, so the first
    /// launch after an update renders every photo it always did.
    enum PhotoPhase {
        /// On the calling thread — one call does the whole move and the whole
        /// report comes back in the return value. What the tests use.
        case inline
        /// On a utility queue, which sets the marker itself when it lands. What
        /// the app uses.
        case deferred
    }

    /// Move Documents into the group container, at most once, on launch.
    ///
    /// Call this **before anything reads or writes a file** — it runs from
    /// `SalahBuddyApp.init()`, which is before `AppState()` exists, because
    /// `AppState`'s own initialiser loads the profile and the logs.
    ///
    /// The marker is an optimisation, not the correctness argument: the
    /// migration underneath is idempotent and re-runnable on its own terms, and
    /// the marker only spares later launches from stat-ing a photo library that
    /// has already moved. It is therefore only set when the run finished with
    /// zero failures — a partial copy stays owed.
    ///
    /// With `photos: .deferred` the returned report covers the JSON half only,
    /// because the other half has not happened yet; it finishes on a background
    /// queue and records the marker from there.
    @discardableResult
    static func prepareOnLaunch(from source: URL = Store.documentsDirectory,
                                to destination: URL = Store.directory,
                                defaults: UserDefaults = .standard,
                                photos: PhotoPhase = .deferred) -> ContainerMigration.Report {
        // No container: Documents IS the home, there is nothing to move, and —
        // the part that matters — nothing to REMEMBER. Writing the marker here
        // would strand the data in Documents forever, because the next launch
        // (correctly provisioned, container present) would read the marker and
        // skip the only run that had any work to do.
        guard !ContainerMigration.sameDirectory(source, destination) else {
            return ContainerMigration.Report()
        }
        guard !defaults.bool(forKey: migrationDoneKey) else {
            return ContainerMigration.Report()
        }

        let documents: ContainerMigration.Report = ContainerMigration.migrateDocuments(
            from: source, to: destination)

        switch photos {
        case .inline:
            let whole: ContainerMigration.Report = documents.adding(
                ContainerMigration.migratePhotos(from: source, to: destination))
            SharedContainer.remember(whole, in: defaults)
            return whole
        case .deferred:
            Task.detached(priority: .utility) {
                let whole: ContainerMigration.Report = documents.adding(
                    ContainerMigration.migratePhotos(from: source, to: destination))
                SharedContainer.remember(whole, in: defaults)
            }
            return documents
        }
    }

    /// The marker is set in exactly one place, and only for a run that finished
    /// both halves with nothing owed.
    private static func remember(_ report: ContainerMigration.Report,
                                 in defaults: UserDefaults) {
        guard report.isComplete else { return }
        defaults.set(true, forKey: migrationDoneKey)
    }
}

// MARK: - The migration

/// The one-time copy of `Documents/` into the group container.
///
/// Written as a merge rather than a directory copy, and that is the whole
/// design. `FileManager.copyItem` refuses a destination that already exists, so
/// the obvious implementation works exactly once and then fails forever; and
/// deleting the destination first opens a window where a crash loses the data.
/// This walks the items instead, decides each one on its own, and writes
/// atomically — so a run that dies half-way leaves every file it did copy
/// intact and every file it did not still sitting in the source.
///
/// **The rule for each item: copy if the destination is missing, or if the
/// source is meaningfully newer** (`newerBy`). Never the other way round. That
/// is what makes a second run a no-op — the copy carries the source's
/// modification date over, so afterwards neither side is newer — and what stops
/// a build that fell back to Documents for a while from later stamping its
/// stale copy over the group container's live one.
///
/// Modification dates are **preserved deliberately**, not incidentally:
/// `BuddyPhotoCache` ages cached buddy photos from their file date and sweeps at
/// 30 days to match the server's retention (SPEC-V5 §7). Restamping them to
/// "now" would silently grant every cached photo another month of life on a
/// device — a local copy outliving the original, which is the one thing §4 of
/// SPEC-V4 forbids.
///
/// **A copy, with one exception.** Documents keeps your JSON and your photos,
/// because a build that later loses the entitlement falls back there and has to
/// find something. `circlephotos/` is deleted from the source as soon as it has
/// landed (`disposableDirectoryNames`) — it holds other people's faces on a
/// 30-day clock, and a second copy nothing enumerates is a photo the poster
/// believes is gone. What Documents does keep is reachable from every erasure
/// path in the app, via `Store.allDirectories`; that is the other half of this
/// design and it does not work without it.
enum ContainerMigration {

    /// What one run did. `skipped` is the healthy steady state — it means the
    /// destination already had something at least as new.
    struct Report: Equatable, Sendable {
        var copied: Int = 0
        var skipped: Int = 0
        var failed: Int = 0

        /// Nothing is still owed. Only a complete run is worth remembering.
        var isComplete: Bool { failed == 0 }

        /// The two halves of one run, added up — the JSON files that move
        /// before the first frame and the photos that move after it.
        func adding(_ other: Report) -> Report {
            Report(copied: copied + other.copied,
                   skipped: skipped + other.skipped,
                   failed: failed + other.failed)
        }
    }

    /// The directories that move wholesale: your photos and the buddy cache.
    /// Both are flat by construction, so this walks one level and skips
    /// anything that is itself a directory rather than recursing into a shape
    /// that does not exist.
    static let directoryNames: [String] = [PhotoStore.directoryName, BuddyPhotoCache.directoryName]

    /// The directory whose SOURCE copy is deleted the moment it has landed.
    ///
    /// Your own photos stay in Documents on purpose — a build that later loses
    /// the entitlement falls back there and has to find something. A buddy
    /// photo has no such argument: it is not yours, and SPEC-V4 §4 makes it
    /// "cheap to lose, wrong to keep" by construction. Leaving a second copy in
    /// a directory that no sweep, no report-hide and no leaving-the-circle path
    /// enumerates would mean up to 400 faces outliving the 30-day retention
    /// they mirror — exactly the state SPEC-V5 §7 forbids, reached with no
    /// user action at all.
    ///
    /// Deleted only after every file in it copied with zero failures, so a run
    /// that ran out of disk still has its source to finish from.
    static let disposableDirectoryNames: Set<String> = [BuddyPhotoCache.directoryName]

    /// How much newer the source has to be before it counts as newer at all.
    ///
    /// A file's modification date round-trips through a `timespec` and a
    /// `Double` on the way in and out of the filesystem, so "the same instant"
    /// is only ever the same to within a rounding error — and a second run that
    /// re-copied the whole photo library because of one nanosecond would defeat
    /// the entire idempotency argument. Here, "newer" always means minutes or
    /// days: the source is a frozen v4 snapshot and the destination is either
    /// missing or live.
    static let newerBy: TimeInterval = 1

    /// PURE. May `source` be written over `destination`?
    ///
    /// The three arguments are separate on purpose. "The destination has no
    /// modification date" and "there is no destination" are different facts,
    /// and collapsing them would make an existing file with an unreadable date
    /// look like an absent one — i.e. would overwrite it. When either date is
    /// unknown and something is already there, the answer is no: keeping a file
    /// that might be newer costs nothing, and clobbering one is permanent.
    static func shouldCopy(source: Date?, destination: Date?, destinationExists: Bool) -> Bool {
        guard destinationExists else { return true }
        guard let source, let destination else { return false }
        return source.timeIntervalSince(destination) > ContainerMigration.newerBy
    }

    /// PURE. Do these two URLs name the same directory?
    ///
    /// Compared as standardized PATHS rather than as `URL`s, because the same
    /// directory has several equal-but-unequal spellings — with and without a
    /// trailing slash, with a `.` component — and the one place this is asked
    /// is the fallback build, where getting it wrong means copying a whole
    /// photo library onto itself.
    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    /// Merge `source` into `destination`, both halves. Safe to call any number
    /// of times.
    ///
    /// The app never calls this: `SharedContainer.prepareOnLaunch` runs the two
    /// halves separately so the photo library does not sit in front of the
    /// first frame. This is the whole move in one call, for the tests and for
    /// anyone reading the two halves as one thing.
    @discardableResult
    static func migrate(from source: URL, to destination: URL,
                        fileManager: FileManager = .default) -> Report {
        ContainerMigration.migrateDocuments(from: source, to: destination,
                                            fileManager: fileManager)
            .adding(ContainerMigration.migratePhotos(from: source, to: destination,
                                                     fileManager: fileManager))
    }

    /// The half that has a deadline: `Documents/*.json`, which `AppState()`
    /// reads moments later. Five small files.
    @discardableResult
    static func migrateDocuments(from source: URL, to destination: URL,
                                 fileManager: FileManager = .default) -> Report {
        var report = Report()
        guard ContainerMigration.isReady(from: source, to: destination,
                                         fileManager: fileManager, report: &report) else {
            return report
        }

        // Enumerated rather than listed from `Store`'s five constants, so a
        // file added later cannot be forgotten here.
        guard let names: [String] = ContainerMigration.jsonFileNames(
                in: source, fileManager: fileManager) else {
            // Documents is there and will not say what is in it. Nothing moved
            // — and, the part that matters, nothing may be recorded as done.
            report.failed += 1
            return report
        }
        for name in names {
            ContainerMigration.copyFile(named: name, from: source, to: destination,
                                        into: &report, fileManager: fileManager)
        }
        return report
    }

    /// The half with no deadline and no ceiling: `photos/` and
    /// `circlephotos/`. Runs off the main thread in the app (see
    /// `SharedContainer.PhotoPhase`).
    @discardableResult
    static func migratePhotos(from source: URL, to destination: URL,
                              fileManager: FileManager = .default) -> Report {
        var report = Report()
        guard ContainerMigration.isReady(from: source, to: destination,
                                         fileManager: fileManager, report: &report) else {
            return report
        }

        for name in ContainerMigration.directoryNames {
            let sourceDirectory: URL = source.appendingPathComponent(name, isDirectory: true)
            // Absent is not owed: a solo user has never had a `circlephotos/`,
            // and a finished run has already taken it away.
            guard fileManager.fileExists(atPath: sourceDirectory.path) else { continue }
            guard let contents: [String] = ContainerMigration.fileNames(
                    in: sourceDirectory, fileManager: fileManager) else {
                report.failed += 1
                continue
            }

            let failedBefore: Int = report.failed
            if !contents.isEmpty {
                let destinationDirectory: URL = destination.appendingPathComponent(
                    name, isDirectory: true)
                guard ContainerMigration.ensureDirectory(destinationDirectory,
                                                         fileManager: fileManager) else {
                    report.failed += contents.count
                    continue
                }
                for file in contents {
                    ContainerMigration.copyFile(named: file, from: sourceDirectory,
                                                to: destinationDirectory,
                                                into: &report, fileManager: fileManager)
                }
            }

            // Everything landed, so the disposable half of the source goes —
            // see `disposableDirectoryNames`. A file that failed leaves the
            // whole directory alone: the source is the only thing the next
            // launch can finish from.
            if ContainerMigration.disposableDirectoryNames.contains(name),
               report.failed == failedBefore {
                try? fileManager.removeItem(at: sourceDirectory)
            }
        }

        return report
    }

    // MARK: - Internals

    /// The three questions both halves ask before touching anything: is this
    /// really two directories, is there a source at all, and can the
    /// destination be made. A `false` with `failed` bumped means owed; a
    /// `false` without one means there was nothing to do.
    private static func isReady(from source: URL, to destination: URL,
                                fileManager: FileManager, report: inout Report) -> Bool {
        // The fallback build calls this with one directory twice. Copying a
        // file onto itself is not a thing worth finding out the hard way.
        guard !ContainerMigration.sameDirectory(source, destination) else { return false }
        guard fileManager.fileExists(atPath: source.path) else { return false }
        guard ContainerMigration.ensureDirectory(destination, fileManager: fileManager) else {
            // Nowhere to put anything. Owed, not done — the marker stays clear.
            report.failed += 1
            return false
        }
        return true
    }

    /// One item, decided and copied. Anything the source does not actually have
    /// as a plain file is not this function's business and is not an error.
    private static func copyFile(named name: String, from source: URL, to destination: URL,
                                 into report: inout Report, fileManager: FileManager) {
        let from: URL = source.appendingPathComponent(name)
        let to: URL = destination.appendingPathComponent(name)

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: from.path, isDirectory: &sourceIsDirectory),
              !sourceIsDirectory.boolValue else { return }

        let destinationExists: Bool = fileManager.fileExists(atPath: to.path)
        let sourceDate: Date? = ContainerMigration.modificationDate(of: from,
                                                                    fileManager: fileManager)
        guard ContainerMigration.shouldCopy(
                source: sourceDate,
                destination: ContainerMigration.modificationDate(of: to, fileManager: fileManager),
                destinationExists: destinationExists) else {
            report.skipped += 1
            return
        }

        do {
            // Bytes rather than `copyItem`, for two reasons that both bite:
            // `copyItem` fails outright when the destination exists, and
            // `Data.write(options: .atomic)` gives the write-to-a-sidecar-then-
            // rename that keeps a killed launch from leaving a truncated file
            // where a whole one used to be.
            let bytes: Data = try Data(contentsOf: from)
            try bytes.write(to: to, options: .atomic)
            if let sourceDate {
                // The atomic write stamps "now"; put the original date back, or
                // every cached buddy photo silently resets its 30-day clock.
                try? fileManager.setAttributes([.modificationDate: sourceDate],
                                               ofItemAtPath: to.path)
            }
            report.copied += 1
        } catch {
            // Owed, not lost: the source is untouched and the next launch tries
            // again, because a run with failures never sets the marker.
            report.failed += 1
        }
    }

    private static func jsonFileNames(in directory: URL, fileManager: FileManager) -> [String]? {
        ContainerMigration.fileNames(in: directory, fileManager: fileManager)?
            .filter { $0.hasSuffix(".json") }
    }

    /// Sorted, so a report is the same on every device and a test can say what
    /// it means. Hidden files are skipped — `.DS_Store` and friends are not
    /// anybody's data.
    ///
    /// **Nil is not the empty list.** "This directory would not say what is in
    /// it" and "this directory is empty" are different facts, and collapsing
    /// them is how a migration that moved nothing gets recorded as done: an
    /// unreadable Documents would answer `[]`, produce a clean `Report()`, set
    /// the marker, and strand every file it never looked at. Everything else
    /// here is careful to keep owed and done apart; so is this.
    private static func fileNames(in directory: URL, fileManager: FileManager) -> [String]? {
        guard let urls: [URL] = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return nil
        }
        return urls.map(\.lastPathComponent).sorted()
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        let attributes: [FileAttributeKey: Any]? = try? fileManager.attributesOfItem(
            atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// True when `url` is a directory afterwards, whether we made it or found
    /// it. A plain FILE sitting where a directory belongs answers false rather
    /// than throwing a copy at it.
    @discardableResult
    private static func ensureDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
