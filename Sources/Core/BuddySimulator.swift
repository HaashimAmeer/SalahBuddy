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

/// v2 simulated 3-buddy circle (replaces the v1 FriendSimulator league).
///
/// For each buddy × day × prayer a deterministic outcome is derived from a
/// SplitMix64 RNG seeded by FNV-1a("name|dayKey|prayer") — a pure function of
/// the dayKey + window, so time-travel always re-derives identical posts.
/// A buddy's post becomes visible only once `AppClock.now >= loggedAt`,
/// letting the grid fill in live through the day. Buddy "photos" are
/// deterministic SwiftUI illustrations (seeded), never real images.
enum BuddySimulator {

    struct Buddy: Equatable {
        let name: String
        let emoji: String
        let consistency: Double
    }

    static let buddies: [Buddy] = [
        Buddy(name: "Mina", emoji: "🌸", consistency: 0.92),
        Buddy(name: "Harun", emoji: "🧢", consistency: 0.75),
        Buddy(name: "Haifa", emoji: "📚", consistency: 0.85),
    ]

    static func member(for buddy: Buddy) -> CircleMember {
        CircleMember(id: "buddy.\(buddy.name)", name: buddy.name, emoji: buddy.emoji, isYou: false)
    }

    // MARK: - Outcomes

    enum Outcome: Equatable {
        case inWindow(tier: LogTier, loggedAt: Date, illustrationSeed: UInt64)
        case qada(at: Date)
        case missed

        /// XP this outcome is worth once visible (current v2 tier values).
        var xp: Int {
            switch self {
            case .inWindow(let tier, _, _): return tier.xp
            case .qada: return LogTier.qada.xp
            case .missed: return 0
            }
        }
    }

    /// FNV-1a 64-bit over "name|dayKey|prayer" — stable across launches.
    static func seed(name: String, dayKey: String, prayer: Prayer) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in "\(name)|\(dayKey)|\(prayer.rawValue)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        return hash
    }

    /// Deterministic place tag for a buddy's post, derived from its
    /// illustration seed (~55% home, ~25% masjid, ~10% work, ~10% on the go).
    static func placeTag(seed: UInt64) -> PlaceTag? {
        switch seed % 100 {
        case 0..<55: return .home
        case 55..<80: return .masjid
        case 80..<90: return .work
        default: return .onTheGo
        }
    }

    /// Deterministic outcome for one buddy × day × prayer. Pure function of
    /// (buddy, dayKey, window) — never reads the clock.
    static func outcome(for buddy: Buddy, dayKey: String, window: PrayerWindow) -> Outcome {
        var rng = SplitMix64(seed: seed(name: buddy.name, dayKey: dayKey, prayer: window.prayer))
        let r1 = rng.uniform()
        let r2 = rng.uniform()
        let r3 = rng.uniform()
        let illustrationSeed = rng.next()

        let duration = window.end.timeIntervalSince(window.start)
        if r1 < buddy.consistency {
            let tier: LogTier
            let thirdIndex: Double
            if r2 < 0.50 { tier = .onTime; thirdIndex = 0 }
            else if r2 < 0.85 { tier = .prayed; thirdIndex = 1 }
            else { tier = .lastCall; thirdIndex = 2 }
            // loggedAt lands inside the tier's third of the window.
            let loggedAt = window.start.addingTimeInterval((thirdIndex + r3) * duration / 3)
            return .inWindow(tier: tier, loggedAt: loggedAt, illustrationSeed: illustrationSeed)
        } else if r1 < buddy.consistency + 0.12 {
            // Made up within ~2h after the window closed.
            return .qada(at: window.end.addingTimeInterval(r3 * 2 * 3600))
        }
        return .missed
    }

    /// Synthetic PrayerLog for an outcome (nil for .missed). Used so circle
    /// scoreboards/grids/challenges can treat buddies and you uniformly.
    static func log(for buddy: Buddy, dayKey: String, window: PrayerWindow) -> PrayerLog? {
        switch outcome(for: buddy, dayKey: dayKey, window: window) {
        case .inWindow(let tier, let loggedAt, _):
            return PrayerLog(id: stableUUID(name: buddy.name, dayKey: dayKey, prayer: window.prayer),
                             prayer: window.prayer, dayKey: dayKey,
                             loggedAt: loggedAt, tier: tier, xp: tier.xp)
        case .qada(let at):
            return PrayerLog(id: stableUUID(name: buddy.name, dayKey: dayKey, prayer: window.prayer),
                             prayer: window.prayer, dayKey: dayKey,
                             loggedAt: at, tier: .qada, xp: LogTier.qada.xp)
        case .missed:
            return nil
        }
    }

    /// All of a buddy's posts across `days` that are visible by `now`
    /// (loggedAt/qada-at <= now — the grid fills in live through the day).
    static func visibleLogs(for buddy: Buddy,
                            days: [(dayKey: String, schedule: DaySchedule)],
                            asOf now: Date) -> [PrayerLog] {
        var result: [PrayerLog] = []
        for day in days {
            for window in day.schedule.windows {
                if let log = log(for: buddy, dayKey: day.dayKey, window: window),
                   log.loggedAt <= now {
                    result.append(log)
                }
            }
        }
        return result
    }

    /// A buddy's weekly score as of `now`: per-day XP (incl. perfect-day
    /// bonus) over their visible posts — same math the grid uses, so the
    /// scoreboard and grid always agree.
    static func weeklyXP(for buddy: Buddy,
                         days: [(dayKey: String, schedule: DaySchedule)],
                         asOf now: Date) -> Int {
        let logs = visibleLogs(for: buddy, days: days, asOf: now)
        let dayKeys = Set(logs.map(\.dayKey))
        return dayKeys.reduce(0) { $0 + GameEngine.xp(forDay: $1, logs: logs) }
    }

    /// Deterministic UUID-shaped id from the outcome seed (stable across calls).
    private static func stableUUID(name: String, dayKey: String, prayer: Prayer) -> UUID {
        var rng = SplitMix64(seed: seed(name: name, dayKey: dayKey, prayer: prayer) ^ 0xA5A5A5A5A5A5A5A5)
        let a = rng.next(), b = rng.next()
        let bytes: [UInt8] = (0..<8).map { UInt8((a >> ($0 * 8)) & 0xFF) }
            + (0..<8).map { UInt8((b >> ($0 * 8)) & 0xFF) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Week math (Mon-start local weeks)

    /// Monday 00:00 local of the week containing `date`.
    static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let interval = cal.dateInterval(of: .weekOfYear, for: date)
        return interval?.start ?? cal.startOfDay(for: date)
    }

    /// Next Monday 00:00 local — when the weekly circle scores reset.
    static func weekEnd(for date: Date, calendar: Calendar = .current) -> Date {
        let start = weekStart(for: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)
    }

    /// ISO week key, e.g. "2026-W24" — used to key weekly challenge completions.
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }

    /// The 7 dayKeys of the Mon-start week containing `date`, Mon-first.
    static func weekDayKeys(for date: Date, calendar: Calendar = .current) -> [String] {
        let start = weekStart(for: date, calendar: calendar)
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { AppClock.dayKey(for: $0) }
        }
    }
}
