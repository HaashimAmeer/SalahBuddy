import Foundation

// MARK: - Remote DTOs (v4)
//
// One struct per Postgres table in `backend/supabase/migrations/`, mapped 1:1.
//
// TWO rules govern every type in this file:
//
// 1. **Explicit CodingKeys, always.** PostgREST's coder does NOT convert key
//    casing, so a camelCase property silently misses its snake_case column.
//    Every key below is spelled out rather than synthesised.
// 2. **Server-managed columns are decoded but NEVER encoded.** `created_at` /
//    `updated_at` / `joined_at` have DB defaults, and the natural round trip
//    (fetch a row, edit a field, upsert it back) would otherwise write the
//    value the server sent us — or a stale one from a wrong device clock —
//    straight back over the server's own. They are read-only mirrors of the
//    row, so the write side simply leaves them out and the DB default wins.
//    The ONE exception is `RemoteMember.joinedAt` — see the note on its
//    `encode(to:)`: that encoder can only ever write `circle.json`.
//    Nil optionals the client DOES own are omitted rather than sent as null,
//    which would try to write null into a NOT NULL column. Both rules are why
//    every DTO hand-writes `encode(to:)` instead of relying on synthesis.
//
// `Prayer` and `LogTier` are reused as-is: their rawValues ARE the Postgres
// enum labels (`prayer_kind`, `log_tier`), which the migration documents. If
// one side ever drifts, decoding fails loudly here rather than scoring wrongly.

// MARK: - profiles

struct RemoteProfile: Codable, Equatable, Sendable {
    var id: UUID                // = auth.users.id
    var name: String
    var avatarEmoji: String?
    var avatarPath: String?     // Storage path, NOT a PhotoStore filename
    var memberKind: String?     // "brother" / "sister" — mirrors AppSettings.memberKind
    var createdAt: Date?
    var updatedAt: Date?

    init(id: UUID, name: String, avatarEmoji: String? = nil, avatarPath: String? = nil,
         memberKind: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.avatarPath = avatarPath
        self.memberKind = memberKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarEmoji = "avatar_emoji"
        case avatarPath = "avatar_path"
        case memberKind = "member_kind"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        avatarEmoji = try c.decodeIfPresent(String.self, forKey: .avatarEmoji)
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        memberKind = try c.decodeIfPresent(String.self, forKey: .memberKind)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(avatarEmoji, forKey: .avatarEmoji)
        try c.encodeIfPresent(avatarPath, forKey: .avatarPath)
        try c.encodeIfPresent(memberKind, forKey: .memberKind)
        // created_at / updated_at deliberately absent — see rule 2. `profiles`
        // is the one table the client upserts directly, so re-sending the
        // fetched `updated_at` is exactly how a stale value would win.
    }
}

// MARK: - circles

struct RemoteCircle: Codable, Equatable, Sendable {
    var id: UUID
    var code: String            // the 6-character invite code
    var name: String
    var emoji: String
    var createdBy: UUID?        // nullable: `on delete set null` when the creator leaves
    var createdAt: Date?

    /// 8 MEMBERS TOTAL, not 8 friends + you. Mirrors `public.circle_max_members()`;
    /// the server trigger is the real enforcement, this is only for the invite UI.
    static let maxMembers = 8

    /// The same cap counted the way `CircleDataSource.maxMembers` counts it —
    /// FRIENDS, with you excluded. Spelled out because the off-by-one between
    /// "seats in the circle" and "friends you can add" is the easy bug here.
    static var maxFriends: Int { maxMembers - 1 }

    init(id: UUID, code: String, name: String = "Your Circle", emoji: String = "🤝",
         createdBy: UUID? = nil, createdAt: Date? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.emoji = emoji
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case name
        case emoji
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Your Circle"
        emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🤝"
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(code, forKey: .code)
        try c.encode(name, forKey: .name)
        try c.encode(emoji, forKey: .emoji)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        // created_at is the server's (rule 2): renaming a circle must not
        // rewrite the day it was founded.
    }
}

// MARK: - circle_members

struct RemoteMember: Codable, Equatable, Sendable {
    var circleID: UUID
    var userID: UUID
    var joinedAt: Date?

    init(circleID: UUID, userID: UUID, joinedAt: Date? = nil) {
        self.circleID = circleID
        self.userID = userID
        self.joinedAt = joinedAt
    }

