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

enum LogTier: String, Codable {
    case onTime, prayed, lastCall, qada

    var xp: Int {
        switch self {
        case .onTime: return 30
        case .prayed: return 20
        case .lastCall: return 10
        case .qada: return 10      // v2: "half points" (was 5). Old logs keep their stored xp.
        }
    }

    var label: String {
        switch self {
        case .onTime: return "On time! ⚡"
        case .prayed: return "Prayed"
        case .lastCall: return "Just made it"
        case .qada: return "Made up (Qada)"
        }
    }

    /// onTime / prayed / lastCall — logged within the window.
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

struct PrayerLog: Codable, Identifiable, Equatable {
    var id: UUID
    var prayer: Prayer
    var dayKey: String          // "yyyy-MM-dd" local — the SCHEDULE day the window belongs to
    var loggedAt: Date
    var tier: LogTier
    var xp: Int
    var photoFilename: String?  // v2: in-window photo proof (nil for qada / v1 logs)
    var jamaat: Bool            // v2: prayed in congregation (+5 XP, tracked for challenges)

    init(id: UUID, prayer: Prayer, dayKey: String, loggedAt: Date, tier: LogTier, xp: Int,
         photoFilename: String? = nil, jamaat: Bool = false) {
        self.id = id
        self.prayer = prayer
        self.dayKey = dayKey
        self.loggedAt = loggedAt
        self.tier = tier
        self.xp = xp
        self.photoFilename = photoFilename
        self.jamaat = jamaat
    }

    // Migration-safe decoding: v1 logs (no photoFilename/jamaat) must keep decoding.
    private enum CodingKeys: String, CodingKey {
        case id, prayer, dayKey, loggedAt, tier, xp, photoFilename, jamaat
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

    init(name: String, totalXP: Int, streak: Int, longestStreak: Int, streakFreezes: Int,
         lastStreakDayKey: String?, lastReconciledDayKey: String?, earnedBadges: [String: Date],
         perfectDayCount: Int, joinedAt: Date,
         excusedDayKeys: Set<String> = [], challengeCompletions: [String: Date] = [:]) {
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
    }

    // Migration-safe decoding: v1 profiles lack the v2 fields.
    private enum CodingKeys: String, CodingKey {
        case name, totalXP, streak, longestStreak, streakFreezes
        case lastStreakDayKey, lastReconciledDayKey, earnedBadges, perfectDayCount, joinedAt
        case excusedDayKeys, challengeCompletions
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
    }
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
