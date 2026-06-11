import Foundation

/// v2 challenge system. All 8 definitions are hard-coded; progress is
/// computed STATELESSLY from logs (yours + buddies'). Completion awards XP
/// once — recorded in `profile.challengeCompletions` keyed by the challenge
/// id (personal, once ever) or "id|weekKey" (group weeklies, re-awardable
/// each week).
enum ChallengeEngine {

    struct Definition {
        let id: String
        let title: String
        let detail: String
        let emoji: String
        let isGroup: Bool
        let target: Int
        let rewardXP: Int
    }

    /// All 8 challenge definitions (goal3 is surfaced only when
    /// `settings.hardestPrayer` is set — see `progressList`).
    static let definitions: [Definition] = [
        Definition(id: "fullday", title: "Full Day",
                   detail: "Pray all 5 in their windows in one day",
                   emoji: "🌞", isGroup: false, target: 5, rewardXP: 20),
        Definition(id: "fajr3", title: "Dawn Patrol Run",
                   detail: "Fajr in-window 3 days in a row",
                   emoji: "🌅", isGroup: false, target: 3, rewardXP: 30),
        Definition(id: "week7", title: "Perfect Week",
                   detail: "Log all 5 prayers every day for 7 days",
                   emoji: "🏆", isGroup: false, target: 7, rewardXP: 100),
        Definition(id: "jamaat3", title: "Together",
                   detail: "Pray in jamaat 3 times",
                   emoji: "🕌", isGroup: false, target: 3, rewardXP: 30),
        Definition(id: "goal3", title: "Goal Getter",
                   detail: "Your hardest prayer in-window 3 days in a row",
                   emoji: "🎯", isGroup: false, target: 3, rewardXP: 40),
        Definition(id: "isha3", title: "Circle Isha Streak",
                   detail: "Everyone logs Isha 3 days in a row",
                   emoji: "🌙", isGroup: true, target: 3, rewardXP: 50),
        Definition(id: "race300", title: "Race to 300",
                   detail: "Be first in your circle to 300 weekly XP",
                   emoji: "👑", isGroup: true, target: 300, rewardXP: 30),
        Definition(id: "circleperfect", title: "Circle Perfect Day",
                   detail: "Every member full-day on the same day",
                   emoji: "💫", isGroup: true, target: 4, rewardXP: 50),
    ]

    static func definition(id: String) -> Definition? {
        definitions.first { $0.id == id }
    }

    /// Completion-record key: personal = id (once ever); group weekly = "id|weekKey".
    static func completionKey(for def: Definition, weekKey: String) -> String {
        def.isGroup ? "\(def.id)|\(weekKey)" : def.id
    }

    // MARK: - Context

