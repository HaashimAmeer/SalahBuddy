import Foundation

/// v4: a real circle behind the `CircleDataSource` seam (SPEC-V4 §8).
///
/// Everything it answers comes from the offline `CircleSnapshot` and nothing
/// else — no network, no `Store` read, no clock. That is deliberate: the Today
/// grid, the week grid and the scoreboard must draw identically on a cold
/// launch in airplane mode as they did on the last sync, and a pure value type
/// over the mirror is the cheapest way to guarantee it. `CircleService` owns
/// refreshing the mirror; this only reads it.
///
/// It deliberately mirrors `SimulatedCircleDataSource` beat for beat — the same
/// "nothing shows before its `loggedAt`" reveal, the same `.missed`-only-once-
/// the-window-closed rule, and the same `GameEngine` calls for the week. A real
/// circle and the demo one produce the same SHAPE of answer, so the views and
/// `ChallengeEngine` cannot tell them apart.
struct RemoteCircleDataSource: CircleDataSource {

    /// The last synced mirror. An empty one is a perfectly valid circle with
    /// nobody in it — never a crash, never a fallback to demo buddies.
    let snapshot: CircleSnapshot

    init(snapshot: CircleSnapshot) {
        self.snapshot = snapshot
    }

    // MARK: - Roster

    /// `CircleSnapshot` builds these (join order, you filtered out), so there
    /// is exactly ONE place in the app that turns a remote profile into a
    /// `CircleMember`.
    var members: [CircleMember] { snapshot.buddyMembers }

    /// FRIEND slots, you excluded — `RemoteCircle.maxMembers` counts seats.
    /// The server trigger is the real cap; this only shapes the invite copy.
    var maxMembers: Int { RemoteCircle.maxFriends }

    /// A buddy's avatar is a Storage path, not a `PhotoStore` filename, so it
    /// gets its own accessor rather than riding on `CircleMember.avatarFilename`
    /// — that field means "a file this app owns", and `MemberAvatarView` only
    /// ever loads it for `isYou`. Phase C's photo cache resolves the path.
    func avatarPath(forMember id: String) -> String? {
        guard let userID = userID(forMember: id) else { return nil }
        return snapshot.profile(for: userID)?.avatarPath
    }

    /// Member ids are `CircleSnapshot`'s spelling — the bare `uuidString`.
    /// Resolves only ids this source actually speaks for: an unknown id, a
    /// stale one from someone who left, or "you" all answer nil, exactly as
    /// the simulator's unknown-buddy path does.
    ///
    /// v4: a mirror with no `me` speaks for NOBODY — without an identity your
    /// own id is indistinguishable from a buddy's, and answering for it would
    /// render your posts inside a phantom buddy row. Same call `buddyMembers`
    /// makes, so the roster and the squares always agree.
    private func userID(forMember id: String) -> UUID? {
        guard let me = snapshot.me else { return nil }
        guard let parsed = UUID(uuidString: id), parsed != me else { return nil }
        guard snapshot.isMember(userID: parsed) else { return nil }
        return parsed
    }

    // MARK: - Visibility

    /// What one square knows before it is dressed as a grid entry or a week
    /// cell. Both go through this so the Today grid and the week grid can never
    /// disagree about the same fact — the bug that would otherwise show a post
    /// in one place and a miss in the other.
    private enum Visibility {
        case posted(RemotePost)
        /// A post exists but its `loggedAt` hasn't arrived — hold the square
        /// rather than flashing "missed" and then correcting itself.
        case pending
        case excused
        case missed
        case waiting
    }

    /// v4 DECISION: a post and an excused day are checked BEFORE the window
    /// opens, which is where this deliberately parts company with
    /// `SimulatedCircleDataSource.cell` (that one hides everything until
    /// `now >= window.start`). A real post can legitimately predate its window
    /// — a travel-combined Asr is logged during Dhuhr (§3) — and hiding it
    /// would show a friend's square as empty while they can see it themselves.
    /// It matches `AppState.myCell`, which has always short-circuited on the
    /// log and on excused first, so YOUR row and a buddy's row answer alike.
    private func visibility(userID: UUID, prayer: Prayer, dayKey: String,
                            window: PrayerWindow?, now: Date) -> Visibility {
        if let post = snapshot.post(userID: userID, dayKey: dayKey, prayer: prayer, asOf: now) {
            return now >= post.loggedAt ? .posted(post) : .pending
        }
        // A resting day is gentle and whole-day: the wire carries the bare flag
        // and nothing else (§3), so there is no per-prayer partial excuse for a
        // buddy the way there is for your own row.
        if snapshot.isExcused(userID: userID, dayKey: dayKey) { return .excused }
        guard let window else { return .waiting }
        return now >= window.end ? .missed : .waiting
    }

    // MARK: - Grid

    func entry(forMember id: String, prayer: Prayer, dayKey: String,
               window: PrayerWindow?, now: Date) -> (state: GridEntryState, placeLabel: String?) {
        guard let userID = userID(forMember: id) else { return (.waiting, nil) }

        switch visibility(userID: userID, prayer: prayer, dayKey: dayKey,
                          window: window, now: now) {
        case .posted(let post):
            guard post.tier.isInWindow else { return (.qada(at: post.loggedAt), nil) }
            let content: PostContent = postContent(for: post, dayKey: dayKey, prayer: prayer)
            let label: String? = RemoteCircleDataSource.nonEmpty(post.placeLabel)
            return (.posted(content, tier: post.tier, at: post.loggedAt), label)
        case .pending, .waiting:
            return (.waiting, nil)
        case .excused:
            return (.excused, nil)
        case .missed:
            return (.missed, nil)
        }
    }

