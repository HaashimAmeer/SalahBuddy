import Foundation

// MARK: - Prayer

enum Prayer: String, CaseIterable, Codable, Identifiable {
    case fajr, dhuhr, asr, maghrib, isha

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fajr: return "Fajr"
        case .dhuhr: return "Dhuhr"
        case .asr: return "Asr"
        case .maghrib: return "Maghrib"
        case .isha: return "Isha"
        }
    }

    var symbolName: String {
        switch self {
        case .fajr: return "sunrise.fill"
        case .dhuhr: return "sun.max.fill"
        case .asr: return "sun.min.fill"
        case .maghrib: return "sunset.fill"
        case .isha: return "moon.stars.fill"
        }
    }

    var emoji: String {
        switch self {
        case .fajr: return "🌅"
        case .dhuhr: return "☀️"
        case .asr: return "🌤"
        case .maghrib: return "🌇"
        case .isha: return "🌙"
        }
    }
}

// MARK: - Log tier

/// v3.2: window split into QUARTERS (was thirds) — a steeper early-bird curve
/// so there's always a real pull to pray sooner. Old logs keep their stored
/// xp and old tier rawValues still decode.
enum LogTier: String, Codable {
    case onTime, prayed, lastCall, closeCall, qada

    var xp: Int {
        switch self {
        case .onTime: return 30    // 1st quarter
        case .prayed: return 20    // 2nd quarter
        case .lastCall: return 15  // 3rd quarter
        case .closeCall: return 12 // 4th quarter — still beats making up later
        case .qada: return 10      // "half points". Old logs keep their stored xp.
        }
    }

    var label: String {
        switch self {
        case .onTime: return "On time! ⚡"
        case .prayed: return "Prayed"
        case .lastCall: return "Getting late"
        case .closeCall: return "Just made it"
        case .qada: return "Made up (Qada)"
        }
    }

    /// Logged within the window (anything but qada).
    var isInWindow: Bool { self != .qada }
}

// MARK: - Schedule

struct PrayerWindow {
    let prayer: Prayer
    let start: Date
    let end: Date
}

struct DaySchedule {
    let dayKey: String
    let dayStart: Date
    let windows: [PrayerWindow]

    func window(for prayer: Prayer) -> PrayerWindow? {
        windows.first { $0.prayer == prayer }
    }
}

// MARK: - Logs

/// Where a prayer happened — one optional tap at post time, never required.
enum PlaceTag: String, Codable, CaseIterable, Identifiable {
    case home, masjid, work, onTheGo

    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .home: return "🏠"
        case .masjid: return "🕌"
        case .work: return "💼"
        case .onTheGo: return "📍"
        }
    }
    var displayName: String {
        switch self {
        case .home: return "Home"
        case .masjid: return "Masjid"
        case .work: return "Work"
        case .onTheGo: return "On the go"
        }
    }
}

struct PrayerLog: Codable, Identifiable, Equatable {
    var id: UUID
    var prayer: Prayer
    var dayKey: String          // "yyyy-MM-dd" local — the SCHEDULE day the window belongs to
    var loggedAt: Date
    var tier: LogTier
    var xp: Int
    var photoFilename: String?  // v2: in-window photo proof (nil for qada / v1 logs)
    var jamaat: Bool            // v2: prayed in congregation (+5 XP, tracked for challenges)
    var placeTag: PlaceTag?     // v3: optional "where I prayed" tag
    var placeName: String?      // v3: reverse-geocoded name when tagged .onTheGo

    init(id: UUID, prayer: Prayer, dayKey: String, loggedAt: Date, tier: LogTier, xp: Int,
         photoFilename: String? = nil, jamaat: Bool = false,
         placeTag: PlaceTag? = nil, placeName: String? = nil) {
        self.id = id
        self.prayer = prayer
        self.dayKey = dayKey
        self.loggedAt = loggedAt
        self.tier = tier
        self.xp = xp
        self.photoFilename = photoFilename
        self.jamaat = jamaat
        self.placeTag = placeTag
        self.placeName = placeName
    }

