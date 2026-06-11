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
        case .qada: return 5
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

struct LeaderboardEntry: Identifiable {
    var id: String
    var name: String
    var avatar: String   // emoji
    var xp: Int
    var isYou: Bool
}

struct DayRecap {
    var dayKey: String
    var date: Date
    var loggedCount: Int
    var inWindowCount: Int
    var xp: Int
    var isPerfect: Bool
}
