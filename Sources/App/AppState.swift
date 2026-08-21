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

    /// v4: the offline mirror of a real circle (SPEC-V4 §8). Held in memory
    /// rather than re-read per access, because `circleSource` is consulted
    /// several times per render and must never touch the disk to draw a grid.
    /// `.empty` covers demo mode, a solo account and a first launch alike.
    @Published private(set) var circleSnapshot: CircleSnapshot = .empty

    /// Yesterday's isha window — it may still be open past midnight
    /// (it ends at TODAY's fajr). Used so a 1 AM isha log counts for yesterday.
    private var previousIshaWindow: PrayerWindow?
    private var previousDayKey: String = ""

    /// Per-dayKey schedule cache for circle grids/weeks. Cleared on refresh()
    /// so settings/location changes recompute. Pure function of dayKey —
    /// time-travel safe.
    private var scheduleCache: [String: DaySchedule] = [:]

    let location = LocationProvider.shared

    // MARK: - Init

    init() {
        let now = AppClock.now
        profile = Store.load(Store.profileFile, default: UserProfile.fresh(now: now))
        logs = Store.load(Store.logsFile, default: [PrayerLog]())
        settings = Store.load(Store.settingsFile, default: AppSettings())
        // Offline-first: whatever the last sync left on disk is the circle we
        // render, before any network work has been attempted.
        circleSnapshot = CircleSnapshot.load()
        location.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - Derived state

    var todayKey: String { AppClock.dayKey(for: AppClock.now) }

    var todayLogs: [PrayerLog] { logs.filter { $0.dayKey == todayKey } }

    /// Logs + bonuses earned today (perfect-day bonus included).
    var todayXP: Int { GameEngine.xp(forDay: todayKey, logs: logs, excusedDayKeys: profile.excusedDayKeys) }

    var level: Int { GameEngine.level(forTotalXP: profile.totalXP) }
    var levelTitle: String { GameEngine.title(forLevel: level) }
    var xpIntoLevel: Int { GameEngine.xpIntoLevel(forTotalXP: profile.totalXP) }
    var xpNeededForLevel: Int { GameEngine.xpToAdvance(from: level) }

    /// Foregone XP from missed windows today ("You missed out on +N XP").
    var missedOutXPToday: Int {
        guard let schedule = todaySchedule else { return 0 }
        return GameEngine.missedOutXP(logs: logs, schedule: schedule,
                                      now: AppClock.now, isExcused: isTodayExcused)
    }

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

    // MARK: - Logging (v2)

    /// In-window logging path. The UI guarantees a photo; nil is tolerated
    /// (photo-save failure must never lose the prayer). If the window already
    /// passed this also handles the qada path (photo/jamaat are dropped).
    func log(_ prayer: Prayer, photoFilename: String? = nil, jamaat: Bool = false,
             placeTag: PlaceTag? = nil, placeName: String? = nil) {
        guard let target = targetWindow(for: prayer) else { return }            // not computable / upcoming
        guard !hasLog(prayer: prayer, dayKey: target.dayKey) else { return }    // double-log = no-op
        guard let tier = GameEngine.tier(for: target.window, at: AppClock.now) else { return } // window not open yet

        let snapshot = preLogSnapshot(dayKey: target.dayKey)
        let entry = buildLog(prayer: prayer, dayKey: target.dayKey, tier: tier,
                             photoFilename: photoFilename, jamaat: jamaat,
                             placeTag: placeTag, placeName: placeName)
        logs.append(entry)
        finalizeLogging(added: [entry], snapshot: snapshot,
                        celebrationPrayer: prayer, celebrationTier: tier, dayKey: target.dayKey)
    }

    /// v3.3: travel (jam') — log the lead prayer AND its partner together from
    /// one photo. Both earn the tier computed against the COMBINED window
    /// [lead.start, follow.end], so combining early still earns the most. Both
    /// share the photo; each computes its own (Jumma-aware) congregation bonus.
    func logCombined(lead: Prayer, photoFilename: String? = nil, jamaat: Bool = false,
                     placeTag: PlaceTag? = nil, placeName: String? = nil) {
        guard let follow = TravelPairs.partner(of: lead),
              TravelPairs.lead(of: lead) == lead,
              let combined = combinedWindow(lead: lead),
              let tier = GameEngine.tier(for: combined, at: AppClock.now) else {
            log(lead, photoFilename: photoFilename, jamaat: jamaat,
                placeTag: placeTag, placeName: placeName)
            return
        }
        let dayKey = todaySchedule?.dayKey ?? todayKey
        let snapshot = preLogSnapshot(dayKey: dayKey)

        var added: [PrayerLog] = []
        for prayer in [lead, follow] where !hasLog(prayer: prayer, dayKey: dayKey) {
            added.append(buildLog(prayer: prayer, dayKey: dayKey, tier: tier,
                                  photoFilename: photoFilename, jamaat: jamaat,
                                  placeTag: placeTag, placeName: placeName))
        }
        guard !added.isEmpty else { return }
        logs.append(contentsOf: added)
        finalizeLogging(added: added, snapshot: snapshot,
                        celebrationPrayer: lead, celebrationTier: tier, dayKey: dayKey)
    }

    /// The merged window for a travel pair: [lead.start, follow.end].
    func combinedWindow(lead: Prayer) -> PrayerWindow? {
        guard let follow = TravelPairs.partner(of: lead),
              let leadWin = todaySchedule?.window(for: lead),
              let followWin = todaySchedule?.window(for: follow) else { return nil }
        return PrayerWindow(prayer: lead, start: leadWin.start, end: followWin.end)
    }

    /// Builds a single in-window/qada log, applying the in-window normalization
    /// (photo/jamaat/place dropped for qada), the Jumma-aware congregation
    /// bonus, and the remember-place side effect.
    private func buildLog(prayer: Prayer, dayKey: String, tier: LogTier,
                          photoFilename: String?, jamaat: Bool,
                          placeTag: PlaceTag?, placeName: String?) -> PrayerLog {
        let inWindow = tier.isInWindow
        let normalizedPhoto: String? = {
            guard inWindow, let name = photoFilename, !name.isEmpty else { return nil }
            return name
        }()
        let countsJamaat = inWindow && jamaat
        let countsPlace: PlaceTag? = inWindow ? placeTag : nil
        if let tag = countsPlace { rememberPlaceIfNeeded(tag) }
        // v3.8: jamaat is a floor (counts as on-time), not an additive bonus.
        let xp = GameEngine.prayerXP(tier: tier, jamaat: countsJamaat)
        return PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                         loggedAt: AppClock.now, tier: tier, xp: xp,
                         photoFilename: normalizedPhoto, jamaat: countsJamaat,
                         placeTag: countsPlace,
                         placeName: countsPlace == .onTheGo ? placeName : nil)
    }

    private struct PreLogSnapshot {
        let levelBefore: Int
        let wasPerfect: Bool
    }

    private func preLogSnapshot(dayKey: String) -> PreLogSnapshot {
        PreLogSnapshot(levelBefore: GameEngine.level(forTotalXP: profile.totalXP),
                       wasPerfect: GameEngine.isPerfectDay(logs: logs, dayKey: dayKey,
                                                           excusedDayKeys: profile.excusedDayKeys))
    }

    /// Shared post-log processing for both single and combined logging:
    /// XP, perfect-day bonus, streak, badges, level-up, persistence, and the
    /// celebration. `added` may hold one log (single) or two (combined); XP is
    /// summed so a combined post celebrates the full amount.
    private func finalizeLogging(added: [PrayerLog], snapshot: PreLogSnapshot,
                                 celebrationPrayer: Prayer, celebrationTier: LogTier, dayKey: String) {
        let excused = profile.excusedDayKeys.contains(dayKey)
        var newProfile = profile
        let addedXP = added.reduce(0) { $0 + $1.xp }
        newProfile.totalXP += addedXP

        var bonusXP = 0
        var perfectDay = false
        if !snapshot.wasPerfect,
           GameEngine.isPerfectDay(logs: logs, dayKey: dayKey,
                                   excusedDayKeys: profile.excusedDayKeys) {
            perfectDay = true
            bonusXP = GameEngine.perfectDayBonus
            newProfile.totalXP += bonusXP
            newProfile.perfectDayCount += 1
        }

        var streakExtended = false
        if !excused,
           GameEngine.isDayComplete(logs: logs, dayKey: dayKey),
           newProfile.lastStreakDayKey != dayKey {
            newProfile = GameEngine.applyStreakIncrement(to: newProfile, dayKey: dayKey)
            streakExtended = true
        }

        let newBadgeIDs = Badges.newlyEarnedIDs(profile: newProfile, logs: logs)
        for id in newBadgeIDs { newProfile.earnedBadges[id] = AppClock.now }
        let leveledUp = GameEngine.level(forTotalXP: newProfile.totalXP) > snapshot.levelBefore

        profile = newProfile
        persist()
        awardNewlyCompletedChallenges()
        // The just-logged prayer's pending "Last call" must be dropped.
        NotificationManager.shared.reschedule()

        celebration = LogResult(prayer: celebrationPrayer, tier: celebrationTier,
                                xpEarned: addedXP, bonusXP: bonusXP,
                                newBadgeIDs: newBadgeIDs, leveledUp: leveledUp,
                                perfectDay: perfectDay, streakExtended: streakExtended)
    }

    /// Make-up path: tap-only, no photo, qada XP (5). Only effective once the
    /// window has passed (same schedule day).
    func logQada(_ prayer: Prayer) {
        log(prayer, photoFilename: nil, jamaat: false)
    }

    // MARK: - Editing past days (v3.6 — design session)

    /// "I made it up but forgot to log it": retroactively mark a PAST day's
    /// prayer as made up, from the Journey day sheet. Recent edits (≤2 days)
    /// still earn qada XP; older ones earn nothing — same-day logging stays
    /// the incentive. Never touches streak history (those days were already
    /// reconciled).
    func logPastMakeUp(_ prayer: Prayer, dayKey: String) {
        guard dayKey < todayKey,                                   // past days only
              !hasLog(prayer: prayer, dayKey: dayKey),
              !isExcused(prayer: prayer, dayKey: dayKey) else { return }
        let xp = GameEngine.lateEditXP(dayKey: dayKey, todayKey: todayKey)
        logs.append(PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                              loggedAt: AppClock.now, tier: .qada, xp: xp))
        profile.totalXP += xp
        persist()
        objectWillChange.send()
    }

    /// XP a retroactive make-up of `dayKey` would earn right now.
    func lateEditXP(forDayKey dayKey: String) -> Int {
        GameEngine.lateEditXP(dayKey: dayKey, todayKey: todayKey)
    }

    func undoLog(_ prayer: Prayer) {
        // Prefer the live target day, else fall back to a log made today.
        let dayKey = targetWindow(for: prayer)?.dayKey ?? todayKey
        var candidateDayKeys: Set<String> = [dayKey, todayKey]
        // §6.8: an isha logged past midnight carries YESTERDAY's dayKey, and
        // once that log exists targetWindow no longer points at the previous
        // window (its hasLog check trips and it falls through to today), so
        // the yesterday-keyed log must be matched explicitly.
        if prayer == .isha { candidateDayKeys.insert(previousDayKey) }
        guard let index = logs.lastIndex(where: { $0.prayer == prayer && candidateDayKeys.contains($0.dayKey) })
        else { return }
        let removed = logs[index]

        let wasPerfect = GameEngine.isPerfectDay(logs: logs, dayKey: removed.dayKey,
                                                 excusedDayKeys: profile.excusedDayKeys)
        let wasComplete = GameEngine.isDayComplete(logs: logs, dayKey: removed.dayKey)

        logs.remove(at: index)

        // Undo removes the photo file too — the grid returns to its CTA state.
        // v3.3: a combined (travel) pair shares one photo, so only delete the
        // file once no remaining log still references it.
        if let photo = removed.photoFilename,
           !logs.contains(where: { $0.photoFilename == photo }) {
            PhotoStore.delete(photo)
        }

        var newProfile = profile
        newProfile.totalXP = max(0, newProfile.totalXP - removed.xp)   // includes any jamaat bonus
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
        // The prayer is unlogged again — restore its "Last call" if applicable.
        NotificationManager.shared.reschedule()
    }

    // MARK: - Travel mode (v3.3)

    var isTraveling: Bool { settings.isTraveling }

    func setTraveling(_ on: Bool) {
        guard settings.isTraveling != on else { return }
        settings.isTraveling = on   // didSet persists + refreshes + reschedules
        objectWillChange.send()
    }

    /// Auto-suggest travel mode: you've saved a Home and you're currently far
    /// (>80 km) from it. Manual toggle is always available regardless.
    func shouldSuggestTravel() -> Bool {
        guard !settings.isTraveling,
              let home = settings.savedPlaces[PlaceTag.home.rawValue],
              let coord = location.deviceCoordinate else { return false }
        return home.distanceMeters(latitude: coord.latitude, longitude: coord.longitude) > 80_000
    }

    // MARK: - Excused days (v2) / "Can't pray" break mode (v3.2)

    var isTodayExcused: Bool { profile.excusedDayKeys.contains(todayKey) }

    /// v3.6: per-PRAYER excuse check. A break that starts at Asr must not
    /// repaint that morning's Fajr as excused (and a mid-day resume must let
    /// the rest of the day count again). Day-level semantics (streak,
    /// calendar) still use `excusedDayKeys` membership.
    func isExcused(prayer: Prayer, dayKey: String) -> Bool {
        guard profile.excusedDayKeys.contains(dayKey) else { return false }
        let order = Prayer.allCases
        guard let idx = order.firstIndex(of: prayer) else { return false }
        if let start = profile.partialExcuseStart[dayKey],
           let s = order.firstIndex(of: start), idx < s { return false }
        if let end = profile.partialExcuseEnd[dayKey],
           let e = order.firstIndex(of: end), idx >= e { return false }
        return true
    }

    var excusedUsedThisMonth: Int {
        GameEngine.excusedCount(in: profile.excusedDayKeys, monthOf: todayKey)
    }

    /// v3.2: excused is now a MODE — start a break, every day while it's
    /// active is auto-marked excused, then "Resume prayers" ends it. No
    /// monthly cap; the accountability is that the circle sees the break.
    var isOnBreak: Bool { profile.excusedModeSince != nil }
    var breakReason: String? { profile.breakReason }

    // v3.4: gender (from onboarding) tailors the break flow. "Prefer not to
    // say" → both nil → the unified break.
    var isSister: Bool { settings.memberKind == "sister" }
    var isBrother: Bool { settings.memberKind == "brother" }

    /// v3.4: reason tailors copy + reminder cadence. A period break commonly
    /// runs ~7–10 days (and its prayers are waived, never made up); other
    /// breaks nudge sooner. v3.6: a soft reminder lands at 7 days for periods
    /// ("max is ~10, but everyone's different").
    ///
    /// v3.6 partial-day rule (design session): the excuse covers prayers from
    /// the CURRENT time block onward. Anything already logged today keeps
    /// counting, and an earlier missed prayer is NOT retroactively excused.
    func startBreak(reason: String? = nil) {
        guard !isOnBreak else { return }
        profile.breakReason = reason
        if let startPrayer = breakStartPrayer() {
            profile.excusedModeSince = todayKey
            profile.excusedDayKeys.insert(todayKey)
            if startPrayer != Prayer.allCases.first {
                profile.partialExcuseStart[todayKey] = startPrayer
            }
        } else {
            // Today is fully decided (everything logged/passed) — the break
            // effectively starts tomorrow.
            profile.excusedModeSince = AppClock.dayKey(
                for: AppClock.now.addingTimeInterval(24 * 3600))
        }
        persistProfile()
        NotificationManager.shared.scheduleBreakReminder(daysFromNow: reason == "period" ? 7 : 5,
                                                         reason: reason)
        objectWillChange.send()
    }

    /// First prayer of today the break should waive: the earliest unlogged
    /// prayer whose window is still open or ahead. nil → nothing left today.
    private func breakStartPrayer() -> Prayer? {
        guard let schedule = todaySchedule else { return Prayer.allCases.first }
        let now = AppClock.now
        for window in schedule.windows.sorted(by: { $0.start < $1.start }) {
            guard !hasLog(prayer: window.prayer, dayKey: todayKey) else { continue }
            if now < window.end { return window.prayer }
            // ended & unlogged — that miss predates the break; not excused.
        }
        return nil
    }

    /// End the break. `startingAgainAt` is the answer to "When did you start
    /// praying again?" — prayers from that one onward count today; earlier
    /// ones stay excused. nil (or the day's first prayer) un-excuses the
    /// whole day.
    func resumePrayers(startingAgainAt prayer: Prayer? = nil) {
        guard isOnBreak else { return }
        profile.excusedModeSince = nil
        profile.breakReason = nil
        if let prayer,
           let idx = Prayer.allCases.firstIndex(of: prayer), idx > 0,
           profile.excusedDayKeys.contains(todayKey) {
            profile.partialExcuseEnd[todayKey] = prayer
        } else {
            profile.excusedDayKeys.remove(todayKey)
            profile.partialExcuseStart[todayKey] = nil
            profile.partialExcuseEnd[todayKey] = nil
        }
        persistProfile()
        NotificationManager.shared.cancelBreakReminder()
        NotificationManager.shared.reschedule()
        objectWillChange.send()
    }

    /// Banner copy for the active break, tailored to the reason.
    var breakCopy: (headline: String, subtext: String) {
        switch profile.breakReason {
        case "period":
            return ("On a break 🌸",
                    "Your prayers are waived while you rest — nothing to make up. Streak's safe, and dhikr earns private XP.")
        case "illness":
            return ("Resting up 💜", "Feel better — your streak is safe until you resume.")
        default:
            return ("On a break 💜", "Your streak is safe until you resume.")
        }
    }

    /// Legacy single-day toggle (kept for the pre-mode UI path); no cap.
    func setTodayExcused(_ on: Bool) {
        let key = todayKey
        if on {
            guard !profile.excusedDayKeys.contains(key) else { return }
            profile.excusedDayKeys.insert(key)
        } else {
            profile.excusedDayKeys.remove(key)
        }
        persistProfile()
    }

    // MARK: - Recharge: dhikr + good deeds (v3.8 — permanent, for everyone)

    var dhikrToday: Int { profile.dhikrByDay[todayKey] ?? 0 }
    var recoveryXPToday: Int { profile.recoveryXPByDay[todayKey] ?? 0 }

    /// Today's prayer-only XP (logs + perfect-day bonus), used to size the
    /// recovery cap for someone who CAN pray (combined ceiling of 150).
    var prayerXPToday: Int {
        let base = todayLogs.reduce(0) { $0 + $1.xp }
        let perfect = GameEngine.isPerfectDay(logs: logs, dayKey: todayKey,
                                              excusedDayKeys: profile.excusedDayKeys)
        return base + (perfect ? GameEngine.perfectDayBonus : 0)
    }

    /// v3.8: dhikr ceiling depends on state — 200 on a break, else only enough
    /// to top a prayed day up to 150.
    var recoveryDailyCap: Int {
        GameEngine.recoveryDailyCap(onBreak: isOnBreak, prayerXPToday: prayerXPToday)
    }

    /// The headline number shown on the Dhikr tab ("up to N"): the flat
    /// ceiling for your state — 200 on a break, 150 otherwise — NOT the
    /// prayer-adjusted remainder, which read as a confusing "135".
    var recoveryDisplayCeiling: Int {
        isOnBreak ? GameEngine.recoveryBreakCap : GameEngine.recoveryDayCeiling
    }
    var recoveryXPRemaining: Int { max(0, recoveryDailyCap - recoveryXPToday) }
    var isRecoveryCapped: Bool { recoveryXPRemaining == 0 }
    var deedsDoneToday: Set<String> { Set(profile.deedsByDay[todayKey] ?? []) }

    /// Tasbih tap: ALWAYS counts (unlimited, never blocked). XP accrues only up
    /// to today's cap — past it the act continues, just without points.
    func tapTasbih() {
        profile.dhikrByDay[todayKey, default: 0] += 1
        awardRecoveryXP(GameEngine.dhikrXP)
        persistProfile()
    }

    /// Complete a good-deed prompt for today: once per deed per day, +deedXP
    /// (subject to the same shared cap).
    func completeDeed(_ id: String) {
        guard !deedsDoneToday.contains(id) else { return }
        profile.deedsByDay[todayKey, default: []].append(id)
        awardRecoveryXP(GameEngine.deedXP)
        persistProfile()
    }

    /// Grant up to `amount` XP, never exceeding today's state-aware cap.
    private func awardRecoveryXP(_ amount: Int) {
        let granted = GameEngine.recoveryGrant(amount: amount, earnedToday: recoveryXPToday,
                                               onBreak: isOnBreak, prayerXPToday: prayerXPToday)
        guard granted > 0 else { return }
        profile.totalXP += granted
        profile.recoveryXPByDay[todayKey, default: 0] += granted
    }

    /// Legacy alias (older call sites) — one tasbih tap.
    func logDhikr() { tapTasbih() }

    // MARK: - Circle (v2; v4 seam)

    /// v4: everything about the OTHER members of the circle is answered here —
    /// the local simulator in demo mode, the offline mirror of a real circle
    /// otherwise (SPEC-V4 §8). "You" is still appended by AppState.
    ///
    /// Computed, not stored: it derives from `profile`/`settings`/the mirror on
    /// every read exactly as `activeBuddies` always has, so no circle mutation
    /// can leave it stale.
    var circleSource: any CircleDataSource {
        switch settings.circleMode {
        case .demo:
            return SimulatedCircleDataSource(buddies: activeBuddies)
        case .real:
            // Answered entirely from the local mirror, so a real circle draws
            // the same offline as it did on the last sync. A mirror that is
            // empty (or absent) is simply a circle with nobody in it yet.
            return RemoteCircleDataSource(snapshot: circleSnapshot)
        }
    }

    /// Phase B3+: `CircleService` hands the freshly synced mirror over here.
    /// Persisting it is the service's job — `AppState` only renders it.
    func applyCircleSnapshot(_ snapshot: CircleSnapshot) {
        circleSnapshot = snapshot
    }

    /// v3.6: the circle as the user shaped it (removals + accepted invites).
    /// v3.9: a solo account's circle is its invites and nothing else.
    /// v4: demo-only — a real circle's roster comes from `circleSource`.
    var activeBuddies: [BuddySimulator.Buddy] {
        guard settings.circleMode == .demo else { return [] }
        return BuddySimulator.activeBuddies(removed: profile.removedBuddyNames,
                                            invited: profile.invitedBuddyNames,
                                            startedSolo: profile.startedSolo)
    }

    /// v3.9: the single source of truth for solo presentation everywhere.
    /// DERIVED from the live circle, so it also covers the legacy path where
    /// someone removes all 8 members.
    var isSoloMode: Bool { circleSource.members.isEmpty }

    /// Friends who can still accept an invite. An EMPTY circle (`isSoloMode` —
    /// a fresh solo account, or a legacy one whose members were all removed)
    /// rebuilds from the FULL roster; an established legacy circle draws from
    /// the extra pool plus anyone it removed, so a removal is always
    /// reversible — `acceptInvite` clears the name as it re-adds them.
    /// v4: demo-only — real circles invite by code (SPEC-V4 §2, Phase B3).
    var invitableBuddies: [BuddySimulator.Buddy] {
        guard settings.circleMode == .demo else { return [] }
        let active = Set(activeBuddies.map(\.name))
        let solo = isSoloMode
        return BuddySimulator.roster.filter { buddy in
            guard !active.contains(buddy.name),
                  !profile.invitedBuddyNames.contains(buddy.name) else { return false }
            return solo
                || profile.removedBuddyNames.contains(buddy.name)
                || BuddySimulator.invitablePool.contains { $0.name == buddy.name }
        }
    }

    var circleIsFull: Bool {
        let source = circleSource
        return source.members.count >= source.maxMembers
    }

    /// Demo invite acceptance: adds the friend and queues the one-time
    /// "just joined" celebration. Their simulated week backfills immediately —
    /// that's the deterministic derivation doing its job, not a bug.
    /// v4: a no-op in a real circle — friends join by code (Phase B3).
    func acceptInvite(name: String) {
        guard settings.circleMode == .demo,
              !circleIsFull,
              invitableBuddies.contains(where: { $0.name == name }) else { return }
        profile.invitedBuddyNames.append(name)
        profile.removedBuddyNames.removeAll { $0 == name }
        profile.pendingNewMemberName = name
        persistProfile()
        objectWillChange.send()
    }

    /// v4: a no-op in a real circle — v4 is leave-only, nobody removes anyone
    /// else (SPEC-V4 §2), and that flow lands with membership in Phase B3.
    func removeMember(name: String) {
        guard settings.circleMode == .demo else { return }
        let before = activeBuddies.count
        profile.invitedBuddyNames.removeAll { $0 == name }
        // A BASE buddy invited back into a legacy circle sits in both lists —
        // dropping the invite alone leaves them in the base 8 — so anyone still
        // standing after that gets recorded as removed.
        if activeBuddies.contains(where: { $0.name == name }),
           !profile.removedBuddyNames.contains(name) {
            profile.removedBuddyNames.append(name)
        }
        // v3.9: a smaller circle makes every group target easier, and a removal
        // is free to undo (one tap re-invites, and their week backfills), so a
        // shrink voids THIS week's group awards. Self-expires on Monday.
        if activeBuddies.count < before {
            profile.groupAwardsFrozenWeek = BuddySimulator.weekKey(for: AppClock.now)
        }
        persistProfile()
        objectWillChange.send()
    }

    /// Dismiss the "X just joined" celebration (optionally after the welcome
    /// XP gift — that goes to THEM, so locally it's just the warm fuzzies).
    func clearPendingNewMember() {
        guard profile.pendingNewMemberName != nil else { return }
        profile.pendingNewMemberName = nil
        persistProfile()
        objectWillChange.send()
    }

    // MARK: - Guided tour (v3.7 — design session)

    /// Current tour step index (nil = not running). Step definitions live in
    /// `Tour.steps` (RootView.swift); RootView drives the tab switching.
    @Published var tutorialStep: Int? = nil

    func startTutorial() { tutorialStep = 0 }

    /// Finish or skip: either way the tour doesn't auto-run again (it stays
    /// replayable from Settings). If the app dies mid-tour, the flag is still
    /// unset, so the tour restarts cleanly from the top next launch.
    func endTutorial() {
        tutorialStep = nil
        if !settings.hasSeenTutorial {
            settings.hasSeenTutorial = true   // didSet persists
        }
    }

    // MARK: - Nudges (v3.6 — session-scoped demo)

    /// "dayKey|prayer|memberID" keys for nudges already sent this session.
    @Published private(set) var nudgesSent: Set<String> = []

    func nudgeKey(member: CircleMember, prayer: Prayer, dayKey: String) -> String {
        "\(dayKey)|\(prayer.rawValue)|\(member.id)"
    }

    func sendNudge(to member: CircleMember, prayer: Prayer, dayKey: String) {
        nudgesSent.insert(nudgeKey(member: member, prayer: prayer, dayKey: dayKey))
    }

    /// Grid order: buddies first, you LAST (isYou flag set).
    var circleMembers: [CircleMember] {
        circleSource.members + [youMember]
    }

    private var youMember: CircleMember {
        CircleMember(id: "you", name: profile.name.isEmpty ? "You" : profile.name,
                     emoji: "😄", isYou: true, avatarFilename: profile.avatarFilename)
    }

    /// The circle's squares for one prayer on one schedule day, filling in
    /// live: a buddy's post appears only once AppClock.now >= its loggedAt.
    func gridEntries(for prayer: Prayer, dayKey: String) -> [GridEntry] {
        let now = AppClock.now
        let window = schedule(forDayKey: dayKey)?.window(for: prayer)
        let source = circleSource
        var entries: [GridEntry] = []

        for member in source.members {
            let result = source.entry(forMember: member.id, prayer: prayer,
                                      dayKey: dayKey, window: window, now: now)
            entries.append(GridEntry(id: "\(member.id)|\(dayKey)|\(prayer.rawValue)",
                                     member: member, state: result.state,
                                     placeLabel: result.placeLabel))
        }

        let myState: GridEntryState
        var myPlaceLabel: String? = nil
        if let myLog = logs.first(where: { $0.dayKey == dayKey && $0.prayer == prayer }) {
            if myLog.tier.isInWindow {
                let content: PostContent = myLog.photoFilename.map { .photo(filename: $0) }
                    ?? .illustration(seed: BuddySimulator.seed(name: "you", dayKey: dayKey, prayer: prayer))
                myState = .posted(content, tier: myLog.tier, at: myLog.loggedAt)
                myPlaceLabel = Self.placeLabel(for: myLog)
            } else {
                myState = .qada(at: myLog.loggedAt)
            }
        } else if isExcused(prayer: prayer, dayKey: dayKey) {
            myState = .excused
        } else if let window, now >= window.end {
            myState = .missed
        } else {
            myState = .waiting
        }
        entries.append(GridEntry(id: "you|\(dayKey)|\(prayer.rawValue)",
                                 member: youMember, state: myState, placeLabel: myPlaceLabel))
        return entries
    }

    // MARK: - Saved places (v3)

    /// First time you tag Home/Masjid/Work with a device fix available, the
    /// spot is remembered so future posts nearby can auto-suggest the tag.
    /// On-the-go is never saved — it's by definition not a fixed place.
    private func rememberPlaceIfNeeded(_ tag: PlaceTag) {
        guard tag != .onTheGo,
              settings.savedPlaces[tag.rawValue] == nil,
              let coord = location.deviceCoordinate else { return }
        settings.savedPlaces[tag.rawValue] = SavedPlace(latitude: coord.latitude,
                                                        longitude: coord.longitude)
    }

    /// The saved place you're currently within ~250 m of, if any.
    func suggestedPlaceTag() -> PlaceTag? {
        guard let coord = location.deviceCoordinate else { return nil }
        return SavedPlace.nearest(to: coord.latitude, coord.longitude,
                                  in: settings.savedPlaces)
    }

    var savedPlaceTags: [PlaceTag] {
        PlaceTag.allCases.filter { settings.savedPlaces[$0.rawValue] != nil }
    }

    func clearSavedPlaces() {
        settings.savedPlaces = [:]
    }

    /// "🏠 Home" / "📍 Capitol Hill" pill text for a log's place, if tagged.
    static func placeLabel(for log: PrayerLog) -> String? {
        guard let tag = log.placeTag else { return nil }
        if tag == .onTheGo, let name = log.placeName, !name.isEmpty {
            return "\(tag.emoji) \(name)"
        }
        return "\(tag.emoji) \(tag.displayName)"
    }

    /// Counts per place tag across all your in-window logs (Journey "Places").
    /// Also surfaces the distinct on-the-go place names, most-recent first.
    func placeStats() -> (counts: [(tag: PlaceTag, count: Int)], spots: [String]) {
        var counts: [PlaceTag: Int] = [:]
        var spots: [String] = []
        for log in logs.reversed() {
            guard let tag = log.placeTag else { continue }
            counts[tag, default: 0] += 1
            if tag == .onTheGo, let name = log.placeName, !name.isEmpty, !spots.contains(name) {
                spots.append(name)
            }
        }
        let ordered = PlaceTag.allCases.compactMap { tag in
            counts[tag].map { (tag: tag, count: $0) }
        }
        return (ordered, spots)
    }

    /// Weekly circle scores (current Mon-start week), sorted descending.
    /// Computed from the same simulated logs the grid shows.
    func weeklyScores() -> [(member: CircleMember, xp: Int)] {
        let now = AppClock.now
        let days = currentWeekDays()
        let source = circleSource
        // v4: one Mon-start week is exactly one ISO week key.
        let weekKeys: [String] = [BuddySimulator.weekKey(for: now)]

        var scores: [(member: CircleMember, xp: Int)] = []
        for member in source.members {
            let prayerXP: Int = source.weeklyXP(forMember: member.id, days: days, asOf: now)
            // v4: a buddy's dhikr/deeds XP is one opaque weekly total, the same
            // rule your own row follows below (SPEC-V4 §3). Simulated buddies
            // have none, so the demo scoreboard is untouched.
            let recoveryXP: Int = source.recoveryXP(forMember: member.id, weekKeys: weekKeys)
            scores.append((member, prayerXP + recoveryXP))
        }
        let myXP = GameEngine.weeklyXP(logs: logs, weekStart: BuddySimulator.weekStart(for: now),
                                       excusedDayKeys: profile.excusedDayKeys)
        // v3.8: dhikr/deeds XP earned this week counts on the scoreboard too,
        // so someone who genuinely can't pray (period/illness) isn't left
        // behind by the Monday reset. (The crown race stays prayer-only.)
        scores.append((youMember, myXP + recoveryXPThisWeek(now: now)))
        return scores.sorted { $0.xp > $1.xp }
    }

    /// Sum of recovery (dhikr+deeds) XP earned across the current Mon-start week.
    private func recoveryXPThisWeek(now: Date) -> Int {
        Set(BuddySimulator.weekDayKeys(for: now))
            .reduce(0) { $0 + (profile.recoveryXPByDay[$1] ?? 0) }
    }

    /// Current-week group data grid: one row per member, 7 day-columns of
    /// 5 prayer cells each (Mon-first).
    func weekRows() -> [MemberWeekRow] {
        let now = AppClock.now
        let dayKeys = BuddySimulator.weekDayKeys(for: now)
        let source = circleSource

        var rows: [MemberWeekRow] = []
        for member in source.members {
            let days: [[GridCellState]] = dayKeys.map { key in
                let schedule = self.schedule(forDayKey: key)
                return Prayer.allCases.map { prayer in
                    source.cell(forMember: member.id, prayer: prayer, dayKey: key,
                                window: schedule?.window(for: prayer), now: now)
                }
            }
            rows.append(MemberWeekRow(id: member.id, member: member, days: days))
        }

        let myDays: [[GridCellState]] = dayKeys.map { key in
            let schedule = self.schedule(forDayKey: key)
            return Prayer.allCases.map { prayer in
                myCell(dayKey: key, prayer: prayer, window: schedule?.window(for: prayer), now: now)
            }
        }
        rows.append(MemberWeekRow(id: "you", member: youMember, days: myDays))
        return rows
    }

    private func myCell(dayKey: String, prayer: Prayer,
                        window: PrayerWindow?, now: Date) -> GridCellState {
        if let log = logs.first(where: { $0.dayKey == dayKey && $0.prayer == prayer }) {
            return log.tier.isInWindow ? .inWindow(log.tier) : .qada
        }
        if isExcused(prayer: prayer, dayKey: dayKey) { return .excused }
        guard let window else { return .future }
        return now >= window.end ? .missed : .future
    }

    // MARK: - Challenges (v2)

    /// Personal + group challenge progress (stateless, computed from logs).
    func challenges() -> [ChallengeProgress] {
        ChallengeEngine.progressList(challengeContext())
    }

    private func challengeContext() -> ChallengeEngine.Context {
        let now = AppClock.now
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let recentDayKeys: [String] = stride(from: 29, through: 0, by: -1).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: todayStart).map { AppClock.dayKey(for: $0) }
        }
        let weekDayKeys = BuddySimulator.weekDayKeys(for: now)
        let weekDayKeySet = Set(weekDayKeys)
        let days = currentWeekDays()

        let source = circleSource
        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = []
        for member in source.members {
            let weekLogs: [PrayerLog] = source.weekLogs(forMember: member.id, days: days, asOf: now)
            memberWeekLogs.append((member, weekLogs))
        }
        memberWeekLogs.append((youMember, logs.filter { weekDayKeySet.contains($0.dayKey) }))

        return ChallengeEngine.Context(myLogs: logs,
                                       memberWeekLogs: memberWeekLogs,
                                       todayKey: todayKey,
                                       recentDayKeys: recentDayKeys,
                                       weekDayKeys: weekDayKeys,
                                       weekKey: BuddySimulator.weekKey(for: now),
                                       hardestPrayer: settings.hardestPrayer,
                                       completions: profile.challengeCompletions,
                                       customChallenges: profile.customChallenges,
                                       hasCircle: !isSoloMode,
                                       groupAwardsFrozen: profile.groupAwardsFrozenWeek
                                           == BuddySimulator.weekKey(for: now))
    }

    // MARK: - Custom group challenges (v3.2)

    func createCustomChallenge(prayer: Prayer, days: Int) {
        let challenge = CustomChallenge(id: "custom-\(UUID().uuidString)",
                                        prayer: prayer,
                                        days: max(2, min(7, days)),
                                        createdAt: AppClock.now)
        profile.customChallenges.append(challenge)
        persistProfile()
        objectWillChange.send()
    }

    func deleteCustomChallenge(id: String) {
        profile.customChallenges.removeAll { $0.id == id }
        persistProfile()
        objectWillChange.send()
    }

    /// Award XP for any challenge that just completed (once per key).
    /// Called from refresh + log paths; LogResult/celebration are unchanged.
    private func awardNewlyCompletedChallenges() {
        let completed = ChallengeEngine.newlyCompleted(challengeContext())
        guard !completed.isEmpty else { return }
        var newProfile = profile
        for item in completed {
            newProfile.challengeCompletions[item.key] = AppClock.now
            newProfile.totalXP += item.definition.rewardXP
        }
        profile = newProfile
        persistProfile()
    }

    // MARK: - Photo summaries (v2)

    /// Days of `date`'s month that have at least one photo, oldest first.
    func photoSummaries(monthOf date: Date) -> [DayPhotoSummary] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        var result: [DayPhotoSummary] = []
        var day = interval.start
        while day < interval.end {
            let key = AppClock.dayKey(for: day)
            let dayLogs = logs.filter { $0.dayKey == key }.sorted { $0.loggedAt < $1.loggedAt }
            let photos = Self.distinctPhotos(of: dayLogs)
            if !photos.isEmpty {
                result.append(DayPhotoSummary(id: key, date: day,
                                              photoFilenames: photos,
                                              recap: recap(forDayKey: key, date: day)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// v3.6: summary for ANY day — the Journey calendar now opens photo-less
    /// days too (for the retroactive make-up editing).
    func daySummary(dayKey: String, date: Date) -> DayPhotoSummary {
        let dayLogs = logs.filter { $0.dayKey == dayKey }.sorted { $0.loggedAt < $1.loggedAt }
        return DayPhotoSummary(id: dayKey, date: date,
                               photoFilenames: Self.distinctPhotos(of: dayLogs),
                               recap: recap(forDayKey: dayKey, date: date))
    }

    /// v3.3: a travel-combined pair is TWO logs sharing ONE photo, so a day's
    /// filenames can repeat — de-dupe (first occurrence wins) before they reach
    /// the photo strips, which key their ForEach on the filename itself.
    private static func distinctPhotos(of dayLogs: [PrayerLog]) -> [String] {
        var seen = Set<String>()
        return dayLogs.compactMap(\.photoFilename).filter { seen.insert($0).inserted }
    }

    // MARK: - Recaps

    /// Oldest → newest, includes today as the last element.
    func recaps(daysBack: Int) -> [DayRecap] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: AppClock.now)
        var result: [DayRecap] = []
        for offset in stride(from: daysBack - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            result.append(recap(forDayKey: AppClock.dayKey(for: date), date: date))
        }
        return result
    }

    /// v3.9: Journey's "Your week" card — the most recent COMPLETED Mon–Sun
    /// week (never the week in progress). nil until that week holds at least
    /// one of your logs, so a new account doesn't get an empty trophy card.
    /// Personal only: no buddy data, so it reads the same solo or in a circle.
    func lastCompletedWeekRecap() -> WeeklyRecap? {
        let calendar = Calendar.current
        let thisWeekStart = BuddySimulator.weekStart(for: AppClock.now, calendar: calendar)
        guard let lastWeekDay = calendar.date(byAdding: .day, value: -1, to: thisWeekStart)
        else { return nil }
        let weekDayKeys = BuddySimulator.weekDayKeys(for: lastWeekDay, calendar: calendar)

        // Sunday's isha window runs past midnight (it ends at Monday's fajr), so
        // on Monday morning the week isn't decided yet — the same rule
        // reconcileStreakIfNeeded follows. Wait one more window rather than
        // publish a total a 1 AM isha log would silently change.
        if let prev = previousIshaWindow,
           AppClock.now < prev.end,
           weekDayKeys.last == previousDayKey,
           !hasLog(prayer: .isha, dayKey: previousDayKey) {
            return nil
        }

        return GameEngine.weeklyRecap(logs: logs,
                                      weekDayKeys: weekDayKeys,
                                      excusedDayKeys: profile.excusedDayKeys)
    }

    private func recap(forDayKey key: String, date: Date) -> DayRecap {
        let dayLogs = logs.filter { $0.dayKey == key }
        return DayRecap(dayKey: key,
                        date: date,
                        loggedCount: dayLogs.count,
                        inWindowCount: dayLogs.filter { $0.tier.isInWindow }.count,
                        xp: GameEngine.xp(forDay: key, logs: logs, excusedDayKeys: profile.excusedDayKeys),
                        isPerfect: GameEngine.isPerfectDay(logs: logs, dayKey: key,
                                                           excusedDayKeys: profile.excusedDayKeys))
    }

    // MARK: - Refresh (schedule + streak reconcile)

    /// Recompute today's schedule and reconcile the streak for elapsed days.
    /// Call on launch, foreground, day change, and settings change.
    func refresh() {
        applyTimeTravelPolicy()

        let now = AppClock.now
        let coords = activeCoordinates
        let calendar = Calendar.current

        scheduleCache.removeAll()

        todaySchedule = PrayerTimeService.schedule(for: now,
                                                   latitude: coords.latitude,
                                                   longitude: coords.longitude,
                                                   method: settings.calcMethod,
                                                   madhab: settings.madhab)
        if let schedule = todaySchedule {
            scheduleCache[schedule.dayKey] = schedule
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            previousDayKey = AppClock.dayKey(for: yesterday)
            previousIshaWindow = schedule(forDayKey: previousDayKey)?.window(for: .isha)
        }

        // v3.2: while a "can't pray" break is active, every day it touches is
        // auto-excused (incl. days that elapsed since the last open).
        if let since = profile.excusedModeSince {
            var changed = false
            var day = AppClock.date(fromDayKey: since) ?? now
            let todayStart = calendar.startOfDay(for: now)
            while day <= todayStart {
                let key = AppClock.dayKey(for: day)
                if !profile.excusedDayKeys.contains(key) {
                    profile.excusedDayKeys.insert(key)
                    changed = true
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            if changed { persistProfile() }
        }

        reconcileStreakIfNeeded(now: now, calendar: calendar)
        awardNewlyCompletedChallenges()

        if settings.useDeviceLocation {
            location.refreshLocation()
        }
    }

    /// v4: keep the developer clock in step with the circle mode (SPEC-V4 §3).
    /// A real circle pins it to real time and clears any offset already set;
    /// demo mode hands time travel back. Runs at the top of every refresh —
    /// launch, foreground, day change and settings change all pass through
    /// here — and BEFORE anything reads `AppClock.now`.
    private func applyTimeTravelPolicy() {
        let allowed: Bool = settings.circleMode == .demo
        AppClock.isTimeTravelAllowed = allowed
        if !allowed, AppClock.offset != 0 {
            AppClock.offset = 0
        }
    }

    /// Schedule for an arbitrary dayKey (cached until next refresh).
    private func schedule(forDayKey key: String) -> DaySchedule? {
        if let cached = scheduleCache[key] { return cached }
        guard let dayStart = AppClock.date(fromDayKey: key) else { return nil }
        let coords = activeCoordinates
        let schedule = PrayerTimeService.schedule(for: dayStart.addingTimeInterval(12 * 3600),
                                                  latitude: coords.latitude,
                                                  longitude: coords.longitude,
                                                  method: settings.calcMethod,
                                                  madhab: settings.madhab)
        if let schedule { scheduleCache[key] = schedule }
        return schedule
    }

    /// The current Mon-start week's (dayKey, schedule) pairs.
    private func currentWeekDays() -> [(dayKey: String, schedule: DaySchedule)] {
        BuddySimulator.weekDayKeys(for: AppClock.now).compactMap { key in
            schedule(forDayKey: key).map { (key, $0) }
        }
    }

    /// Walk every elapsed day from the day after `lastReconciledDayKey`
    /// through the last *decided* day. Excused days are skipped (streak
    /// preserved, no freeze). Incomplete day → consume a freeze, else
    /// streak → 0. Never touches today.
    ///
    /// "Last decided day" is normally yesterday, BUT yesterday's isha window
    /// stays open past midnight (it ends at today's fajr). While that window
    /// is still open and isha is unlogged for yesterday, yesterday's outcome
    /// isn't known yet — a 1 AM isha log can still complete it — so we stop
    /// the walk one day earlier and pick yesterday up on a later refresh.
    private func reconcileStreakIfNeeded(now: Date, calendar: Calendar) {
        let todayStart = calendar.startOfDay(for: now)
        guard var lastDecidedStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return }

        if let prev = previousIshaWindow,
           now < prev.end,
           AppClock.dayKey(for: lastDecidedStart) == previousDayKey,
           !hasLog(prayer: .isha, dayKey: previousDayKey) {
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: lastDecidedStart) else { return }
            lastDecidedStart = dayBefore
        }
        let lastDecidedKey = AppClock.dayKey(for: lastDecidedStart)

        guard let lastKey = profile.lastReconciledDayKey,
              let lastDate = AppClock.date(fromDayKey: lastKey) else {
            // First run (or unparseable state): start the ledger at the last
            // decided day without penalizing pre-install days.
            if profile.lastReconciledDayKey != lastDecidedKey {
                profile.lastReconciledDayKey = lastDecidedKey
                persistProfile()
            }
            return
        }
        guard lastDate < lastDecidedStart else { return }   // nothing new (or time-traveled backwards)

        var elapsed: [(dayKey: String, isComplete: Bool)] = []
        var day = calendar.date(byAdding: .day, value: 1, to: lastDate) ?? lastDecidedStart
        while day <= lastDecidedStart {
            let key = AppClock.dayKey(for: day)
            elapsed.append((key, GameEngine.isDayComplete(logs: logs, dayKey: key)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !elapsed.isEmpty else { return }
        profile = GameEngine.reconcile(profile: profile, elapsedDays: elapsed,
                                       excusedDayKeys: profile.excusedDayKeys)
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

    /// v3.9: onboarding marks a brand-new account as starting solo — its circle
    /// begins empty and grows one invite at a time. Never unset: a legacy
    /// profile must keep its existing circle.
    ///
    /// The "new account" signal (settings.hasOnboarded) lives in a DIFFERENT
    /// file from the circle it decides, and Store.load falls back per file — so
    /// a lost settings.json can replay onboarding over a populated profile.
    /// Gate on the profile: only an account with no history and an untouched
    /// circle may be flipped.
    func markStartedSolo() {
        guard !profile.startedSolo,
              profile.totalXP == 0,
              logs.isEmpty,
              profile.removedBuddyNames.isEmpty,
              profile.invitedBuddyNames.isEmpty else { return }
        profile.startedSolo = true
        persistProfile()
        objectWillChange.send()
    }

    /// v3.6: profile photo (settings rehaul). Stored via PhotoStore; the old
    /// file is cleaned up on replace.
    func setAvatar(_ image: UIImage) {
        let filename = PhotoStore.save(image, dayKey: "avatar", prayer: .fajr)
        guard !filename.isEmpty else { return }
        if let old = profile.avatarFilename { PhotoStore.delete(old) }
        profile.avatarFilename = filename
        persistProfile()
        objectWillChange.send()
    }

    // MARK: - DEBUG helpers

    /// 21 days of plausible history ending yesterday; profile is rebuilt from
    /// the generated logs so XP/streak/badges/perfect days stay consistent.
    /// ~70% of in-window logs get demo photos (PhotoStore.demoImage, "demo-"
    /// prefixed). Buddy history needs no filling — BuddySimulator derives it.
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
                var photo: String?
                var place: PlaceTag?
                var placeName: String?
                if tier.isInWindow, rng.uniform() < 0.7 {
                    photo = PhotoStore.saveDemo(seed: rng.next(), dayKey: key, prayer: prayer)
                    // ~60% of demo posts carry a place tag so Journey's
                    // "Places" section has something to show.
                    if rng.uniform() < 0.6 {
                        place = BuddySimulator.placeTag(seed: rng.next())
                        if place == .onTheGo {
                            placeName = ["Green Lake", "Campus library", "Buc-ee's, Texas"][Int(rng.next() % 3)]
                        }
                    }
                }
                generated.append(PrayerLog(id: UUID(), prayer: prayer, dayKey: key,
                                           loggedAt: loggedAt, tier: tier, xp: tier.xp,
                                           photoFilename: photo, jamaat: false,
                                           placeTag: place, placeName: placeName))
            }
        }

        logs = generated.sorted { $0.loggedAt < $1.loggedAt }

        // Rebuild the profile from the logs.
        var p = UserProfile.fresh(now: AppClock.now)
        p.name = profile.name
        p.joinedAt = calendar.date(byAdding: .day, value: -21, to: todayStart) ?? profile.joinedAt
        // v3.9: this filler rebuilds HISTORY, not the circle — carry the solo
        // flag and whatever circle the user shaped through untouched.
        p.startedSolo = profile.startedSolo
        p.invitedBuddyNames = profile.invitedBuddyNames
        p.removedBuddyNames = profile.removedBuddyNames

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
        PhotoStore.deleteAll()
        Store.delete(Store.logsFile)
        Store.delete(Store.profileFile)
        persist()
        refresh()
    }
}
