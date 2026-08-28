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

    // MARK: - Launch

    /// Set once the migration has run with nothing left owed. `UserDefaults`
    /// rather than `Store`: it is bookkeeping ABOUT the store, and it has to be
    /// readable before the store is trusted.
    static let migrationDoneKey: String = "v5.containerMigrationComplete"

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
    @discardableResult
    static func prepareOnLaunch(from source: URL = Store.documentsDirectory,
                                to destination: URL = Store.directory,
                                defaults: UserDefaults = .standard) -> ContainerMigration.Report {
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

        let report: ContainerMigration.Report = ContainerMigration.migrate(from: source,
                                                                           to: destination)
        if report.isComplete {
            defaults.set(true, forKey: migrationDoneKey)
        }
        return report
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
enum ContainerMigration {

    /// What one run did. `skipped` is the healthy steady state — it means the
    /// destination already had something at least as new.
    struct Report: Equatable, Sendable {
        var copied: Int = 0
        var skipped: Int = 0
        var failed: Int = 0

        /// Nothing is still owed. Only a complete run is worth remembering.
        var isComplete: Bool { failed == 0 }
    }

    /// The directories that move wholesale: your photos and the buddy cache.
    /// Both are flat by construction, so this walks one level and skips
    /// anything that is itself a directory rather than recursing into a shape
    /// that does not exist.
    static let directoryNames: [String] = [PhotoStore.directoryName, BuddyPhotoCache.directoryName]

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

    /// Merge `source` into `destination`. Safe to call any number of times.
    @discardableResult
    static func migrate(from source: URL, to destination: URL,
                        fileManager: FileManager = .default) -> Report {
        var report = Report()

        // The fallback build calls this with one directory twice. Copying a
        // file onto itself is not a thing worth finding out the hard way.
        guard !ContainerMigration.sameDirectory(source, destination) else { return report }
        guard fileManager.fileExists(atPath: source.path) else { return report }
        guard ContainerMigration.ensureDirectory(destination, fileManager: fileManager) else {
            // Nowhere to put anything. Owed, not done — the marker stays clear.
            report.failed += 1
            return report
        }

        // Documents/*.json — enumerated rather than listed from `Store`'s five
        // constants, so a file added later cannot be forgotten here.
        for name in ContainerMigration.jsonFileNames(in: source, fileManager: fileManager) {
            ContainerMigration.copyFile(named: name, from: source, to: destination,
                                        into: &report, fileManager: fileManager)
        }

        for name in ContainerMigration.directoryNames {
            let sourceDirectory: URL = source.appendingPathComponent(name, isDirectory: true)
            let contents: [String] = ContainerMigration.fileNames(in: sourceDirectory,
                                                                  fileManager: fileManager)
            guard !contents.isEmpty else { continue }

            let destinationDirectory: URL = destination.appendingPathComponent(name,
                                                                               isDirectory: true)
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

        return report
    }

    // MARK: - Internals

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

    private static func jsonFileNames(in directory: URL, fileManager: FileManager) -> [String] {
        ContainerMigration.fileNames(in: directory, fileManager: fileManager)
            .filter { $0.hasSuffix(".json") }
    }

    /// Sorted, so a report is the same on every device and a test can say what
    /// it means. Hidden files are skipped — `.DS_Store` and friends are not
    /// anybody's data.
    private static func fileNames(in directory: URL, fileManager: FileManager) -> [String] {
        guard let urls: [URL] = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return []
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