    func cell(forMember id: String, prayer: Prayer, dayKey: String,
              window: PrayerWindow?, now: Date) -> GridCellState {
        guard let userID = userID(forMember: id) else { return .future }

        switch visibility(userID: userID, prayer: prayer, dayKey: dayKey,
                          window: window, now: now) {
        case .posted(let post):
            return post.tier.isInWindow ? .inWindow(post.tier) : .qada
        case .pending, .waiting:
            return .future
        case .excused:
            return .excused
        case .missed:
            return .missed
        }
    }

    // MARK: - Photos

    /// v4 DECISION: a synced post's `photo_path` is a Storage path, and
    /// `PostContent.photo(filename:)` means "a JPEG in `PhotoStore`" everywhere
    /// it is read — handing it a path would draw an empty tile. A third
    /// `PostContent` case would break every exhaustive `switch` over it
    /// (`PhotoSquare`) for a picture this phase cannot fetch yet, so the path
    /// travels ALONGSIDE the entry instead, via `photoPath(forMember:…)`, and
    /// Phase C's buddy-photo cache (§4) is what turns it into an image.
    ///
    /// Until then a synced post draws the same seeded illustration `AppState`
    /// already draws for one of YOUR posts with no photo, so both cases
    /// `PhotoSquare` knows stay true: a tile is either a file this app owns or
    /// an illustration.
    private func postContent(for post: RemotePost, dayKey: String, prayer: Prayer) -> PostContent {
        let seed: UInt64 = BuddySimulator.seed(name: post.userID.uuidString,
                                               dayKey: dayKey, prayer: prayer)
        return .illustration(seed: seed)
    }

    /// The Storage path behind one square's photo, when the post carries one.
    /// The path is already unique (`<circle>/<user>/<uuid>.jpg`), so it is all
    /// a disk cache needs to key on.
    ///
    /// `now` is not decoration: a traveller's slot can hold two posts and the
    /// square is already drawing ONE of them. Resolving the path by the same
    /// rule at the same instant is what stops a tile showing London's tier
    /// above New York's photograph.
    func photoPath(forMember id: String, prayer: Prayer, dayKey: String,
                   asOf now: Date) -> String? {
        guard let userID = userID(forMember: id),
              let post = snapshot.post(userID: userID, dayKey: dayKey, prayer: prayer,
                                       asOf: now) else {
            return nil
        }
        return RemoteCircleDataSource.nonEmpty(post.photoPath)
    }

    /// Treats an empty string as absent — a column that came back "" must not
    /// render as a blank pill or a path to nowhere.
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - Week

    func weekLogs(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> [PrayerLog] {
        guard let userID = userID(forMember: id) else { return [] }
        let dayKeys: [String] = days.map { $0.dayKey }
        let mapped: [PrayerLog] = snapshot.prayerLogs(userID: userID, dayKeys: dayKeys)
        // The same reveal the grid uses, so a member's week and their squares
        // can never tell different stories.
        let visible: [PrayerLog] = mapped.filter { $0.loggedAt <= now }
        return visible.sorted(by: RemoteCircleDataSource.isEarlier)
    }

    /// Day, then the canonical prayer order — the order the simulator's week
    /// comes back in. `dayKey` is "yyyy-MM-dd", so a string compare IS a date
    /// compare.
    private static func isEarlier(_ lhs: PrayerLog, _ rhs: PrayerLog) -> Bool {
        if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
        let order: [Prayer] = Prayer.allCases
        let left: Int = order.firstIndex(of: lhs.prayer) ?? 0
        let right: Int = order.firstIndex(of: rhs.prayer) ?? 0
        return left < right
    }

    /// Per-day XP (perfect-day bonus included) over the member's visible week —
    /// the identical fold `BuddySimulator.weeklyXP` does, so demo and real
    /// scoreboards are the same number computed the same way. The one addition
    /// is the member's excused days, which the simulator has no concept of:
    /// they void the perfect-day bonus exactly as they do on your own row.
    func weeklyXP(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> Int {
        let logs: [PrayerLog] = weekLogs(forMember: id, days: days, asOf: now)
        let excused: Set<String> = excusedDayKeys(forMember: id)
        let dayKeys: Set<String> = Set(logs.map { $0.dayKey })
        var total = 0
        for key in dayKeys {
            total += GameEngine.xp(forDay: key, logs: logs, excusedDayKeys: excused)
        }
        return total
    }

    /// The member's rest days, straight off the mirror.
    ///
    /// v4.2: this used to be a local in `weeklyXP` alone. The crown race needs
    /// the same set — an excused day earns no perfect-day bonus in the race any
    /// more than it does in the standings — so it is answered once, here, and
    /// `weeklyXP` reads it from the same place everybody else does. An id this
    /// source doesn't speak for (unknown, departed, or "you") answers empty,
    /// exactly as every other accessor on it does.
    func excusedDayKeys(forMember id: String) -> Set<String> {
        guard let userID = userID(forMember: id) else { return [] }
        return snapshot.excusedDayKeys(userID: userID)
    }

    /// The opaque weekly dhikr/deeds total (§3) — the mirror stores one integer
    /// per week and the scoreboard never learns what earned it.
    func recoveryXP(forMember id: String, weekKeys: [String]) -> Int {
        guard let userID = userID(forMember: id) else { return 0 }
        return snapshot.recoveryXP(userID: userID, weekKeys: weekKeys)
    }
}
