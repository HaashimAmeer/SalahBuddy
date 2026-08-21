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
// 2. **Server-managed columns are Optional and OMITTED when nil.** `created_at`
//    / `updated_at` have DB defaults; encoding an explicit `null` would try to
//    write null into a NOT NULL column. That is why the write-side DTOs
//    hand-write `encode(to:)` with `encodeIfPresent` instead of relying on
//    synthesis.
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
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
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
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
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

    init(id: UUID, userID: UUID, circleID: UUID, dayKey: String, prayer: Prayer,
         tier: LogTier, loggedAt: Date, jamaat: Bool = false,
         placeLabel: String? = nil, photoPath: String? = nil,
         travelCombined: Bool = false) {
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
    }

    /// `created_at` / `updated_at` are intentionally absent: they are server
    /// defaults, and sending them would let a wrong device clock win.
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
        let xp: Int = GameEngine.prayerXP(tier: tier, jamaat: jamaat)
        return PrayerLog(id: id, prayer: prayer, dayKey: dayKey, loggedAt: loggedAt,
                         tier: tier, xp: xp, photoFilename: nil, jamaat: jamaat,
                         placeTag: nil, placeName: nil)
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
struct RemoteExcusedDay: Codable, Equatable, Sendable {
    var userID: UUID
    var circleID: UUID
    var dayKey: String
    var createdAt: Date?

    init(userID: UUID, circleID: UUID, dayKey: String, createdAt: Date? = nil) {
        self.userID = userID
        self.circleID = circleID
        self.dayKey = dayKey
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case circleID = "circle_id"
        case dayKey = "day_key"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(dayKey, forKey: .dayKey)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

// MARK: - recovery_weeks

/// One opaque weekly integer per user (§3). The scoreboard sees the number and
/// never what earned it — no dhikr counts, no deed ids, nothing per-day.
struct RemoteRecoveryWeek: Codable, Equatable, Sendable {
    var userID: UUID
    var circleID: UUID
    var weekKey: String         // "yyyy-Www", e.g. "2026-W24"
    var xp: Int
    var updatedAt: Date?

    init(userID: UUID, circleID: UUID, weekKey: String, xp: Int, updatedAt: Date? = nil) {
        self.userID = userID
        self.circleID = circleID
        self.weekKey = weekKey
        self.xp = xp
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case circleID = "circle_id"
        case weekKey = "week_key"
        case xp
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(UUID.self, forKey: .userID)
        circleID = try c.decode(UUID.self, forKey: .circleID)
        weekKey = try c.decode(String.self, forKey: .weekKey)
        xp = (try? c.decodeIfPresent(Int.self, forKey: .xp)) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(circleID, forKey: .circleID)
        try c.encode(weekKey, forKey: .weekKey)
        try c.encode(xp, forKey: .xp)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
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
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
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
