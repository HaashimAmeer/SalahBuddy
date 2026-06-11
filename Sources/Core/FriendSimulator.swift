import Foundation

/// Deterministic SplitMix64 RNG — same seed → same sequence, every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// Simulated weekly league. Each friend's trajectory is deterministic per
/// (friendName, ISO week key): all 35 tier draws for the week are generated
/// up-front from a seeded SplitMix64, then only the windows elapsed by `date`
/// are summed — so the board moves during the day but never rewrites history.
enum FriendSimulator {

    struct Persona {
        let name: String
        let avatar: String
        let consistency: Double   // 0.55–0.95
    }

    static let personas: [Persona] = [
        Persona(name: "Ahmed", avatar: "🧔", consistency: 0.92),
        Persona(name: "Fatima", avatar: "🧕", consistency: 0.95),
        Persona(name: "Yusuf", avatar: "🧢", consistency: 0.85),
        Persona(name: "Aisha", avatar: "🌸", consistency: 0.78),
        Persona(name: "Omar", avatar: "🏀", consistency: 0.70),
        Persona(name: "Maryam", avatar: "📚", consistency: 0.88),
        Persona(name: "Bilal", avatar: "🎯", consistency: 0.65),
        Persona(name: "Zainab", avatar: "✨", consistency: 0.82),
        Persona(name: "Idris", avatar: "🌙", consistency: 0.55),
    ]

    /// Nominal local prayer times (hours from local midnight) used for the
    /// simulation's window grid — keeps friends deterministic & cheap.
    static let nominalHours: [Double] = [5.5, 13.0, 16.5, 19.5, 21.0]

    // MARK: - Week math

    /// Monday 00:00 local of the week containing `date`.
    static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let interval = cal.dateInterval(of: .weekOfYear, for: date)
        return interval?.start ?? cal.startOfDay(for: date)
    }

    /// Next Monday 00:00 local — when the league resets.
    static func weekEnd(for date: Date, calendar: Calendar = .current) -> Date {
        let start = weekStart(for: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)
    }

    /// ISO week key, e.g. "2026-W24".
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }

    /// FNV-1a 64-bit — stable across launches (unlike Swift's Hasher).
    static func seed(name: String, weekKey: String) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in "\(name)|\(weekKey)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        return hash
    }

    // MARK: - XP

    /// XP this persona has accrued this week as of `date`.
    static func weeklyXP(for persona: Persona, at date: Date, calendar: Calendar = .current) -> Int {
        let start = weekStart(for: date, calendar: calendar)
        let key = weekKey(for: date, calendar: calendar)
        var rng = SplitMix64(seed: seed(name: persona.name, weekKey: key))

        var total = 0
        for dayOffset in 0..<7 {
            for hour in nominalHours {
                // ALWAYS draw (fixed stream position), even for future windows.
                let r1 = rng.uniform()
                let r2 = rng.uniform()
                let windowTime = calendar.date(byAdding: .day, value: dayOffset, to: start)
                    .map { $0.addingTimeInterval(hour * 3600) }
                    ?? start.addingTimeInterval(Double(dayOffset) * 86400 + hour * 3600)
                guard windowTime <= date else { continue }

                if r1 < persona.consistency {
                    if r2 < 0.55 { total += LogTier.onTime.xp }
                    else if r2 < 0.85 { total += LogTier.prayed.xp }
                    else { total += LogTier.lastCall.xp }
                } else if r1 < persona.consistency + 0.12 {
                    total += LogTier.qada.xp
                }
            }
        }
        return total
    }

    /// All 9 simulated friends as leaderboard entries (unsorted, no "you").
    static func entries(at date: Date, calendar: Calendar = .current) -> [LeaderboardEntry] {
        personas.map { p in
            LeaderboardEntry(id: "friend.\(p.name)", name: p.name, avatar: p.avatar,
                             xp: weeklyXP(for: p, at: date, calendar: calendar), isYou: false)
        }
    }
}