    // Migration-safe decoding: v1/v2 logs (missing newer fields) must keep decoding.
    private enum CodingKeys: String, CodingKey {
        case id, prayer, dayKey, loggedAt, tier, xp, photoFilename, jamaat, placeTag, placeName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        prayer = try c.decode(Prayer.self, forKey: .prayer)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        loggedAt = try c.decode(Date.self, forKey: .loggedAt)
        tier = try c.decode(LogTier.self, forKey: .tier)
        xp = try c.decode(Int.self, forKey: .xp)
        photoFilename = try c.decodeIfPresent(String.self, forKey: .photoFilename)
        jamaat = try c.decodeIfPresent(Bool.self, forKey: .jamaat) ?? false
        placeTag = try c.decodeIfPresent(PlaceTag.self, forKey: .placeTag)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
    }
}

// MARK: - Profile

struct UserProfile: Codable {
    var name: String
    var totalXP: Int
    var streak: Int
    var longestStreak: Int
    var streakFreezes: Int
    var lastStreakDayKey: String?
    var lastReconciledDayKey: String?
    var earnedBadges: [String: Date]
    var perfectDayCount: Int
    var joinedAt: Date
    var excusedDayKeys: Set<String>            // v2: days marked "Can't pray today"
    var challengeCompletions: [String: Date]   // v2: challenge id (or "id|weekKey") → completion date
    var excusedModeSince: String?              // v3.2: dayKey the "can't pray" break started (nil = not on a break)
    var dhikrByDay: [String: Int]              // v3.2: dayKey → dhikr count (taps), unlimited
    var customChallenges: [CustomChallenge]    // v3.2: group challenges the circle created
    var breakReason: String?                   // v3.4: "period" / "illness" / "other" — tailors break copy
    var recoveryXPByDay: [String: Int]         // v3.5: XP earned from dhikr+deeds per day (enforces soft cap)
    var deedsByDay: [String: [String]]         // v3.5: completed good-deed ids per day

    init(name: String, totalXP: Int, streak: Int, longestStreak: Int, streakFreezes: Int,
         lastStreakDayKey: String?, lastReconciledDayKey: String?, earnedBadges: [String: Date],
         perfectDayCount: Int, joinedAt: Date,
         excusedDayKeys: Set<String> = [], challengeCompletions: [String: Date] = [:],
         excusedModeSince: String? = nil, dhikrByDay: [String: Int] = [:],
         customChallenges: [CustomChallenge] = [], breakReason: String? = nil,
         recoveryXPByDay: [String: Int] = [:], deedsByDay: [String: [String]] = [:]) {
        self.name = name
        self.totalXP = totalXP
        self.streak = streak
        self.longestStreak = longestStreak
        self.streakFreezes = streakFreezes
        self.lastStreakDayKey = lastStreakDayKey
        self.lastReconciledDayKey = lastReconciledDayKey
        self.earnedBadges = earnedBadges
        self.perfectDayCount = perfectDayCount
        self.joinedAt = joinedAt
        self.excusedDayKeys = excusedDayKeys
        self.challengeCompletions = challengeCompletions
        self.excusedModeSince = excusedModeSince
        self.dhikrByDay = dhikrByDay
        self.customChallenges = customChallenges
        self.breakReason = breakReason
        self.recoveryXPByDay = recoveryXPByDay
        self.deedsByDay = deedsByDay
    }

