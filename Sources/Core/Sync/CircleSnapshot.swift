import Foundation

/// v4: the offline-first local mirror of a real circle.
///
/// Everything the Circle/Today screens render comes from here, never straight
/// off the wire — so a cold launch in airplane mode draws the same roster,
/// grid and scoreboard as the last successful sync. `CircleService` refreshes
/// it; the views only ever read it.
///
/// Persisted through `Store` as `circle.json` with a TOLERANT decoder, exactly
/// like `UserProfile`: a snapshot written by an older build (or a newer one)
/// must still load, because the alternative is a user's circle silently
/// vanishing after an update.
struct CircleSnapshot: Codable, Equatable, Sendable {
    /// nil = not in a real circle (solo, or demo mode).
    var circle: RemoteCircle?
    /// The signed-in user's own auth id — what makes `isYou` decidable offline.
    var me: UUID?
    var profiles: [RemoteProfile]
    var members: [RemoteMember]
    var posts: [RemotePost]
    var excusedDays: [RemoteExcusedDay]
    var recoveryWeeks: [RemoteRecoveryWeek]
    var challenges: [RemoteCustomChallenge]
    var lastSyncedAt: Date?

    init(circle: RemoteCircle? = nil, me: UUID? = nil,
         profiles: [RemoteProfile] = [], members: [RemoteMember] = [],
         posts: [RemotePost] = [], excusedDays: [RemoteExcusedDay] = [],
         recoveryWeeks: [RemoteRecoveryWeek] = [],
         challenges: [RemoteCustomChallenge] = [],
         lastSyncedAt: Date? = nil) {
        self.circle = circle
        self.me = me
        self.profiles = profiles
        self.members = members
        self.posts = posts
        self.excusedDays = excusedDays
        self.recoveryWeeks = recoveryWeeks
        self.challenges = challenges
        self.lastSyncedAt = lastSyncedAt
    }

    static let empty = CircleSnapshot()

    // MARK: - Persistence

    private enum CodingKeys: String, CodingKey {
        case circle, me, profiles, members, posts
        case excusedDays, recoveryWeeks, challenges, lastSyncedAt
    }