    enum CodingKeys: String, CodingKey {
        case circleID = "circle_id"
        case userID = "user_id"
        case joinedAt = "joined_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        userID = try c.decode(UUID.self, forKey: .userID)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
    }

    /// Rule 2's one exception, and the grant is why it is safe: `authenticated`
    /// holds only `select, delete` on `circle_members` — the row is inserted by
    /// `create_circle` / `join_circle`, server-side — so this encoder can never
    /// reach the wire. It writes `circle.json` and nothing else, and the mirror
    /// MUST keep `joined_at`: it is what orders the roster, so dropping it here
    /// re-sorts everybody by raw uuid on the next cold launch.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(joinedAt, forKey: .joinedAt)
    }
}

// MARK: - posts

/// The shareable fact of a logged prayer (SPEC-V4 §3). Deliberately carries no
/// XP: scoring stays in `GameEngine`, so every client re-derives the same
/// number from the same facts.
struct RemotePost: Codable, Equatable, Sendable, Identifiable {
    var id: UUID                // client-generated — the same UUID as the local PrayerLog
    var userID: UUID
    var circleID: UUID
    var dayKey: String          // the CLIENT's schedule day; never re-derived from loggedAt
    var prayer: Prayer
    var tier: LogTier
    var loggedAt: Date
    var jamaat: Bool
    var placeLabel: String?     // the rendered pill ("🏠 Home"), not the raw tag
    var photoPath: String?      // Storage path; nil once retention ages the photo out
    var travelCombined: Bool

    /// The SERVER's `updated_at`, decoded and never encoded (rule 2).
    ///
    /// v4 Phase C DECISION: this is the delta cursor's source of truth. A delta
    /// asks PostgREST for `updated_at > <cursor>`, and `updated_at` is stamped
    /// by `now()` inside Postgres — so a cursor taken from THIS device's clock
    /// is being compared against a clock that is not this device's. A phone
    /// running a minute fast (a hand-set clock, or an RTC restored before NTP
    /// catches up) would ask for rows from the server's future and get an empty
    /// page every single time, silently, forever. Carrying the server's own
    /// stamp back as the next cursor removes the comparison between clocks
    /// entirely. Nil for a row this device built rather than read.
    var updatedAt: Date?

    init(id: UUID, userID: UUID, circleID: UUID, dayKey: String, prayer: Prayer,
         tier: LogTier, loggedAt: Date, jamaat: Bool = false,
         placeLabel: String? = nil, photoPath: String? = nil,
         travelCombined: Bool = false, updatedAt: Date? = nil) {
        self.id = id
        self.userID = userID
        self.circleID = circleID
        self.dayKey = dayKey
        self.prayer = prayer
        self.tier = tier
        self.loggedAt = loggedAt
        self.jamaat = jamaat
        self.placeLabel = placeLabel
        self.photoPath = photoPath
        self.travelCombined = travelCombined
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case circleID = "circle_id"
        case dayKey = "day_key"
        case prayer
        case tier
        case loggedAt = "logged_at"
        case jamaat
        case placeLabel = "place_label"
        case photoPath = "photo_path"
        case travelCombined = "travel_combined"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userID = try c.decode(UUID.self, forKey: .userID)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        prayer = try c.decode(Prayer.self, forKey: .prayer)
        tier = try c.decode(LogTier.self, forKey: .tier)
        loggedAt = try c.decode(Date.self, forKey: .loggedAt)
        jamaat = (try? c.decodeIfPresent(Bool.self, forKey: .jamaat)) ?? false
        placeLabel = try c.decodeIfPresent(String.self, forKey: .placeLabel)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        travelCombined = (try? c.decodeIfPresent(Bool.self, forKey: .travelCombined)) ?? false
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
    }