    // Migration-safe decoding: v1 profiles lack the v2 fields.
    private enum CodingKeys: String, CodingKey {
        case name, totalXP, streak, longestStreak, streakFreezes
        case lastStreakDayKey, lastReconciledDayKey, earnedBadges, perfectDayCount, joinedAt
        case excusedDayKeys, challengeCompletions
        case excusedModeSince, dhikrByDay, customChallenges, breakReason
        case recoveryXPByDay, deedsByDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        totalXP = try c.decode(Int.self, forKey: .totalXP)
        streak = try c.decode(Int.self, forKey: .streak)
        longestStreak = try c.decode(Int.self, forKey: .longestStreak)
        streakFreezes = try c.decode(Int.self, forKey: .streakFreezes)
        lastStreakDayKey = try c.decodeIfPresent(String.self, forKey: .lastStreakDayKey)
        lastReconciledDayKey = try c.decodeIfPresent(String.self, forKey: .lastReconciledDayKey)
        earnedBadges = try c.decode([String: Date].self, forKey: .earnedBadges)
        perfectDayCount = try c.decode(Int.self, forKey: .perfectDayCount)
        joinedAt = try c.decode(Date.self, forKey: .joinedAt)
        excusedDayKeys = (try? c.decodeIfPresent(Set<String>.self, forKey: .excusedDayKeys)) ?? []
        challengeCompletions = (try? c.decodeIfPresent([String: Date].self, forKey: .challengeCompletions)) ?? [:]
        excusedModeSince = (try? c.decodeIfPresent(String.self, forKey: .excusedModeSince)) ?? nil
        dhikrByDay = (try? c.decodeIfPresent([String: Int].self, forKey: .dhikrByDay)) ?? [:]
        customChallenges = (try? c.decodeIfPresent([CustomChallenge].self, forKey: .customChallenges)) ?? []
        breakReason = (try? c.decodeIfPresent(String.self, forKey: .breakReason)) ?? nil
        recoveryXPByDay = (try? c.decodeIfPresent([String: Int].self, forKey: .recoveryXPByDay)) ?? [:]
        deedsByDay = (try? c.decodeIfPresent([String: [String]].self, forKey: .deedsByDay)) ?? [:]
    }

    static func fresh(now: Date) -> UserProfile {
        UserProfile(name: "", totalXP: 0, streak: 0, longestStreak: 0,
                    streakFreezes: 0, lastStreakDayKey: nil, lastReconciledDayKey: nil,
                    earnedBadges: [:], perfectDayCount: 0, joinedAt: now)
    }
}

// MARK: - Settings

enum CalcMethod: String, Codable, CaseIterable {
    case northAmerica, muslimWorldLeague, egyptian, ummAlQura, karachi

    var displayName: String {
        switch self {
        case .northAmerica: return "North America (ISNA)"
        case .muslimWorldLeague: return "Muslim World League"
        case .egyptian: return "Egyptian"
        case .ummAlQura: return "Umm Al-Qura"
        case .karachi: return "Karachi"
        }
    }
}

enum AsrMadhab: String, Codable, CaseIterable {
    case shafi, hanafi
}

/// v3: a remembered coordinate for a place tag ("Home" etc.), captured the
/// first time you tag that place with a device fix available. Powers the
/// near-a-saved-place auto-suggestion on the post screen.
struct SavedPlace: Codable, Equatable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in meters (haversine) — pure, testable.
    func distanceMeters(latitude lat: Double, longitude lon: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat - latitude) * .pi / 180
        let dLon = (lon - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The saved place within `maxMeters` of the coordinate, nearest first.
    static func nearest(to lat: Double, _ lon: Double,
                        in places: [String: SavedPlace],
                        maxMeters: Double = 250) -> PlaceTag? {
        places
            .compactMap { key, place -> (PlaceTag, Double)? in
                guard let tag = PlaceTag(rawValue: key) else { return nil }
                let d = place.distanceMeters(latitude: lat, longitude: lon)
                return d <= maxMeters ? (tag, d) : nil
            }
            .min { $0.1 < $1.1 }?
            .0
    }
}

struct AppSettings: Codable {
    var calcMethod: CalcMethod = .northAmerica
    var madhab: AsrMadhab = .shafi
    var useDeviceLocation: Bool = true
    var fixedLatitude: Double = 47.6062
    var fixedLongitude: Double = -122.3321
    var locationName: String = "Seattle"
    var notificationsEnabled: Bool = false
    var dailyGoal: Int = 100
    var hasOnboarded: Bool = false
    var hardestPrayer: Prayer? = nil   // v2: onboarding goal-setting → seeds goal3 challenge
    var savedPlaces: [String: SavedPlace] = [:]   // v3: PlaceTag.rawValue → remembered spot
    var memberKind: String? = nil      // v3.2: "brother" / "sister" (onboarding, optional) — tailors copy
    var isTraveling: Bool = false      // v3.3: travel mode — combine Dhuhr+Asr and Maghrib+Isha

