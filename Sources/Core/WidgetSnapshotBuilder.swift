import Foundation

/// v5 §3 — how a `WidgetSnapshot` is made. PURE, in the `GameEngine` sense:
/// no clock, no disk, no singletons, every input passed in explicitly.
///
/// It lives in the APP target and deliberately not in `Sources/Shared`, so the
/// extension cannot compile it even by accident. The widget re-derives nothing;
/// this is the deriving, and it happens once, on the side of the fence that
/// already knows the schedule, the mirror and the roster.
///
/// The `entries` it folds are `AppState.gridEntries` — the SAME call the Today
/// grid makes, through the same `CircleDataSource` seam. That is what §9-03
/// asks for: a demo circle and a real one reach the home screen along one path,
/// so a simulated buddy and a real friend cannot render differently, because by
/// the time this function sees them they are the same value.
enum WidgetSnapshotBuilder {

    // MARK: - Which window

    /// The window the home screen is about: the one open right now, else the
    /// next one to open.
    ///
    /// `carryOver` is yesterday's isha while it is still live — it ends at
    /// TODAY's fajr, so between midnight and fajr the window a person is
    /// standing in belongs to yesterday's schedule day (`dayKey` is the
    /// SCHEDULE day, not the calendar one). `AppState` decides whether that
    /// block is still live, because that answer also depends on whether it has
    /// been logged; this only asks whether the clock is inside it.
    ///
    /// The fall-through to the LAST window matters: after a schedule has gone
    /// stale (an app that has not been opened since yesterday) every window is
    /// closed, and "the day's last one, closed" is a truthful thing to draw.
    /// nil is reserved for having no schedule at all.
    static func window(in schedule: DaySchedule?,
                       carryOver: (window: PrayerWindow, dayKey: String)?,
                       now: Date) -> (window: PrayerWindow, dayKey: String)? {
        if let carryOver, now >= carryOver.window.start, now < carryOver.window.end {
            return carryOver
        }
        guard let schedule else { return carryOver }
        let windows: [PrayerWindow] = schedule.windows
        if let open = windows.first(where: { now >= $0.start && now < $0.end }) {
            return (open, schedule.dayKey)
        }
        if let next = windows.filter({ now < $0.start }).min(by: { $0.start < $1.start }) {
            return (next, schedule.dayKey)
        }
        guard let last = windows.max(by: { $0.end < $1.end }) else { return carryOver }
        return (last, schedule.dayKey)
    }

    // MARK: - Who can be nudged (SPEC-V5 §3/§4)

    /// How long a window has to have been open before the people still in it
    /// count as outstanding.
    ///
    /// v3.6's rule, and it lives here so the home screen and the Today screen
    /// cannot offer different nudges: `TodayBlocks.nudgeEligible` reads this
    /// same number. Praying five minutes into Asr is not late, and a push that
    /// says otherwise is the fastest way to make somebody delete a widget.
    static let nudgeGrace: TimeInterval = 30 * 60

    /// Whether this window's still-empty friends are nudge targets YET.
    ///
    /// `waiting` is not "everyone who has not posted" — §3 calls it the nudge
    /// list and P4's button spends it verbatim, so it carries the app's own
    /// gate rather than a looser one. Three conditions, all of them the Today
    /// screen's (`TodayBlocks.nudgeRow`):
    ///
    /// 1. **The window is OPEN.** `window(in:carryOver:now:)` deliberately
    ///    answers the NEXT window when nothing is open, because the tile still
    ///    has to say "Dhuhr, opens 1:00 PM". Naming three people as outstanding
    ///    for a prayer whose time has not come in is a different claim, and a
    ///    wrong one.
    /// 2. **Thirty minutes in** (`nudgeGrace`).
    /// 3. **Not the carry-over isha.** Between midnight and fajr the live
    ///    window belongs to yesterday; the app refuses to nudge there
    ///    (`!block.isYesterdayIsha`) and so does this — 1 AM is nobody's
    ///    reminder hour.
    ///
    /// A person who is merely still to pray remains visible in the counts —
    /// "2 of 5 prayed" is true from the first second of the window.
    static func nudgesAllowed(window: PrayerWindow?, isCarryOver: Bool, now: Date) -> Bool {
        guard let window, !isCarryOver else { return false }
        guard now < window.end else { return false }
        return now >= window.start.addingTimeInterval(nudgeGrace)
    }

    // MARK: - Photos (SPEC-V5 §7, reports)

