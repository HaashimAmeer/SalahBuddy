import Foundation

enum Badges {

    static let all: [Badge] = [
        Badge(id: "streak3", name: "Kindling", symbolName: "flame",
              detail: "Reach a 3-day streak"),
        Badge(id: "streak7", name: "On Fire", symbolName: "flame.fill",
              detail: "Reach a 7-day streak"),
        Badge(id: "streak30", name: "Unstoppable", symbolName: "flame.circle.fill",
              detail: "Reach a 30-day streak"),
        Badge(id: "perfect1", name: "Perfect Day", symbolName: "star.fill",
              detail: "Log all 5 prayers in their windows"),
        Badge(id: "perfect10", name: "Perfectionist", symbolName: "sparkles",
              detail: "10 perfect days"),
        Badge(id: "fajr7", name: "Dawn Patrol", symbolName: "sunrise.fill",
              detail: "7 Fajr prayers in the window"),
        Badge(id: "xp1000", name: "Rising Star", symbolName: "bolt.fill",
              detail: "Earn 1,000 total XP"),
        Badge(id: "xp5000", name: "Luminary", symbolName: "sun.max.fill",
              detail: "Earn 5,000 total XP"),
    ]

    static func badge(id: String) -> Badge? {
        all.first { $0.id == id }
    }

    /// IDs of every badge whose condition is currently satisfied.
    static func satisfiedBadgeIDs(profile: UserProfile, logs: [PrayerLog]) -> [String] {
        var ids: [String] = []
        if profile.streak >= 3 || profile.longestStreak >= 3 { ids.append("streak3") }
        if profile.streak >= 7 || profile.longestStreak >= 7 { ids.append("streak7") }
        if profile.streak >= 30 || profile.longestStreak >= 30 { ids.append("streak30") }
        if profile.perfectDayCount >= 1 { ids.append("perfect1") }
        if profile.perfectDayCount >= 10 { ids.append("perfect10") }
        let inWindowFajr = logs.lazy.filter { $0.prayer == .fajr && $0.tier.isInWindow }.count
        if inWindowFajr >= 7 { ids.append("fajr7") }
        if profile.totalXP >= 1000 { ids.append("xp1000") }
        if profile.totalXP >= 5000 { ids.append("xp5000") }
        return ids
    }

    /// Satisfied-but-not-yet-earned badge IDs (i.e. newly unlocked).
    static func newlyEarnedIDs(profile: UserProfile, logs: [PrayerLog]) -> [String] {
        satisfiedBadgeIDs(profile: profile, logs: logs)
            .filter { profile.earnedBadges[$0] == nil }
    }
}