    init() {}

    // Tolerant decoding: missing keys fall back to defaults (forward-compatible).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calcMethod = (try? c.decode(CalcMethod.self, forKey: .calcMethod)) ?? .northAmerica
        madhab = (try? c.decode(AsrMadhab.self, forKey: .madhab)) ?? .shafi
        useDeviceLocation = (try? c.decode(Bool.self, forKey: .useDeviceLocation)) ?? true
        fixedLatitude = (try? c.decode(Double.self, forKey: .fixedLatitude)) ?? 47.6062
        fixedLongitude = (try? c.decode(Double.self, forKey: .fixedLongitude)) ?? -122.3321
        locationName = (try? c.decode(String.self, forKey: .locationName)) ?? "Seattle"
        notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? false
        dailyGoal = (try? c.decode(Int.self, forKey: .dailyGoal)) ?? 100
        hasOnboarded = (try? c.decode(Bool.self, forKey: .hasOnboarded)) ?? false
        hardestPrayer = (try? c.decodeIfPresent(Prayer.self, forKey: .hardestPrayer)) ?? nil
        savedPlaces = (try? c.decode([String: SavedPlace].self, forKey: .savedPlaces)) ?? [:]
        memberKind = (try? c.decodeIfPresent(String.self, forKey: .memberKind)) ?? nil
        isTraveling = (try? c.decode(Bool.self, forKey: .isTraveling)) ?? false
    }
}

// MARK: - Recharge (v3.5: good deeds during a break)

/// One phrase of the tasbih (dhikr after prayer): Arabic, transliteration,
/// meaning, and how many times it's repeated in a round (33 / 33 / 34 = 100).
struct TasbihPhrase: Equatable {
    let arabic: String
    let translit: String
    let meaning: String
    let count: Int
}

/// A good-deed prompt offered during a break — all universally encouraged
/// during menstruation (no Qur'an *reciting*, to sidestep the mushaf debate).
struct GoodDeed: Identifiable, Equatable {
    let id: String
    let emoji: String
    let title: String
    let arabic: String?
}

enum Recharge {
    static let roundTotal = 100

    static let tasbih: [TasbihPhrase] = [
        TasbihPhrase(arabic: "سُبْحَانَ اللّٰه", translit: "SubhanAllah",
                     meaning: "Glory be to Allah", count: 33),
        TasbihPhrase(arabic: "الْحَمْدُ لِلّٰه", translit: "Alhamdulillah",
                     meaning: "All praise is for Allah", count: 33),
        TasbihPhrase(arabic: "اللّٰهُ أَكْبَر", translit: "Allahu Akbar",
                     meaning: "Allah is the Greatest", count: 34),
    ]

    /// Phrase + how many of it are done so far, for a running total. `inSet`
    /// is 0-based within the current phrase; `phraseIndex` is 0/1/2.
    static func position(forTotal total: Int) -> (phrase: TasbihPhrase, inSet: Int, phraseIndex: Int) {
        let pos = ((total % roundTotal) + roundTotal) % roundTotal   // 0..99, safe for 0
        if pos < 33 { return (tasbih[0], pos, 0) }
        if pos < 66 { return (tasbih[1], pos - 33, 1) }
        return (tasbih[2], pos - 66, 2)
    }

    static let goodDeeds: [GoodDeed] = [
        GoodDeed(id: "salawat", emoji: "🤲", title: "Send 10 salawat ﷺ",
                 arabic: "اللّٰهُمَّ صَلِّ عَلَى مُحَمَّد"),
        GoodDeed(id: "istighfar", emoji: "💫", title: "Istighfar ×100",
                 arabic: "أَسْتَغْفِرُ اللّٰه"),
        GoodDeed(id: "dua", emoji: "💜", title: "Make du'a for someone you love", arabic: nil),
        GoodDeed(id: "sadaqah", emoji: "🌿", title: "Give a little sadaqah", arabic: nil),
        GoodDeed(id: "quran", emoji: "🎧", title: "Listen to a page of Qur'an", arabic: nil),
        GoodDeed(id: "gratitude", emoji: "🌸", title: "Note 3 things you're grateful for", arabic: nil),
    ]
}

