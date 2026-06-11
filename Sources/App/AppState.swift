import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var profile: UserProfile
    @Published private(set) var logs: [PrayerLog]          // full history
    @Published var settings: AppSettings {
        didSet {
            Store.save(settings, to: Store.settingsFile)
            refresh()
            // Settings changes (calc method, location, notifications toggle,
            // onboarding completion) all affect the notification schedule.
            NotificationManager.shared.reschedule()
        }
    }
    @Published private(set) var todaySchedule: DaySchedule?
    @Published var celebration: LogResult?                 // set by log(); UI presents then nils it

    /// Yesterday's isha window — it may still be open past midnight
    /// (it ends at TODAY's fajr). Used so a 1 AM isha log counts for yesterday.
    private var previousIshaWindow: PrayerWindow?
    private var previousDayKey: String = ""

    let location = LocationProvider.shared

    // MARK: - Init

    init() {
        let now = AppClock.now
        profile = Store.load(Store.profileFile, default: UserProfile.fresh(now: now))
        logs = Store.load(Store.logsFile, default: [PrayerLog]())
        settings = Store.load(Store.settingsFile, default: AppSettings())
        location.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - Derived state

    var todayKey: String { AppClock.dayKey(for: AppClock.now) }

    var todayLogs: [PrayerLog] { logs.filter { $0.dayKey == todayKey } }

    /// Logs + bonuses earned today (perfect-day bonus included).
    var todayXP: Int { GameEngine.xp(forDay: todayKey, logs: logs) }

    var level: Int { GameEngine.level(forTotalXP: profile.totalXP) }
    var levelTitle: String { GameEngine.title(forLevel: level) }
    var xpIntoLevel: Int { GameEngine.xpIntoLevel(forTotalXP: profile.totalXP) }
    var xpNeededForLevel: Int { GameEngine.xpToAdvance(from: level) }

    /// Coordinates currently in use (device fix or fixed fallback).
    var activeCoordinates: (latitude: Double, longitude: Double) {
        if settings.useDeviceLocation, let coord = location.deviceCoordinate {
            return (coord.latitude, coord.longitude)
        }
        return (settings.fixedLatitude, settings.fixedLongitude)
    }

    /// True when the schedule is using the device's real location.
    var isUsingDeviceLocation: Bool {
        settings.useDeviceLocation && location.deviceCoordinate != nil
    }

    var activeLocationName: String {
        isUsingDeviceLocation ? (location.placeName ?? "Current location") : settings.locationName
    }

    // MARK: - Status

    func status(of prayer: Prayer) -> PrayerStatus {
        let now = AppClock.now

        // Yesterday's isha can still be open past midnight.
        if prayer == .isha,
           let prev = previousIshaWindow,
           now >= prev.start, now < prev.end,
           !hasLog(prayer: .isha, dayKey: previousDayKey) {
            return .open(closesAt: prev.end)
        }

        if let log = todayLogs.first(where: { $0.prayer == prayer }) {
            return .logged(log.tier)
        }
        guard let window = todaySchedule?.window(for: prayer) else {
            return .upcoming(opensAt: now)
        }
        if now < window.start { return .upcoming(opensAt: window.start) }
        if now < window.end { return .open(closesAt: window.end) }
        return .missedWindow
    }

    /// Tier if the prayer were logged right now (nil if its window hasn't opened).
    func potentialTier(for prayer: Prayer) -> LogTier? {
        guard let target = targetWindow(for: prayer) else { return nil }
        return GameEngine.tier(for: target.window, at: AppClock.now)
    }

    /// The window + schedule-day a log of `prayer` right now would attach to.
    /// Handles isha crossing midnight: before today's fajr, an unlogged
    /// yesterday-isha is the live target with YESTERDAY's dayKey.
    private func targetWindow(for prayer: Prayer) -> (window: PrayerWindow, dayKey: String)? {
        let now = AppClock.now
        if prayer == .isha,
           let prev = previousIshaWindow,
           now >= prev.start, now < prev.end,
           !hasLog(prayer: .isha, dayKey: previousDayKey) {
            return (prev, previousDayKey)
        }
        guard let window = todaySchedule?.window(for: prayer) else { return nil }
        return (window, todayKey)
    }

    private func hasLog(prayer: Prayer, dayKey: String) -> Bool {
        logs.contains { $0.prayer == prayer && $0.dayKey == dayKey }
    }

    // MARK: - Logging

    func log(_ prayer: Prayer) {
        guard let target = targetWindow(for: prayer) else { return }            // not computable / upcoming
        guard !hasLog(prayer: prayer, dayKey: target.dayKey) else { return }    // double-log = no-op
        guard let tier = GameEngine.tier(for: target.window, at: AppClock.now) else { return } // window not open yet

        // Qada only for the current schedule day — targetWindow() already
        // restricts us to today's (or the still-open yesterday-isha) windows,
        // so a qada tier here is always same-schedule-day.

        let levelBefore = GameEngine.level(forTotalXP: profile.totalXP)
        let wasPerfect = GameEngine.isPerfectDay(logs: logs, dayKey: target.dayKey)

        let entry = PrayerLog(id: UUID(), prayer: prayer, dayKey: target.dayKey,
                              loggedAt: AppClock.now, tier: tier, xp: tier.xp)
        logs.append(entry)

        var newProfile = profile
        newProfile.totalXP += tier.xp

        var bonusXP = 0
        var perfectDay = false
        if !wasPerfect, GameEngine.isPerfectDay(logs: logs, dayKey: target.dayKey) {
            perfectDay = true
            bonusXP = GameEngine.perfectDayBonus
            newProfile.totalXP += bonusXP
            newProfile.perfectDayCount += 1
        }

        var streakExtended = false
        if GameEngine.isDayComplete(logs: logs, dayKey: target.dayKey),
           newProfile.lastStreakDayKey != target.dayKey {
            newProfile = GameEngine.applyStreakIncrement(to: newProfile, dayKey: target.dayKey)
            streakExtended = true
        }

        let newBadgeIDs = Badges.newlyEarnedIDs(profile: newProfile, logs: logs)
        for id in newBadgeIDs { newProfile.earnedBadges[id] = AppClock.now }

        let leveledUp = GameEngine.level(forTotalXP: newProfile.totalXP) > levelBefore

        profile = newProfile
        persist()

        celebration = LogResult(prayer: prayer, tier: tier, xpEarned: tier.xp, bonusXP: bonusXP,
                                newBadgeIDs: newBadgeIDs, leveledUp: leveledUp,
                                perfectDay: perfectDay, streakExtended: streakExtended)
    }

    func undoLog(_ prayer: Prayer) {
        // Prefer the live target day (handles the past-midnight isha case),
        // else fall back to a log made today.
        let dayKey = targetWindow(for: prayer)?.dayKey ?? todayKey
        guard let index = logs.lastIndex(where: { $0.prayer == prayer && ($0.dayKey == dayKey || $0.dayKey == todayKey) })
        else { return }
        let removed = logs[index]

        let wasPerfect = GameEngine.isPerfectDay(logs: logs, dayKey: removed.dayKey)
        let wasComplete = GameEngine.isDayComplete(logs: logs, dayKey: removed.dayKey)

        logs.remove(at: index)

        var newProfile = profile
        newProfile.totalXP = max(0, newProfile.totalXP - removed.xp)
        if wasPerfect {
            newProfile.totalXP = max(0, newProfile.totalXP - GameEngine.perfectDayBonus)
            newProfile.perfectDayCount = max(0, newProfile.perfectDayCount - 1)
        }
        if wasComplete {
            newProfile = GameEngine.reverseStreakIncrement(on: newProfile, dayKey: removed.dayKey)
        }
        // Badges are intentionally NOT revoked on undo.

        profile = newProfile
        persist()
    }

    // MARK: - League

    func leaderboard() -> [LeaderboardEntry] {
        let now = AppClock.now
        var entries = FriendSimulator.entries(at: now)
        let myXP = GameEngine.weeklyXP(logs: logs, weekStart: FriendSimulator.weekStart(for: now))
        let myName = profile.name.isEmpty ? "You" : profile.name
        entries.append(LeaderboardEntry(id: "you", name: myName, avatar: "😄", xp: myXP, isYou: true))
        return entries.sorted { $0.xp > $1.xp }
    }

    func leagueResetDate() -> Date {
        FriendSimulator.weekEnd(for: AppClock.now)
    }

    // MARK: - Recaps

    /// Oldest → newest, includes today as the last element.
    func recaps(daysBack: Int) -> [DayRecap] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: AppClock.now)
        var result: [DayRecap] = []
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let key = AppClock.dayKey(for: date)
            let dayLogs = logs.filter { $0.dayKey == key }
            result.append(DayRecap(dayKey: key,
                                   date: date,
                                   loggedCount: dayLogs.count,
                                   inWindowCount: dayLogs.filter { $0.tier.isInWindow }.count,
                                   xp: GameEngine.xp(forDay: key, logs: logs),
                                   isPerfect: GameEngine.isPerfectDay(logs: logs, dayKey: key)))
        }
        return result
    }

    // MARK: - Refresh (schedule + streak reconcile)

    /// Recompute today's schedule and reconcile the streak for elapsed days.
    /// Call on launch, foreground, day change, and settings change.
    func refresh() {
        let now = AppClock.now
        let coords = activeCoordinates
        let calendar = Calendar.current

        todaySchedule = PrayerTimeService.schedule(for: now,
                                                   latitude: coords.latitude,
                                                   longitude: coords.longitude,
                                                   method: settings.calcMethod,
                                                   madhab: settings.madhab)

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            previousDayKey = AppClock.dayKey(for: yesterday)
            previousIshaWindow = PrayerTimeService.schedule(for: yesterday,
                                                            latitude: coords.latitude,
                                                            longitude: coords.longitude,
                                                            method: settings.calcMethod,
                                                            madhab: settings.madhab)?
                .window(for: .isha)
        }

        reconcileStreakIfNeeded(now: now, calendar: calendar)

        if settings.useDeviceLocation {
            location.refreshLocation()
        }
    }

    /// Walk every elapsed day from the day after `lastReconciledDayKey`
    /// through yesterday. Incomplete day → consume a freeze, else streak → 0.
    /// Never touches today.
    private func reconcileStreakIfNeeded(now: Date, calendar: Calendar) {
        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return }
        let yesterdayKey = AppClock.dayKey(for: yesterdayStart)

        guard let lastKey = profile.lastReconciledDayKey,
              let lastDate = AppClock.date(fromDayKey: lastKey) else {
            // First run (or unparseable state): start the ledger at yesterday
            // without penalizing pre-install days.
            if profile.lastReconciledDayKey != yesterdayKey {
                profile.lastReconciledDayKey = yesterdayKey
                persistProfile()
            }
            return
        }
        guard lastDate < yesterdayStart else { return }   // nothing new (or time-traveled backwards)

        var elapsed: [(dayKey: String, isComplete: Bool)] = []
        var day = calendar.date(byAdding: .day, value: 1, to: lastDate) ?? yesterdayStart
        while day <= yesterdayStart {
            let key = AppClock.dayKey(for: day)
            elapsed.append((key, GameEngine.isDayComplete(logs: logs, dayKey: key)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !elapsed.isEmpty else { return }
        profile = GameEngine.reconcile(profile: profile, elapsedDays: elapsed)
        persistProfile()
    }

    // MARK: - Persistence

    private func persist() {
        Store.save(profile, to: Store.profileFile)
        Store.save(logs, to: Store.logsFile)
    }

    private func persistProfile() {
        Store.save(profile, to: Store.profileFile)
    }

    // MARK: - Profile edits

    func setName(_ name: String) {
        profile.name = name
        persistProfile()
    }

    // MARK: - DEBUG helpers

    /// 21 days of plausible history ending yesterday; profile is rebuilt from
    /// the generated logs so XP/streak/badges/perfect days stay consistent.
    func fillDemoHistory() {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: AppClock.now)
        var rng = SplitMix64(seed: 0xDE_0B6B3A_7640_0042)
        var generated: [PrayerLog] = []

        for offset in stride(from: 21, through: 1, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let key = AppClock.dayKey(for: dayStart)
            for (i, prayer) in Prayer.allCases.enumerated() {
                let roll = rng.uniform()
                guard roll < 0.88 else { continue }    // ~12% missed outright
                let tierRoll = rng.uniform()
                let tier: LogTier = tierRoll < 0.55 ? .onTime
                    : tierRoll < 0.78 ? .prayed
                    : tierRoll < 0.90 ? .lastCall
                    : .qada
                let loggedAt = dayStart.addingTimeInterval(Double(6 + i * 3) * 3600 + rng.uniform() * 1800)
                generated.append(PrayerLog(id: UUID(), prayer: prayer, dayKey: key,
                                           loggedAt: loggedAt, tier: tier, xp: tier.xp))
            }
        }

        logs = generated.sorted { $0.loggedAt < $1.loggedAt }

        // Rebuild the profile from the logs.
        var p = UserProfile.fresh(now: AppClock.now)
        p.name = profile.name
        p.joinedAt = calendar.date(byAdding: .day, value: -21, to: todayStart) ?? profile.joinedAt

        var dayKeys: [String] = []
        for offset in stride(from: 21, through: 1, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: todayStart) {
                dayKeys.append(AppClock.dayKey(for: d))
            }
        }
        for key in dayKeys {
            p.totalXP += logs.filter { $0.dayKey == key }.reduce(0) { $0 + $1.xp }
            if GameEngine.isPerfectDay(logs: logs, dayKey: key) {
                p.totalXP += GameEngine.perfectDayBonus
                p.perfectDayCount += 1
            }
            if GameEngine.isDayComplete(logs: logs, dayKey: key) {
                p = GameEngine.applyStreakIncrement(to: p, dayKey: key)
            } else if p.streakFreezes > 0 {
                p.streakFreezes -= 1
            } else {
                p.streak = 0
            }
        }
        p.lastReconciledDayKey = dayKeys.last
        for id in Badges.satisfiedBadgeIDs(profile: p, logs: logs) {
            p.earnedBadges[id] = AppClock.now
        }

        profile = p
        persist()
        refresh()
    }

    func resetAllData() {
        logs = []
        profile = UserProfile.fresh(now: AppClock.now)
        settings = AppSettings()       // didSet persists + refreshes
        Store.delete(Store.logsFile)
        Store.delete(Store.profileFile)
        persist()
        refresh()
    }
}