    /// Everything needed to compute progress, gathered by AppState.
    struct Context {
        let myLogs: [PrayerLog]                                          // full history
        let memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])]  // current week, all members
        let todayKey: String
        let recentDayKeys: [String]    // ordered oldest→newest, ending today (~30 days)
        let weekDayKeys: [String]      // Mon-first, 7 dayKeys of the current week
        let weekKey: String
        let hardestPrayer: Prayer?
        let completions: [String: Date]
    }

    // MARK: - Progress

    static func progressList(_ ctx: Context) -> [ChallengeProgress] {
        definitions.compactMap { def in
            if def.id == "goal3", ctx.hardestPrayer == nil { return nil }
            let key = completionKey(for: def, weekKey: ctx.weekKey)
            let current = current(for: def, ctx: ctx)
            return ChallengeProgress(id: def.id, title: def.title, detail: def.detail,
                                     emoji: def.emoji, isGroup: def.isGroup,
                                     target: def.target, current: min(current, def.target),
                                     completedAt: ctx.completions[key], rewardXP: def.rewardXP)
        }
    }

    /// Raw (unclamped) progress value for a definition.
    static func current(for def: Definition, ctx: Context) -> Int {
        switch def.id {
        case "fullday":
            // §6.6: an after-midnight isha carries YESTERDAY's dayKey, so the
            // 5th in-window prayer of a day can land once todayKey has already
            // rolled over. Take the best of the last two days so the award
            // check sees the just-completed day at log time (and later).
            let lastTwoDays = ctx.recentDayKeys.suffix(2)
            return lastTwoDays
                .map { inWindowCount(logs: ctx.myLogs, dayKey: $0) }
                .max() ?? inWindowCount(logs: ctx.myLogs, dayKey: ctx.todayKey)
        case "fajr3":
            return consecutiveRun(dayKeys: ctx.recentDayKeys, todayKey: ctx.todayKey) { key in
                hasInWindowLog(ctx.myLogs, prayer: .fajr, dayKey: key)
            }
        case "week7":
            return consecutiveRun(dayKeys: ctx.recentDayKeys, todayKey: ctx.todayKey) { key in
                GameEngine.isDayComplete(logs: ctx.myLogs, dayKey: key)
            }
        case "jamaat3":
            return ctx.myLogs.filter(\.jamaat).count
        case "goal3":
            guard let prayer = ctx.hardestPrayer else { return 0 }
            return consecutiveRun(dayKeys: ctx.recentDayKeys, todayKey: ctx.todayKey) { key in
                hasInWindowLog(ctx.myLogs, prayer: prayer, dayKey: key)
            }
        case "isha3":
            let weekSoFar = weekDayKeysThroughToday(ctx)
            return consecutiveRun(dayKeys: weekSoFar, todayKey: weekSoFar.last ?? ctx.todayKey) { key in
                ctx.memberWeekLogs.allSatisfy { entry in
                    entry.logs.contains { $0.prayer == .isha && $0.dayKey == key }
                }
            }
        case "race300":
            guard let you = ctx.memberWeekLogs.first(where: { $0.member.isYou }) else { return 0 }
            return memberWeeklyXP(logs: you.logs)
        case "circleperfect":
            let weekSoFar = weekDayKeysThroughToday(ctx)
            var best = 0
            for key in weekSoFar {
                let count = ctx.memberWeekLogs.filter { entry in
                    isFullInWindowDay(logs: entry.logs, dayKey: key)
                }.count
                best = max(best, count)
            }
            return best
        default:
            return 0
        }
    }

    /// Whether the challenge is satisfied RIGHT NOW (used for awarding).
    /// race300 requires actually winning the race, not just reaching 300.
    static func isCompletedNow(_ def: Definition, ctx: Context) -> Bool {
        if def.id == "race300" {
            guard let youID = ctx.memberWeekLogs.first(where: { $0.member.isYou })?.member.id
            else { return false }
            return raceWinnerID(memberWeekLogs: ctx.memberWeekLogs, threshold: def.target) == youID
        }
        return current(for: def, ctx: ctx) >= def.target
    }

    /// Challenges completed now but not yet recorded — AppState records the
    /// key and awards the XP exactly once.
    static func newlyCompleted(_ ctx: Context) -> [(key: String, definition: Definition)] {
        definitions.compactMap { def in
            if def.id == "goal3", ctx.hardestPrayer == nil { return nil }
            let key = completionKey(for: def, weekKey: ctx.weekKey)
            guard ctx.completions[key] == nil, isCompletedNow(def, ctx: ctx) else { return nil }
            return (key, def)
        }
    }

    // MARK: - Race to 300

    /// The member whose cumulative weekly XP crossed `threshold` EARLIEST
    /// (by log timestamps). nil while nobody has crossed.
    static func raceWinnerID(memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])],
                             threshold: Int = 300) -> String? {
        var winner: (id: String, at: Date)?
        for entry in memberWeekLogs {
            var running = 0
            for log in entry.logs.sorted(by: { $0.loggedAt < $1.loggedAt }) {
                running += log.xp
                if running >= threshold {
                    if winner == nil || log.loggedAt < winner!.at {
                        winner = (entry.member.id, log.loggedAt)
                    }
                    break
                }
            }
        }
        return winner?.id
    }

    /// Weekly XP for a member's week-logs (per-day XP incl. perfect bonus —
    /// matches the scoreboard math).
    static func memberWeeklyXP(logs: [PrayerLog]) -> Int {
        Set(logs.map(\.dayKey)).reduce(0) { $0 + GameEngine.xp(forDay: $1, logs: logs) }
    }

    // MARK: - Helpers

    /// Length of the consecutive-day run satisfying `satisfies`, ending today
    /// — or ending yesterday when today doesn't (yet) satisfy it. A gap
    /// before the run resets the count.
    static func consecutiveRun(dayKeys: [String], todayKey: String,
                               satisfies: (String) -> Bool) -> Int {
        guard var idx = dayKeys.lastIndex(of: todayKey) else { return 0 }
        if !satisfies(dayKeys[idx]) { idx -= 1 }   // today still pending — run may end yesterday
        var run = 0
        while idx >= 0, satisfies(dayKeys[idx]) {
            run += 1
            idx -= 1
        }
        return run
    }

    private static func weekDayKeysThroughToday(_ ctx: Context) -> [String] {
        if let todayIdx = ctx.weekDayKeys.firstIndex(of: ctx.todayKey) {
            return Array(ctx.weekDayKeys.prefix(through: todayIdx))
        }
        return ctx.weekDayKeys
    }

    private static func hasInWindowLog(_ logs: [PrayerLog], prayer: Prayer, dayKey: String) -> Bool {
        logs.contains { $0.prayer == prayer && $0.dayKey == dayKey && $0.tier.isInWindow }
    }

    private static func inWindowCount(logs: [PrayerLog], dayKey: String) -> Int {
        Set(logs.lazy.filter { $0.dayKey == dayKey && $0.tier.isInWindow }.map(\.prayer)).count
    }

    private static func isFullInWindowDay(logs: [PrayerLog], dayKey: String) -> Bool {
        inWindowCount(logs: logs, dayKey: dayKey) == Prayer.allCases.count
    }
}