// MARK: - Travel combining (v3.3)

/// While traveling (safar) you may combine (jam') Dhuhr+Asr and Maghrib+Isha.
/// Fajr is never combined. This helper defines the pairs and which prayer
/// leads (the earlier one). Qasr — shortening rak'ahs — isn't trackable here.
enum TravelPairs {
    /// The combinable pairs, lead (earlier) first.
    static let pairs: [(lead: Prayer, follow: Prayer)] = [(.dhuhr, .asr), (.maghrib, .isha)]

    /// The prayer combined with `prayer`, or nil for Fajr (never combined).
    static func partner(of prayer: Prayer) -> Prayer? {
        switch prayer {
        case .dhuhr: return .asr
        case .asr: return .dhuhr
        case .maghrib: return .isha
        case .isha: return .maghrib
        case .fajr: return nil
        }
    }

    /// The earlier prayer of `prayer`'s pair (itself if it's already the lead
    /// or Fajr).
    static func lead(of prayer: Prayer) -> Prayer {
        switch prayer {
        case .asr: return .dhuhr
        case .isha: return .maghrib
        default: return prayer
        }
    }

    static func isCombinable(_ prayer: Prayer) -> Bool { prayer != .fajr }
}

// MARK: - Badges

struct Badge: Identifiable {
    let id: String
    let name: String
    let symbolName: String
    let detail: String
}

// MARK: - UI-facing value types

enum PrayerStatus: Equatable {
    case upcoming(opensAt: Date)
    case open(closesAt: Date)
    case logged(LogTier)
    case missedWindow            // window passed today, qada still possible
}

struct LogResult: Equatable {
    var prayer: Prayer
    var tier: LogTier
    var xpEarned: Int
    var bonusXP: Int
    var newBadgeIDs: [String]
    var leveledUp: Bool
    var perfectDay: Bool
    var streakExtended: Bool
}

struct DayRecap {
    var dayKey: String
    var date: Date
    var loggedCount: Int
    var inWindowCount: Int
    var xp: Int
    var isPerfect: Bool
}

// MARK: - v2 Circle / grid contracts (§3)

struct CircleMember: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let isYou: Bool
}

enum PostContent: Equatable {
    case photo(filename: String)
    case illustration(seed: UInt64)
}

enum GridEntryState: Equatable {
    case waiting
    case posted(PostContent, tier: LogTier, at: Date)
    case qada(at: Date)
    case missed
    case excused
}

struct GridEntry: Identifiable {
    let id: String
    let member: CircleMember
    let state: GridEntryState
    /// v3: short place pill for posted squares, e.g. "🏠 Home" or "📍 Capitol Hill".
    var placeLabel: String? = nil
}

enum GridCellState: Equatable {
    case inWindow(LogTier)
    case qada
    case missed
    case excused
    case future
}

struct MemberWeekRow: Identifiable {
    let id: String
    let member: CircleMember
    let days: [[GridCellState]]   // 7 days × 5 prayers, Mon-first
}

/// v3.2: a group challenge the circle defined themselves — "everyone logs
/// <prayer> for <days> days in a row". Reward scales with length.
struct CustomChallenge: Codable, Identifiable, Equatable {
    var id: String          // "custom-<uuid>"
    var prayer: Prayer
    var days: Int
    var createdAt: Date

    var rewardXP: Int { days * 15 }
    var title: String { "Everyone: \(prayer.displayName) ×\(days)" }
    var detail: String { "The whole circle logs \(prayer.displayName) \(days) days in a row" }
}

struct ChallengeProgress: Identifiable {
    let id: String
    let title: String
    let detail: String
    let emoji: String
    let isGroup: Bool
    let target: Int
    let current: Int
    let completedAt: Date?
    let rewardXP: Int
}

struct DayPhotoSummary: Identifiable {
    let id: String
    let date: Date
    let photoFilenames: [String]
    let recap: DayRecap
}