    /// The `thumb` a post gets: the buddy-photo cache key for its Storage path,
    /// or nil.
    ///
    /// **This is where §7's report invariant is enforced.** A photo this device
    /// has reported is hidden in the app by `PhotoReports`, which keeps a set of
    /// paths on disk rather than editing the mirror (the mirror is rewritten by
    /// every pull, so an edit there would not survive one). The home screen is a
    /// second surface for the same bytes, and the hide has to reach it: a photo
    /// somebody reported reappearing on their home screen is worse than never
    /// having offered the report at all. Applying it HERE — as the file is
    /// written — means the widget never learns the name of a hidden photo, so
    /// there is nothing for a stale timeline, a cached render or a future
    /// version of the extension to get wrong.
    ///
    /// The value is a `BuddyPhotoCache` key, not a path: the widget shares the
    /// container and therefore the cache, and §7 is explicit that there is never
    /// a widget-only photo store. P3 writes the ~300px thumbnail under this same
    /// key and renders it; P2 writes the name and draws none of them.
    static func thumb(forPhotoPath path: String?, hiddenPaths: Set<String>) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard !hiddenPaths.contains(path) else { return nil }
        return BuddyPhotoCache.key(forRemotePath: path)
    }

    // MARK: - The snapshot

    /// Fold one window's grid entries into the file the widget reads.
    ///
    /// - Parameters:
    ///   - writtenAt: `AppClock.now`. It is the file's timestamp AND the
    ///     moment every time-dependent decision here is made against — there
    ///     is no clock in this file to read instead, which is the point.
    ///   - entries: `AppState.gridEntries` for this window — buddies through
    ///     the seam, you last.
    ///   - isCarryOverWindow: whether `window` is yesterday's isha, still open
    ///     before today's fajr. Only `AppState` can tell (the tuple carries a
    ///     dayKey, not a provenance), and only the nudge gate cares.
    ///   - photoPaths: member id → the Storage path behind that member's post,
    ///     from `CircleDataSource.photoPath`. Absent for demo buddies (their
    ///     posts are seeded illustrations) and for you.
    ///   - nudgedMemberIDs: who has already been nudged for this window.
    ///   - hiddenPhotoPaths: `PhotoReports.hiddenPaths`. See `thumb`.
    static func make(writtenAt: Date,
                     mode: CircleMode,
                     streak: Int,
                     window: (window: PrayerWindow, dayKey: String)?,
                     entries: [GridEntry],
                     isCarryOverWindow: Bool = false,
                     photoPaths: [String: String] = [:],
                     nudgedMemberIDs: Set<String> = [],
                     hiddenPhotoPaths: Set<String> = []) -> WidgetSnapshot {

        var posts: [WidgetSnapshot.Post] = []
        var waiting: [WidgetSnapshot.Waiting] = []
        var prayedCount: Int = 0
        var youLogged: Bool = false
        let canNudge: Bool = nudgesAllowed(window: window?.window,
                                           isCarryOver: isCarryOverWindow,
                                           now: writtenAt)

        for entry in entries {
            let member: CircleMember = entry.member
            switch entry.state {
            case .posted(_, let tier, let at):
                prayedCount += 1
                youLogged = youLogged || member.isYou
                posts.append(post(member: member, tier: tier, at: at,
                                  photoPaths: photoPaths, hiddenPhotoPaths: hiddenPhotoPaths))
            case .qada(let at):
                // A make-up is still a prayer prayed, so it counts and it shows.
                // Its own tier says which it was.
                prayedCount += 1
                youLogged = youLogged || member.isYou
                posts.append(post(member: member, tier: .qada, at: at,
                                  photoPaths: photoPaths, hiddenPhotoPaths: hiddenPhotoPaths))
            case .waiting:
                // A nudge target is somebody whose window has been OPEN long
                // enough to be late in, and is still empty (`canNudge`, above —
                // the seams answer `.waiting` for a window that has not opened
                // yet, which is a person with nothing to answer for). You are
                // never one (`.isYou`), and neither is a person resting —
                // `.excused` falls through below, and it must, because §7's
                // break flag exists to be gentle with and a nudge is the
                // opposite of gentle.
                guard canNudge, !member.isYou else { continue }
                waiting.append(WidgetSnapshot.Waiting(
                    userID: member.id,
                    name: displayName(member),
                    emoji: member.emoji,
                    nudgedThisWindow: nudgedMemberIDs.contains(member.id)))
            case .missed, .excused:
                continue
            }
        }

        // Newest first (§3), with the name as a stable tiebreak so two devices
        // holding the same second never disagree about the order.
        posts.sort { left, right in
            left.loggedAt == right.loggedAt ? left.name < right.name
                                            : left.loggedAt > right.loggedAt
        }
        if posts.count > WidgetSnapshot.postCap {
            posts = Array(posts.prefix(WidgetSnapshot.postCap))
        }

        let shape: WidgetSnapshot.Window? = window.map {
            WidgetSnapshot.Window(prayer: $0.window.prayer, dayKey: $0.dayKey,
                                  opensAt: $0.window.start, endsAt: $0.window.end)
        }
        return WidgetSnapshot(
            writtenAt: writtenAt,
            mode: mode,
            window: shape,
            you: WidgetSnapshot.You(logged: youLogged, streak: streak),
            circle: WidgetSnapshot.Circle(prayedCount: prayedCount,
                                          memberCount: entries.count,
                                          posts: posts,
                                          waiting: waiting))
    }

    // MARK: - Helpers

    private static func post(member: CircleMember, tier: LogTier, at: Date,
                             photoPaths: [String: String],
                             hiddenPhotoPaths: Set<String>) -> WidgetSnapshot.Post {
        // Your own square draws a `PhotoStore` file, which is a different store
        // with a different lifetime (SPEC-V4 §4) and no cache key. It stays out
        // of `thumb` until P3 decides how your own photo reaches the extension.
        let path: String? = member.isYou ? nil : photoPaths[member.id]
        return WidgetSnapshot.Post(name: displayName(member),
                                   emoji: member.emoji,
                                   tier: tier,
                                   loggedAt: at,
                                   thumb: thumb(forPhotoPath: path,
                                                hiddenPaths: hiddenPhotoPaths))
    }

    /// A name the home screen can print. `CircleSnapshot` already substitutes
    /// "You"/"Friend" for an empty profile name; this covers the demo and
    /// "you" paths, which build their members by hand.
    private static func displayName(_ member: CircleMember) -> String {
        let trimmed: String = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return member.isYou ? "You" : "Friend"
    }
}