    /// `created_at` / `updated_at` are intentionally absent: they are server
    /// defaults, and sending them would let a wrong device clock win. That is
    /// also why `updatedAt` is decode-only above — it is read as the delta
    /// cursor and never written back.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(dayKey, forKey: .dayKey)
        try c.encode(prayer, forKey: .prayer)
        try c.encode(tier, forKey: .tier)
        try c.encode(loggedAt, forKey: .loggedAt)
        try c.encode(jamaat, forKey: .jamaat)
        try c.encodeIfPresent(placeLabel, forKey: .placeLabel)
        try c.encodeIfPresent(photoPath, forKey: .photoPath)
        try c.encode(travelCombined, forKey: .travelCombined)
    }

    /// A synced post, as `GameEngine` sees it. This is the whole trick behind
    /// "no second scoring implementation": a buddy's week is scored by the
    /// exact same pure functions as your own.
    ///
    /// - `photoFilename` is ALWAYS nil — buddy photos live in the disposable
    ///   `Documents/circlephotos/` cache keyed by `photoPath`, never in
    ///   `PhotoStore`, which is yours forever (§4).
    /// - `placeTag`/`placeName` stay nil: the wire carries only the rendered
    ///   label, and the tag matters solely for your own Journey "Places" stats.
    func asPrayerLog() -> PrayerLog {
        return PrayerLog(id: id, prayer: prayer, dayKey: dayKey, loggedAt: loggedAt,
                         tier: tier, xp: postedXP, photoFilename: nil, jamaat: jamaat,
                         placeTag: nil, placeName: nil)
    }

    /// What `GameEngine` says this post is worth — run here so a buddy's row is
    /// scored by the same pure functions as your own.
    ///
    /// v4 Phase C FIX: a `.qada` post is NOT flatly worth `LogTier.qada.xp`.
    /// `AppState.logPastMakeUp` scores a retroactive make-up with
    /// `GameEngine.lateEditXP`, which pays 5 inside the 2-day grace and **0**
    /// after it — same-day logging stays the incentive. Re-deriving a flat 5
    /// here made every OTHER device score a stale make-up five points higher
    /// than the device that made it, so the two leaderboards disagreed about
    /// the same person for the rest of the week.
    ///
    /// It stays clock-free: the "today" the rule needs is the day the EDIT was
    /// made, which is `logged_at` — already on the wire, and the same value the
    /// poster's own device used. A same-day qada and an isha-after-midnight
    /// qada both still come out at 5, which is what the local paths produce.
    private var postedXP: Int {
        guard tier == .qada else { return GameEngine.prayerXP(tier: tier, jamaat: jamaat) }
        return GameEngine.lateEditXP(dayKey: dayKey, todayKey: AppClock.dayKey(for: loggedAt))
    }

    /// The other direction, kept here so there is exactly one mapping in the
    /// app. `placeLabel` is passed in already rendered (`AppState.placeLabel`)
    /// and `travelCombined` by the caller, because a `PrayerLog` alone doesn't
    /// know it was half of a travel pair.
    static func from(log: PrayerLog, userID: UUID, circleID: UUID,
                     placeLabel: String? = nil, photoPath: String? = nil,
                     travelCombined: Bool = false) -> RemotePost {
        RemotePost(id: log.id, userID: userID, circleID: circleID, dayKey: log.dayKey,
                   prayer: log.prayer, tier: log.tier, loggedAt: log.loggedAt,
                   jamaat: log.jamaat, placeLabel: placeLabel, photoPath: photoPath,
                   travelCombined: travelCombined)
    }
}

// MARK: - excused_days

/// A BARE FLAG. Period privacy is absolute (§3): `breakReason` never leaves the
/// device, and there is no column here that could hold it.
///
/// v4 DECISION: the row's `created_at` is NOT mirrored. §7 gives this table
/// three columns — user, circle, day — and the timestamp is the one thing on
/// it that carries meaning the flag does not: it pins the minute a break
/// started. It is not needed to render anything, so the client neither decodes
/// it nor keeps it in `circle.json`. (The column still exists server-side; the
/// matching column-scoped grant belongs with the backend migrations.)
struct RemoteExcusedDay: Codable, Equatable, Sendable {
    var userID: UUID
    var circleID: UUID
    var dayKey: String

    init(userID: UUID, circleID: UUID, dayKey: String) {
        self.userID = userID
        self.circleID = circleID
        self.dayKey = dayKey
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case circleID = "circle_id"
        case dayKey = "day_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        dayKey = try c.decode(String.self, forKey: .dayKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(dayKey, forKey: .dayKey)
    }
}

// MARK: - recovery_weeks