    /// Every field is optional-with-a-default. A snapshot missing a collection
    /// a later build added decodes to an empty one rather than throwing away
    /// the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        circle = (try? c.decodeIfPresent(RemoteCircle.self, forKey: .circle)) ?? nil
        me = (try? c.decodeIfPresent(UUID.self, forKey: .me)) ?? nil
        profiles = (try? c.decodeIfPresent([RemoteProfile].self, forKey: .profiles)) ?? []
        members = (try? c.decodeIfPresent([RemoteMember].self, forKey: .members)) ?? []
        self.posts = (try? c.decodeIfPresent([RemotePost].self, forKey: .posts)) ?? []
        excusedDays = (try? c.decodeIfPresent([RemoteExcusedDay].self, forKey: .excusedDays)) ?? []
        recoveryWeeks = (try? c.decodeIfPresent([RemoteRecoveryWeek].self, forKey: .recoveryWeeks)) ?? []
        challenges = (try? c.decodeIfPresent([RemoteCustomChallenge].self, forKey: .challenges)) ?? []
        lastSyncedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)) ?? nil
    }

    static func load() -> CircleSnapshot {
        Store.load(Store.circleFile, default: .empty)
    }

    func save() {
        Store.save(self, to: Store.circleFile)
    }

    /// Leaving a circle drops the mirror entirely — the app returns to solo
    /// mode with only its own local history, which is the whole promise of §2.
    static func clear() {
        Store.delete(Store.circleFile)
    }

    // MARK: - Roster

    var hasCircle: Bool { circle != nil }

    /// Seats still free in the circle — i.e. how many more people can join,
    /// which is what the invite sheet reports. Counts TOTAL members, you
    /// included (`RemoteCircle.maxFriends` is the you-excluded view). The
    /// server trigger is the real cap; this only decides what the sheet says.
    var remainingSlots: Int {
        max(0, RemoteCircle.maxMembers - members.count)
    }

    func isMember(userID: UUID) -> Bool {
        members.contains { $0.userID == userID }
    }

    func profile(for userID: UUID) -> RemoteProfile? {
        profiles.first { $0.id == userID }
    }

    /// Join order, oldest first, with the user id as a stable tiebreak so two
    /// devices never render the roster in different orders.
    private var orderedMembers: [RemoteMember] {
        let epoch = Date(timeIntervalSince1970: 0)
        return members.sorted { (lhs: RemoteMember, rhs: RemoteMember) -> Bool in
            let left: Date = lhs.joinedAt ?? epoch
            let right: Date = rhs.joinedAt ?? epoch
            if left != right { return left < right }
            return lhs.userID.uuidString < rhs.userID.uuidString
        }
    }

    /// The whole circle as the UI's value type, you included.
    var allMembers: [CircleMember] {
        orderedMembers.map { makeMember(userID: $0.userID) }
    }

    /// Buddies only — "you" is appended by `AppState`, same as in demo mode.
    ///
    /// v4 DECISION: no identity, no circle. `me` is what makes `isYou`
    /// decidable, and a mirror that has synced membership but not yet resolved
    /// the signed-in user (a cold launch before auth returns) would otherwise
    /// hand back a roster that still contains YOU — which `AppState` then
    /// appends you on top of, double-counting you on the scoreboard, the week
    /// grid and the crown. An empty circle is the honest answer until the
    /// identity lands, and it costs one render.
    var buddyMembers: [CircleMember] {
        guard let me else { return [] }
        return orderedMembers
            .filter { $0.userID != me }
            .map { makeMember(userID: $0.userID) }
    }

    /// nil when the id isn't in this circle (a stale post from someone who left).
    func member(for userID: UUID) -> CircleMember? {
        guard isMember(userID: userID) else { return nil }
        return makeMember(userID: userID)
    }

    /// `avatarFilename` is deliberately nil: it names a `PhotoStore` file, and a
    /// buddy's avatar lives in the disposable photo cache instead (§4).
    /// `AppState` substitutes your own filename for the `isYou` member.
    private func makeMember(userID: UUID) -> CircleMember {
        let remote: RemoteProfile? = profile(for: userID)
        let isYou: Bool = (userID == me)
        let storedName: String = remote?.name ?? ""
        let name: String = storedName.isEmpty ? (isYou ? "You" : "Friend") : storedName
        let storedEmoji: String = remote?.avatarEmoji ?? ""
        let emoji: String = storedEmoji.isEmpty ? (isYou ? "😄" : "🙂") : storedEmoji
        return CircleMember(id: userID.uuidString, name: name, emoji: emoji,
                            isYou: isYou, avatarFilename: nil)
    }

    // MARK: - Posts

    // `self.posts` is spelled out below: the stored property and these lookups
    // share a base name, and being explicit keeps overload resolution trivial.
    func posts(dayKey: String, prayer: Prayer) -> [RemotePost] {
        self.posts.filter { $0.dayKey == dayKey && $0.prayer == prayer }
    }

    /// Every post this member holds for one slot, EARLIEST PRAYER FIRST.
    ///
    /// v4: a slot can hold more than one row. `utc_offset` joined the `posts`
    /// unique key in migration 20260822000300, because a long-haul flight makes
    /// two genuinely different prayers share one `day_key` — Maghrib in London
    /// and Maghrib in New York on the same local date. The mirror keeps both,
    /// exactly as the server does.
    ///
    /// Ordered by `loggedAt`, then by id, so the order is a property of the
    /// DATA. `self.posts` arrives in whatever order the last merge left it, and
    /// `upserted` re-appends a touched row at the end — a lookup that took
    /// `first` therefore silently swapped which of a traveller's two prayers a
    /// cell was drawing whenever an unrelated edit bumped `updated_at`.
    func posts(userID: UUID, dayKey: String, prayer: Prayer) -> [RemotePost] {
        self.posts
            .filter { $0.userID == userID && $0.dayKey == dayKey && $0.prayer == prayer }
            .sorted { a, b in
                a.loggedAt == b.loggedAt ? a.id.uuidString < b.id.uuidString
                                         : a.loggedAt < b.loggedAt
            }
    }

    /// The ONE post that represents this member's slot as of `now`.
    ///
    /// The rule, and it is a rule rather than an accident: the LATEST prayer
    /// that has actually happened; if none has arrived yet, the earliest one
    /// still to come (so the caller can hold the square rather than flashing
    /// "missed"). A cell therefore only ever moves FORWARD in time, and never
    /// because the array was reordered.
    ///
    /// SPEC-V4 §7 item 4 records the cross-timezone PRESENTATION question as
    /// INTENDED rather than open — a shared grid's columns mean "each member's
    /// own day", and aligning by absolute time would split somebody's day
    /// across two of them. (It was §7.3 and "open" before the section was
    /// renumbered; item 3 is now the push filter, and that one is fixed.) This
    /// does not settle that; it settles the narrower one §7 item 2 created, which is
    /// which of one member's two prayers occupies one member's one cell.
    func post(userID: UUID, dayKey: String, prayer: Prayer, asOf now: Date) -> RemotePost? {
        let slot: [RemotePost] = posts(userID: userID, dayKey: dayKey, prayer: prayer)
        return slot.last { now >= $0.loggedAt } ?? slot.first
    }

    func postsBy(userID: UUID) -> [RemotePost] {
        self.posts.filter { $0.userID == userID }
    }

    /// Synced posts as `GameEngine` inputs. This is the ONLY bridge between the
    /// wire format and the scoring layer — every leaderboard number in a real
    /// circle is `GameEngine` run over the result of this call.
    func prayerLogs(userID: UUID, dayKeys: [String]? = nil) -> [PrayerLog] {
        let mine: [RemotePost] = postsBy(userID: userID)
        guard let dayKeys else { return mine.map { $0.asPrayerLog() } }
        let wanted = Set(dayKeys)
        return mine.filter { wanted.contains($0.dayKey) }.map { $0.asPrayerLog() }
    }

    // MARK: - Excused days

    func isExcused(userID: UUID, dayKey: String) -> Bool {
        excusedDays.contains { $0.userID == userID && $0.dayKey == dayKey }
    }

    /// The set `GameEngine.weeklyXP` / `xp(forDay:)` take, so a resting day
    /// scores the same for a buddy as it does for you.
    func excusedDayKeys(userID: UUID) -> Set<String> {
        var keys: Set<String> = []
        for day in excusedDays where day.userID == userID {
            keys.insert(day.dayKey)
        }
        return keys
    }

    // MARK: - Recovery XP

    /// The opaque weekly dhikr/deeds total (§3) — a number and nothing else.
    /// Summed over `weekKeys` so a scoreboard spanning a week boundary still
    /// asks one question.
    func recoveryXP(userID: UUID, weekKeys: [String]) -> Int {
        let wanted = Set(weekKeys)
        var total = 0
        for week in recoveryWeeks where week.userID == userID && wanted.contains(week.weekKey) {
            total += max(0, week.xp)
        }
        return total
    }

    // MARK: - Challenges

    /// The circle's custom challenges in `ChallengeEngine`'s own shape.
    var customChallenges: [CustomChallenge] {
        challenges.map { $0.asCustomChallenge() }
    }
}