/// One opaque weekly integer per user (§3). The scoreboard sees the number and
/// never what earned it — no dhikr counts, no deed ids, nothing per-day.
///
/// v4 DECISION: `updated_at` is NOT mirrored, for the same reason the excused
/// row drops `created_at`. The total is meant to be opaque, but the timestamp
/// advances on every dhikr tap and every deed, so keeping it would hand the
/// circle a per-action activity trace hanging off the one row that exists to
/// avoid exactly that. §7 lists four columns; these are them.
struct RemoteRecoveryWeek: Codable, Equatable, Sendable {
    var userID: UUID
    var circleID: UUID
    var weekKey: String         // "yyyy-Www", e.g. "2026-W24"
    var xp: Int

    init(userID: UUID, circleID: UUID, weekKey: String, xp: Int) {
        self.userID = userID
        self.circleID = circleID
        self.weekKey = weekKey
        self.xp = xp
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case circleID = "circle_id"
        case weekKey = "week_key"
        case xp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        weekKey = try c.decode(String.self, forKey: .weekKey)
        xp = (try? c.decodeIfPresent(Int.self, forKey: .xp)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(weekKey, forKey: .weekKey)
        try c.encode(xp, forKey: .xp)
    }
}

// MARK: - custom_challenges

/// The circle's own "everyone logs <prayer> for <days> days" challenge. The row
/// is just the definition — progress and awards stay client-computed, so the
/// same inputs give every device the same result (§5).
struct RemoteCustomChallenge: Codable, Equatable, Sendable, Identifiable {
    var id: String              // the client's "custom-<uuid>" — keeps ChallengeEngine's identity
    var circleID: UUID
    var createdBy: UUID
    var prayer: Prayer
    var days: Int
    var weekKey: String?
    var createdAt: Date?

    init(id: String, circleID: UUID, createdBy: UUID, prayer: Prayer, days: Int,
         weekKey: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.circleID = circleID
        self.createdBy = createdBy
        self.prayer = prayer
        self.days = days
        self.weekKey = weekKey
        self.createdAt = createdAt
    }

    // v4 Phase C FIX: `created_at` is decoded and NEVER encoded, exactly like
    // every other timestamp in this file — an earlier draft made it rule 2's
    // second exception and the grant says otherwise.
    // `20260821000200_rls.sql` gives `authenticated`
    // `insert (id, circle_id, created_by, prayer, days, week_key)` and nothing
    // more, and `backend/tests/sql/12_rls_enabled_everywhere.sql` fails the
    // backend build if `created_at` is ever added to that list. Sending the
    // column made EVERY challenge insert fail with `42501 permission denied for
    // column created_at` — a refusal, not an outage, so the op spent its whole
    // refusal budget and was then discarded, and a custom challenge silently
    // never reached the circle at all.
    //
    // Nothing is lost: the column's `default now()` fills it, and the value is
    // read back on the next pull. It is not load-bearing on the client either —
    // `CustomChallenge.createdAt` is used only by `CircleSync.challengeCreated`
    // to derive a week key from the LOCAL challenge, never to order anything.
    enum CodingKeys: String, CodingKey {
        case id
        case circleID = "circle_id"
        case createdBy = "created_by"
        case prayer
        case days
        case weekKey = "week_key"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        createdBy = try c.decode(UUID.self, forKey: .createdBy)
        prayer = try c.decode(Prayer.self, forKey: .prayer)
        days = try c.decode(Int.self, forKey: .days)
        weekKey = try c.decodeIfPresent(String.self, forKey: .weekKey)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(prayer, forKey: .prayer)
        try c.encode(days, forKey: .days)
        try c.encodeIfPresent(weekKey, forKey: .weekKey)
        // created_at deliberately absent — see the note on CodingKeys.
    }

    /// The local shape `ChallengeEngine` already understands. `createdAt` falls
    /// back to the epoch rather than reading a clock — the value only orders
    /// the list, and a nil here means the row predates the column.
    func asCustomChallenge() -> CustomChallenge {
        CustomChallenge(id: id, prayer: prayer, days: days,
                        createdAt: createdAt ?? Date(timeIntervalSince1970: 0))
    }

    static func from(challenge: CustomChallenge, circleID: UUID, createdBy: UUID,
                     weekKey: String?) -> RemoteCustomChallenge {
        RemoteCustomChallenge(id: challenge.id, circleID: circleID, createdBy: createdBy,
                              prayer: challenge.prayer, days: challenge.days,
                              weekKey: weekKey, createdAt: challenge.createdAt)
    }
}
