import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var profile: UserProfile
    @Published private(set) var logs: [PrayerLog]          // full history
    @Published var settings: AppSettings {
        didSet {
            Store.save(settings, to: Store.settingsFile)
            // Only when the windows actually move. `refresh()` runs Adhan over
            // the whole day, drops the schedule cache and reconciles streaks —
            // real work, synchronous, on the main thread, and it was happening
            // for every settings write including ones that cannot possibly
            // change a prayer time. `circleMode` is in the list because
            // `refresh` also applies the time-travel policy.
            if settings.affectsSchedule(comparedTo: oldValue) { refresh() }
            // Reschedule stays unconditional: the notification TOGGLES are
            // themselves a reason to requeue, and this only starts a Task.
            NotificationManager.shared.reschedule()
            // v4 Phase D FIX: and the REMOTE half of the same switches. The
            // device row was only ever written by `PushRegistrar.refresh`,
            // whose callers are launch and foreground — so turning "Friend
            // activity" off left `devices.notify_friend_activity = true` until
            // the next background/foreground cycle, and the next push a person
            // got was the one they had just opted out of. Hung off `didSet`
            // rather than off the two Settings toggles because this is where
            // EVERY path that can flip one arrives. It never prompts and costs
            // nothing when nothing changed (see `preferencesChanged`).
            Task { await PushRegistrar.shared.preferencesChanged() }
        }
    }
    @Published private(set) var todaySchedule: DaySchedule?
    @Published var celebration: LogResult?                 // set by log(); UI presents then nils it
    /// v4: set once per timezone crossing, cleared when the Today banner is
    /// dismissed. Deliberately NOT persisted — it is news, and news that
    /// survives a relaunch becomes nagging.
    @Published var pendingTravelNotice: TravelNotice?

    /// v4: the offline mirror of a real circle (SPEC-V4 §8). Held in memory
    /// rather than re-read per access, because `circleSource` is consulted
    /// several times per render and must never touch the disk to draw a grid.
    /// `.empty` covers demo mode, a solo account and a first launch alike.
    @Published private(set) var circleSnapshot: CircleSnapshot = .empty

    /// v4 Phase C: the one door between this class and the network.
    ///
    /// `AppState` logs a prayer and calls `postLogged`; whether that reaches
    /// the server now, in ten minutes or after the flight lands is the engine's
    /// problem, not this file's. There is deliberately no other networking
    /// symbol in `AppState`.
    ///
    /// Weak, and optional: the engine is owned by `CircleService` (which owns
    /// the mirror it merges into), it is created on demand at launch, and every
    /// mirror call below is a no-op until it exists — which is exactly what a
    /// solo install, demo mode and every existing unit test want.
    private weak var circleSync: CircleSync?

    /// Wired once at launch by `CircleStack.start(host:)`, which is also what
    /// creates the engine (see `CircleService.ensureSync`) — before the session
    /// is restored, so a prayer logged in the first second is still mirrored.
    func attachCircleSync(_ sync: CircleSync) {
        circleSync = sync
        replayUnmirroredExcusedDays(to: sync)
    }

    /// v4 Phase C FIX: rest days created before the engine existed.
    ///
    /// `init()` calls `refresh()`, and `refresh()`'s break walk marks every day
    /// a multi-day break has touched — but `circleSync` is only attached here,
    /// from the launch sequence, so on a cold launch after a break spanned days
    /// `mirrorExcused` was a no-op and the flags went nowhere. The walk
    /// only ever reports days it JUST inserted (`!contains(key)`), and the
    /// insert is persisted, so no later `refresh()` retried them: the circle
    /// showed those days as `.missed` forever, and scored them against an
    /// excused set only the poster's own device had.
    ///
    /// Replaying is close to free. Only days the mirror does not already carry
    /// are sent — normally none, because `circle.json` is loaded before this
    /// runs — the outbox collapses on `excused:<dayKey>`, and the server insert
    /// ignores duplicates.
    private func replayUnmirroredExcusedDays(to sync: CircleSync) {
        guard mirrorsToCircle else { return }
        guard let me: UUID = circleSnapshot.me else { return }
        let mirrored: Set<String> = circleSnapshot.excusedDayKeys(userID: me)
        let horizon: Date = AppClock.now
            .addingTimeInterval(-Double(CircleSyncTuning.pullWindowDays) * 86_400)
        let owed: [String] = CircleSync.unmirroredExcusedDayKeys(
            local: profile.excusedDayKeys,
            mirrored: mirrored,
            startDayKey: AppClock.dayKey(for: horizon),
            todayKey: todayKey)
        for key in owed {
            sync.excusedChanged(dayKey: key, on: true)
        }
    }

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
        // v4: settings come first so the time-travel policy is applied BEFORE
        // the first `AppClock.now` read — a stale offset left on disk would
        // otherwise stamp a time-travelled `joinedAt` on a fresh profile in a
        // real circle, which is the one thing the guard exists to prevent.
        let loaded: AppSettings = Store.load(Store.settingsFile, default: AppSettings())
        AppState.applyTimeTravelPolicy(for: loaded.circleMode)
        settings = loaded

        let now = AppClock.now
        profile = Store.load(Store.profileFile, default: UserProfile.fresh(now: now))
        logs = Store.load(Store.logsFile, default: [PrayerLog]())
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
                                      now: AppClock.now, isExcused: isTodayExcused,
                                      joinedAt: profile.joinedAt,
                                      currentOffset: AppClock.utcOffsetSeconds)
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

        // IDENTITY, not grouping: after a long-haul flight today's dayKey can
        // hold the zone you left AND the zone you landed in, and only a log
        // from THIS zone means "already prayed". `todayLogs` (grouping) stays
        // as it is — the XP breakdown must still sum every log on the day.
        if let log = currentInstanceLog(prayer: prayer, dayKey: todayKey) {
            return .logged(log.tier)
        }
        guard let window = todaySchedule?.window(for: prayer) else {
            return .upcoming(opensAt: now)
        }
        if now < window.start { return .upcoming(opensAt: window.start) }
        if now < window.end { return .open(closesAt: window.end) }
        // Closed before the account existed → not a miss. Mirrors the rule
        // already applied to OTHER people in `gridEntries` (a circle member's
        // days before they joined don't count against them); it was only ever
        // missing for you, on your own first day.
        if window.end <= profile.joinedAt { return .beforeJoining }
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

    /// Has THIS instance of `prayer` on `dayKey` already been logged?
    ///
    /// v4 — PRAYER IDENTITY. `dayKey` stays the grouping key for a day and
    /// nothing about scoring moves, but it is no longer the whole identity of a
    /// prayer. Cross enough timezones and one calendar date holds two different
    /// fajrs (see `GameEngine.isSamePrayerInstance`), so identity is
    /// `(prayer, dayKey, zone)` and the zone is compared with tolerance: a
    /// madhab change or a DST hour must never make a logged prayer look
    /// unlogged, and a legacy log with no offset matches anything.
    ///
    /// Every caller of this asks an IDENTITY question — "may I log this?",
    /// "is the CTA still live?", "can a late isha still land?". Callers asking
    /// a GROUPING question ("what happened on this day?") use `hasAnyLog` or
    /// go straight to `GameEngine`, and must not be routed through here.
    private func hasLog(prayer: Prayer, dayKey: String) -> Bool {
        currentInstanceLog(prayer: prayer, dayKey: dayKey) != nil
    }

    /// The log for this prayer instance, if there is one. See `hasLog`.
    /// The rule lives in `GameEngine` and the clock read lives here, which is
    /// the usual division: the engine decides, orchestration supplies the now.
    private func currentInstanceLog(prayer: Prayer, dayKey: String) -> PrayerLog? {
        GameEngine.loggedInstance(prayer: prayer, dayKey: dayKey,
                                  currentOffset: AppClock.utcOffsetSeconds, in: logs)
    }

    /// GROUPING: does this schedule day contain `prayer` at all, from any zone?
    /// The question the Journey day sheet asks before offering a make-up — that
    /// sheet lists a past day's prayers by dayKey alone, and a zone you are no
    /// longer standing in is not a reason to offer to log one twice.
    private func hasAnyLog(prayer: Prayer, dayKey: String) -> Bool {
        logs.contains { $0.prayer == prayer && $0.dayKey == dayKey }
    }

    /// Is `(prayer, dayKey)` the instance the device is LIVING IN right now?
    ///
    /// Identity only means anything against a zone you are actually standing
    /// in. Today is that day; so — before fajr — is yesterday's still-open
    /// isha, which is the one past-dated thing `status(of:)` also answers by
    /// identity. Everything older is history: the zone the device is in today
    /// has nothing to say about the zone Monday was lived in, and asking would
    /// repaint a whole travelled week as missed.
    private func isLiveInstance(prayer: Prayer, dayKey: String) -> Bool {
        if dayKey == todayKey { return true }
        // `targetWindow` is the one place that decides whether yesterday's isha
        // is still the live block, so it is asked rather than re-derived.
        guard prayer == .isha, dayKey == previousDayKey else { return false }
        return targetWindow(for: .isha)?.dayKey == dayKey
    }

    /// The log a SQUARE draws for `(prayer, dayKey)` — the Today grid, the week
    /// grid, a day sheet.
    ///
    /// v4: for the day you are standing in this is the IDENTITY lookup, so the
    /// square sitting next to the camera CTA can never contradict
    /// `status(of:)`. Before this, a traveller who prayed fajr in Mumbai and
    /// landed in Seattle after Seattle's fajr closed saw the "Make up Fajr"
    /// row and a posted photo for the same prayer at the same time, and the
    /// inline make-up button was hidden by a cell that disagreed with it.
    /// For a PAST day it is grouping, deterministically — see
    /// `GameEngine.latestLog`.
    private func cellLog(prayer: Prayer, dayKey: String) -> PrayerLog? {
        GameEngine.cellLog(prayer: prayer, dayKey: dayKey,
                           isLiveDay: isLiveInstance(prayer: prayer, dayKey: dayKey),
                           currentOffset: AppClock.utcOffsetSeconds, in: logs)
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
                        celebrationPrayer: prayer, celebrationTier: tier, dayKey: target.dayKey,
                        travelCombined: false)
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
        // v4 §3: both prayers of the pair carry `travel_combined`, so the
        // circle can tell a jam' from two separate posts a minute apart.
        finalizeLogging(added: added, snapshot: snapshot,
                        celebrationPrayer: lead, celebrationTier: tier, dayKey: dayKey,
                        travelCombined: true)
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
                         placeName: countsPlace == .onTheGo ? placeName : nil,
                         utcOffset: AppClock.utcOffsetSeconds)
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
                                 celebrationPrayer: Prayer, celebrationTier: LogTier, dayKey: String,
                                 travelCombined: Bool) {
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
        // v4 §3: share what the device has just committed — after the write to
        // disk, never before it, so the queue can never be ahead of the truth
        // it is describing.
        mirrorLogged(added, travelCombined: travelCombined)
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
    ///
    /// Deliberately no mirror call of its own: it IS `log`, and adding one here
    /// would post the same prayer twice.
    func logQada(_ prayer: Prayer) {
        log(prayer, photoFilename: nil, jamaat: false)
    }

    // MARK: - Mirroring to the circle (v4 Phase C)

    /// Whether a local change is also a circle change.
    ///
    /// The engine refuses without a live circle anyway, so this is belt to its
    /// braces — but it is the half that reads at the call site, and it is the
    /// half that keeps demo mode from ever forming a wire type at all.
    private var mirrorsToCircle: Bool { settings.circleMode == .real }

    /// Share logs that were just written locally. `travelCombined` is passed
    /// in because a `PrayerLog` cannot know it was half of a jam' pair — §3
    /// wants the flag on BOTH prayers of the pair.
    ///
    /// A combined pair enqueues two photo uploads of the same JPEG, one object
    /// each, and that is the intended trade: the alternative is two rows
    /// pointing at one object, where undoing either prayer tombstones the
    /// picture out from under the other.
    ///
    /// `announce` is §6's friend-activity push, and it is false for exactly one
    /// caller: a retroactive make-up (`logPastMakeUp`). The alert reads
    /// "📸 X posted first for Fajr", which a friend will read as *now* — and
    /// last Thursday's fajr is not news, it is bookkeeping. The post still goes.
    private func mirrorLogged(_ added: [PrayerLog], travelCombined: Bool,
                              announce: Bool = true) {
        guard mirrorsToCircle, let sync = circleSync else { return }
        for entry in added {
            sync.postLogged(entry, photoFilename: entry.photoFilename,
                            travelCombined: travelCombined, announce: announce)
        }
    }

    /// §3: undo RETRACTS the post. The row goes, and with it the photo.
    private func mirrorRetracted(_ removed: PrayerLog) {
        guard mirrorsToCircle, let sync = circleSync else { return }
        sync.postRetracted(removed)
    }

    /// §3: a rest day travels as a BARE FLAG. Note what this signature cannot
    /// express — `breakReason` has nowhere to go, here or in `CircleOp`, and
    /// that is the enforcement.
    private func mirrorExcused(dayKey: String, on: Bool) {
        guard mirrorsToCircle, let sync = circleSync else { return }
        sync.excusedChanged(dayKey: dayKey, on: on)
    }

    /// §3: dhikr + good deeds leave as one opaque weekly integer — never the
    /// tap count, never which deed.
    ///
    /// Sent on every grant rather than on a timer: the outbox collapses repeats
    /// on `recovery:<weekKey>`, so a hundred tasbih taps are one pending write
    /// that keeps being rewritten, and the drain's own re-entrancy guard means
    /// they cost at most one request per round trip.
    private func mirrorRecoveryWeek() {
        guard mirrorsToCircle, let sync = circleSync else { return }
        let now: Date = AppClock.now
        sync.recoveryWeekChanged(weekKey: BuddySimulator.weekKey(for: now),
                                 xp: recoveryXPThisWeek(now: now))
    }

    /// §5: a custom challenge belongs to the CIRCLE, which is why
    /// `activeCustomChallenges` already reads the mirror for one.
    private func mirrorChallengeCreated(_ challenge: CustomChallenge) {
        guard mirrorsToCircle, let sync = circleSync else { return }
        sync.challengeCreated(challenge)
    }

    private func mirrorChallengeDeleted(id: String) {
        guard mirrorsToCircle, let sync = circleSync else { return }
        sync.challengeDeleted(id: id)
    }

    /// SPEC-V4 §2, via `CircleServiceHost`: the current Mon-start week's logs,
    /// so joining mid-week shows the circle your week so far.
    ///
    /// The one read the circle stack is allowed of local history, and it is an
    /// answer rather than access: one week, filtered here, read-only. The
    /// engine filters again by week key — this is not a place to be clever.
    func circleBackfillLogs(forWeekOf now: Date) -> [PrayerLog] {
        let keys: Set<String> = Set(BuddySimulator.weekDayKeys(for: now))
        return logs.filter { keys.contains($0.dayKey) }
    }

    /// The same week's rest days, as bare keys (§3 — the reason has no way out
    /// of this file, and no way into `CircleOp`). Joining mid-period should
    /// show the circle "resting", not five missed cells a day.
    func circleBackfillExcusedDayKeys(forWeekOf now: Date) -> [String] {
        let keys: Set<String> = Set(BuddySimulator.weekDayKeys(for: now))
        return profile.excusedDayKeys.filter { keys.contains($0) }.sorted()
    }

    // MARK: - Editing past days (v3.6 — design session)

    /// "I made it up but forgot to log it": retroactively mark a PAST day's
    /// prayer as made up, from the Journey day sheet. Recent edits (≤2 days)
    /// still earn qada XP; older ones earn nothing — same-day logging stays
    /// the incentive. Never touches streak history (those days were already
    /// reconciled).
    func logPastMakeUp(_ prayer: Prayer, dayKey: String) {
        guard dayKey < todayKey,                                   // past days only
              // GROUPING on purpose (v4): the day sheet that offers this button
              // shows one row per prayer per dayKey and hides it the moment ANY
              // log exists, so the guard has to agree with what the user saw.
              // The zone identity is unknowable for a past day anyway — the
              // offset in hand is the EDIT's, not the day's.
              !hasAnyLog(prayer: prayer, dayKey: dayKey),
              !isExcused(prayer: prayer, dayKey: dayKey) else { return }
        let xp = GameEngine.lateEditXP(dayKey: dayKey, todayKey: todayKey)
        // The offset of the EDIT, not of the day being edited — that day's
        // zone is unknowable after the fact, and guessing it would be worse
        // than leaving the record honest about when the claim was made.
        let entry = PrayerLog(id: UUID(), prayer: prayer, dayKey: dayKey,
                              loggedAt: AppClock.now, tier: .qada, xp: xp,
                              utcOffset: AppClock.utcOffsetSeconds)
        logs.append(entry)
        profile.totalXP += xp
        persist()
        // v4 §3: a retroactive make-up is still a post — it carries the PAST
        // `dayKey` it belongs to, and the server never re-derives one from
        // `logged_at` (which is now). No push: see `mirrorLogged`.
        mirrorLogged([entry], travelCombined: false, announce: false)
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
        // IDENTITY (v4): undo takes back the prayer you are standing in, which
        // on a travel day is not the only one on this dayKey. It picks through
        // the SAME resolver `status(of:)` uses — see
        // `GameEngine.loggedInstanceIndex` — because two logs can match at once
        // and a tile that showed one while Undo deleted the other left the
        // button looking dead and took the wrong XP with it.
        guard let index = GameEngine.loggedInstanceIndex(
            prayer: prayer, dayKeys: candidateDayKeys,
            currentOffset: AppClock.utcOffsetSeconds,
            preferredDayKey: dayKey, in: logs)
        else { return }
        let removed = logs[index]

        logs.remove(at: index)

        // Undo removes the photo file too — the grid returns to its CTA state.
        // v3.3: a combined (travel) pair shares one photo, so only delete the
        // file once no remaining log still references it. v4.1: that rule is
        // `GameEngine.isPhotoOrphaned`, shared with the camera flow, which asks
        // it of a photo it has just written rather than one it just orphaned.
        PhotoStore.deleteIfOrphaned(removed.photoFilename, in: logs)

        // All of undo's arithmetic, in `GameEngine` where scoring lives. It
        // compares the day BEFORE against the day AFTER rather than assuming
        // the removal broke it — on a travel day one prayer can be logged
        // twice, so taking one back can leave the day just as perfect and just
        // as complete as it was.
        profile = GameEngine.profileAfterUndo(of: removed, from: profile,
                                              remainingLogs: logs,
                                              excusedDayKeys: profile.excusedDayKeys)
        persist()
        // v4 §3: undo DELETES the post. The outbox collapses this against a
        // create that never left the device, so undoing straight after logging
        // costs the network nothing at all.
        mirrorRetracted(removed)
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
              let coord = location.deviceCoordinate else { return false }
        let homes = SavedPlace.all(.home, in: settings.savedPlaces)
        guard !homes.isEmpty else { return false }
        // Far from EVERY home. With more than one saved (a second home, a
        // parents' place) being near any of them means you are not travelling.
        return homes.allSatisfy {
            $0.distanceMeters(latitude: coord.latitude, longitude: coord.longitude) > 80_000
        }
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
        // v4 §3: the circle sees "resting", never why. This asks the DAY
        // whether it ended up excused rather than asking the break — a break
        // that starts after the last window closes excuses nothing today, and
        // sending a flag for it would show a rest day that isn't one.
        if profile.excusedDayKeys.contains(todayKey) {
            mirrorExcused(dayKey: todayKey, on: true)
        }
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
        // v4 §3: the wire flag is whole-day, so only the branch that stops the
        // day being excused at all has anything to tell the circle. Resuming
        // mid-day leaves the day excused (the later prayers just count again),
        // which is the same fact the circle already has.
        var unexcusedToday: Bool = false
        if let prayer,
           let idx = Prayer.allCases.firstIndex(of: prayer), idx > 0,
           profile.excusedDayKeys.contains(todayKey) {
            profile.partialExcuseEnd[todayKey] = prayer
        } else {
            profile.excusedDayKeys.remove(todayKey)
            profile.partialExcuseStart[todayKey] = nil
            profile.partialExcuseEnd[todayKey] = nil
            unexcusedToday = true
        }
        persistProfile()
        if unexcusedToday {
            mirrorExcused(dayKey: todayKey, on: false)
        }
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
        mirrorExcused(dayKey: key, on: on)
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
        mirrorRecoveryWeek()
    }

    /// Complete a good-deed prompt for today: once per deed per day, +deedXP
    /// (subject to the same shared cap).
    func completeDeed(_ id: String) {
        guard !deedsDoneToday.contains(id) else { return }
        profile.deedsByDay[todayKey, default: []].append(id)
        awardRecoveryXP(GameEngine.deedXP)
        persistProfile()
        mirrorRecoveryWeek()
    }

    /// Un-tick a good deed — the mis-tap escape hatch.
    ///
    /// The XP has to come back off by the same rules it went on by, which is
    /// NOT `totalXP -= deedXP`: a deed ticked once the daily cap was already
    /// spent earned nothing, and taking 10 back there would invent a debt.
    /// `GameEngine.recoveryEarnedAfterUndo` does that reasoning; this method
    /// only supplies what remains and banks the difference.
    ///
    /// Deliberately today-only. `deedsDoneToday` reads the current dayKey, and
    /// yesterday's deeds are history rather than a pending choice.
    func uncompleteDeed(_ id: String) {
        guard deedsDoneToday.contains(id) else { return }

        var remaining = profile.deedsByDay[todayKey] ?? []
        remaining.removeAll { $0 == id }
        profile.deedsByDay[todayKey] = remaining.isEmpty ? nil : remaining

        let rawRemaining = dhikrToday * GameEngine.dhikrXP
            + remaining.count * GameEngine.deedXP
        let earned = recoveryXPToday
        let settled = GameEngine.recoveryEarnedAfterUndo(earnedToday: earned,
                                                         remainingRawTotal: rawRemaining)
        let refund = earned - settled
        if refund > 0 {
            profile.totalXP = max(0, profile.totalXP - refund)
            profile.recoveryXPByDay[todayKey] = settled == 0 ? nil : settled
        }

        persistProfile()
        mirrorRecoveryWeek()
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
    ///
    /// NO CALLER YET. Until B3 lands the mirror is read once in `init` and
    /// never changes within a session, so a `.real` circle draws whatever the
    /// last sync left on disk. That is the seam being in place, not wired.
    func applyCircleSnapshot(_ snapshot: CircleSnapshot) {
        circleSnapshot = snapshot
        // v5 §3: a pull that brought in a friend's post is exactly the change
        // the home screen exists to show. The file is rewritten here; the
        // reload it deserves is P3's push-driven one (§5-B) — for now the next
        // backgrounding, or a window boundary, picks it up.
        publishWidgetSnapshot()
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
    /// someone removes all 11 members.
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

    /// How many friends are in the circle right now, you excluded — what the
    /// invite sheet counts. v4: reads the seam, so a real circle counts its
    /// synced members rather than the (always empty) simulated roster.
    var friendCount: Int { circleSource.members.count }

    /// The friend cap the invite copy quotes. The two modes genuinely differ:
    /// 8 simulated buddies in demo, 7 in a real circle (8 seats minus you), so
    /// quoting a constant would advertise a slot the server refuses.
    var friendCapacity: Int { circleSource.maxMembers }

    /// v4: removing someone is a DEMO-only affordance. A real circle is
    /// leave-only (SPEC-V4 §2), so the button must not be offered there —
    /// `removeMember` already refuses, and a confirm dialog in front of a
    /// silent no-op is worse than no button at all.
    var canRemoveMembers: Bool { settings.circleMode == .demo }

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

    /// v4 §6: the nudge chip is now a REAL push.
    ///
    /// `nudgesSent` stays exactly what it was — the optimistic, session-scoped
    /// tick — and it is inserted FIRST, before anything asynchronous: the chip
    /// must settle the instant it is tapped, whatever the network does next.
    /// The server rate-limits to one nudge per sender, per recipient, per
    /// prayer window and answers `rate_limited`, which `PushRegistrar` reads as
    /// "already nudged" rather than as a failure — so a second tap never
    /// un-ticks the chip.
    ///
    /// Demo mode stays entirely offline: the `member:` overload parses the
    /// member id as a uuid, and a simulated buddy's name (or "you") isn't one,
    /// so it never reaches the network.
    func sendNudge(to member: CircleMember, prayer: Prayer, dayKey: String) {
        nudgesSent.insert(nudgeKey(member: member, prayer: prayer, dayKey: dayKey))
        // v5 §3: `waiting[].nudgedThisWindow` is what P4's widget button reads
        // to know it has already been spent. Nudges are session-scoped and
        // never touch `persist()`, so this is their only way into the file.
        publishWidgetSnapshot()
        Task { await PushRegistrar.shared.nudge(member: member, dayKey: dayKey, prayer: prayer) }
    }

    /// Grid order: buddies first, you LAST (isYou flag set).
    var circleMembers: [CircleMember] {
        circleSource.members + [youMember]
    }

    private var youMember: CircleMember {
        CircleMember(id: "you", name: profile.name.isEmpty ? "You" : profile.name,
                     emoji: "😄", isYou: true, avatarFilename: profile.avatarFilename)
    }

    /// The id every square in a photo grid carries.
    ///
    /// v4: built and read through this pair rather than spelled inline, because
    /// a tile now has to recover the coordinates it was drawn for —
    /// `PhotoSquare` resolves a buddy's Storage photo from (member, day,
    /// prayer), and the alternative was threading a path through two view
    /// layers that have no other reason to know about one.
    static func gridEntryID(memberID: String, dayKey: String, prayer: Prayer) -> String {
        "\(memberID)|\(dayKey)|\(prayer.rawValue)"
    }

    /// The inverse. nil for anything that isn't one of ours (a SwiftUI preview
    /// passing "1", say) — never a crash, never a guess.
    static func gridEntryCoordinates(_ id: String)
        -> (memberID: String, dayKey: String, prayer: Prayer)? {
        let parts: [Substring] = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let prayer = Prayer(rawValue: String(parts[2])) else { return nil }
        return (String(parts[0]), String(parts[1]), prayer)
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
            let entryID: String = AppState.gridEntryID(memberID: member.id, dayKey: dayKey,
                                                      prayer: prayer)
            entries.append(GridEntry(id: entryID,
                                     member: member, state: result.state,
                                     placeLabel: result.placeLabel))
        }

        let myState: GridEntryState
        var myPlaceLabel: String? = nil
        if let myLog = cellLog(prayer: prayer, dayKey: dayKey) {
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
        let myEntryID: String = AppState.gridEntryID(memberID: "you", dayKey: dayKey, prayer: prayer)
        entries.append(GridEntry(id: myEntryID,
                                 member: youMember, state: myState, placeLabel: myPlaceLabel))
        return entries
    }

    // MARK: - Saved places (v3)

    /// Tagging Home/Masjid/Work somewhere NEW remembers that spot, so future
    /// posts nearby can auto-suggest the tag. On-the-go is never saved — it is
    /// by definition not a fixed place.
    ///
    /// v4.1: this used to fire only on the FIRST ever tag of a kind
    /// (`savedPlaces[tag] == nil`), which is why a second masjid could never be
    /// recorded and why a Home saved at the wrong address stayed wrong forever.
    /// The condition is now "not already inside a saved place of this tag", so
    /// praying at a different masjid adds it and praying at the usual one does
    /// nothing.
    private func rememberPlaceIfNeeded(_ tag: PlaceTag) {
        guard tag != .onTheGo, let coord = location.deviceCoordinate else { return }
        let existing = SavedPlace.all(tag, in: settings.savedPlaces)
        let alreadyHere = existing.contains {
            $0.distanceMeters(latitude: coord.latitude,
                              longitude: coord.longitude) <= $0.radiusMeters
        }
        guard !alreadyHere else { return }
        settings.savedPlaces.append(SavedPlace(tag: tag,
                                               latitude: coord.latitude,
                                               longitude: coord.longitude,
                                               savedAt: AppClock.now))
    }

    /// The saved place you're currently standing inside, if any.
    func suggestedPlace() -> SavedPlace? {
        guard let coord = location.deviceCoordinate else { return nil }
        return SavedPlace.nearest(to: coord.latitude, coord.longitude,
                                  in: settings.savedPlaces)
    }

    /// The same answer, as a bare tag — what the camera flow pre-selects.
    func suggestedPlaceTag() -> PlaceTag? { suggestedPlace()?.tag }

    var savedPlaceTags: [PlaceTag] {
        PlaceTag.allCases.filter { !SavedPlace.all($0, in: settings.savedPlaces).isEmpty }
    }

    // MARK: - Managing saved places (v4.1)

    /// Rename a saved place. An empty name clears it back to the tag's generic
    /// name rather than storing a blank.
    func renamePlace(id: UUID, to name: String) {
        guard let i = settings.savedPlaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.savedPlaces[i].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Move a saved place to where the device is now — the fix for a Home that
    /// was anchored at the wrong address, which until now was permanent.
    @discardableResult
    func reanchorPlace(id: UUID) -> Bool {
        guard let coord = location.deviceCoordinate,
              let i = settings.savedPlaces.firstIndex(where: { $0.id == id }) else { return false }
        settings.savedPlaces[i].latitude = coord.latitude
        settings.savedPlaces[i].longitude = coord.longitude
        settings.savedPlaces[i].savedAt = AppClock.now
        return true
    }

    func setPlaceRadius(id: UUID, meters: Double) {
        guard let i = settings.savedPlaces.firstIndex(where: { $0.id == id }) else { return }
        settings.savedPlaces[i].radiusMeters = max(50, min(5_000, meters))
    }

    func forgetPlace(id: UUID) {
        settings.savedPlaces.removeAll { $0.id == id }
    }

    func clearSavedPlaces() {
        settings.savedPlaces = []
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

    /// YOUR square in the week grid.
    ///
    /// GROUPING, not identity — including for today, and unlike `cellLog`.
    /// A week-grid cell answers "how did that DAY go", which is the same
    /// question asked of every other member's row: those go through
    /// `RemoteCircleDataSource.cell` -> `CircleSnapshot.post(...)`, which keys
    /// on day_key alone. Answering your own row by identity made the grid
    /// disagree with itself — fly Mumbai to Seattle and your fajr cell read
    /// `.missed` while `weeklyXP` on the same screen counted its 30 XP and put
    /// you higher on the scoreboard, and a circle-mate who took the identical
    /// flight rendered `.posted` because their row took the other path.
    ///
    /// Identity still governs the TODAY screen (`gridEntries`, line ~1101),
    /// where the question really is "can I log this one now" and the square
    /// has to agree with the camera CTA beside it. Two different questions,
    /// two different rules, and the grid is the day one.
    private func myCell(dayKey: String, prayer: Prayer,
                        window: PrayerWindow?, now: Date) -> GridCellState {
        if let log = GameEngine.latestLog(prayer: prayer, dayKey: dayKey, in: logs) {
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
                                       customChallenges: activeCustomChallenges,
                                       hasCircle: !isSoloMode,
                                       groupAwardsFrozen: profile.groupAwardsFrozenWeek
                                           == BuddySimulator.weekKey(for: now))
    }

    // MARK: - Custom group challenges (v3.2)

    /// The group challenges in play. v4: in a real circle they belong to the
    /// CIRCLE, so the synced mirror is the source — otherwise a challenge
    /// someone else created is invisible and one you made is scored against
    /// members who never agreed to it. One you just made is still only local
    /// until the outbox drains, so it is offered alongside the synced set and
    /// the id decides: the mirror's copy wins once it round-trips.
    private var activeCustomChallenges: [CustomChallenge] {
        guard settings.circleMode == .real else { return profile.customChallenges }
        // v4 Phase C FIX: a challenge the user has REMOVED is subtracted from
        // the mirror while its delete is still queued. `deleteCustomChallenge`
        // drops it from `profile.customChallenges`, but the synced copy is what
        // renders, so removing one offline used to leave the card on screen and
        // `ChallengeEngine` scoring it until the queue drained and a full pull
        // came back. (`CircleSync.applyAcknowledged` closes the other half of
        // the window — after the delete lands and before the next pull.)
        let removed: Set<String> = circleSync?.pendingChallengeDeletions ?? []
        let synced: [CustomChallenge] = circleSnapshot.customChallenges.filter {
            !removed.contains($0.id)
        }
        let syncedIDs: Set<String> = Set(synced.map { $0.id })
        let pending: [CustomChallenge] = profile.customChallenges.filter {
            !syncedIDs.contains($0.id) && !removed.contains($0.id)
        }
        return synced + pending
    }

    func createCustomChallenge(prayer: Prayer, days: Int) {
        let challenge = CustomChallenge(id: "custom-\(UUID().uuidString)",
                                        prayer: prayer,
                                        days: max(2, min(7, days)),
                                        createdAt: AppClock.now)
        profile.customChallenges.append(challenge)
        persistProfile()
        mirrorChallengeCreated(challenge)
        objectWillChange.send()
    }

    /// Whether THIS device may retract that challenge.
    ///
    /// v4 §5: a custom challenge belongs to the CIRCLE, and the server agrees —
    /// `custom_challenges_delete` is `created_by = auth.uid()`. A delete aimed
    /// at somebody else's row therefore matches zero rows and *succeeds*
    /// (PostgREST answers 204, not an error): the card would vanish here, the
    /// outbox would call the op done, and the next full pull would put it
    /// straight back. Refusing locally is the honest version of the same
    /// answer, and it keeps `ChallengeEngine` scoring the same set on every
    /// device in the circle, which is the whole point of syncing them.
    ///
    /// Demo mode has no server and no author — every challenge there is yours.
    /// A challenge the mirror has never heard of is yours too: it is one you
    /// just made, still queued.
    func canDeleteCustomChallenge(id: String) -> Bool {
        guard settings.circleMode == .real else { return true }
        guard let row = circleSnapshot.challenges.first(where: { $0.id == id }) else { return true }
        return row.createdBy == circleSnapshot.me
    }

    func deleteCustomChallenge(id: String) {
        guard canDeleteCustomChallenge(id: id) else { return }
        profile.customChallenges.removeAll { $0.id == id }
        persistProfile()
        mirrorChallengeDeleted(id: id)
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
        guard let weekDayKeys: [String] = lastCompletedWeekDayKeys() else { return nil }
        return GameEngine.weeklyRecap(logs: logs,
                                      weekDayKeys: weekDayKeys,
                                      excusedDayKeys: profile.excusedDayKeys)
    }

    /// The Mon–Sun keys of the most recent FINISHED week, or nil while that
    /// week is still undecided.
    ///
    /// Split out of `lastCompletedWeekRecap()` (behaviour unchanged) because
    /// the v4 circle page has to recap the SAME week: two independent
    /// derivations would eventually disagree, and the day they did, the Journey
    /// would show your week beside somebody else's.
    ///
    /// Sunday's isha window runs past midnight (it ends at Monday's fajr), so on
    /// Monday morning the week isn't decided yet — the same rule
    /// `reconcileStreakIfNeeded` follows. Wait one more window rather than
    /// publish a total a 1 AM isha log would silently change.
    private func lastCompletedWeekDayKeys() -> [String]? {
        let calendar = Calendar.current
        let thisWeekStart = BuddySimulator.weekStart(for: AppClock.now, calendar: calendar)
        guard let lastWeekDay = calendar.date(byAdding: .day, value: -1, to: thisWeekStart)
        else { return nil }
        let weekDayKeys = BuddySimulator.weekDayKeys(for: lastWeekDay, calendar: calendar)

        if let prev = previousIshaWindow,
           AppClock.now < prev.end,
           weekDayKeys.last == previousDayKey,
           !hasLog(prayer: .isha, dayKey: previousDayKey) {
            return nil
        }
        return weekDayKeys
    }

    // MARK: - The circle's week (v4 §5)

    /// The circle page of the weekly recap: who wore the crown, and the best
    /// single day anybody in the circle had, for the same finished week the
    /// personal card above it recaps.
    ///
    /// v4 DECISION: **real circles only.** It is computed from the MIRROR —
    /// synced posts, synced rest days, synced recovery totals — and demo mode
    /// has no mirror, only a deterministic function of a buddy's name. Crowning
    /// a simulated friend for a week the simulator invented would be a trophy
    /// for nobody. A solo account has no circle either, so both of v3.9's
    /// states render exactly as they do today: no page at all.
    ///
    /// Your own row comes from LOCAL logs rather than from your posts in the
    /// mirror, which is the same choice `weeklyScores()` makes: your device is
    /// the source of truth for your own week, and reading it back off the wire
    /// would make the number quietly depend on whether the queue had drained.
    func lastCompletedWeekCircleRecap() -> CircleWeekRecap? {
        guard let weekDayKeys: [String] = lastCompletedWeekDayKeys() else { return nil }
        let mine: Set<String> = Set(weekDayKeys)
        var myRecovery: Int = 0
        for key in weekDayKeys {
            myRecovery += profile.recoveryXPByDay[key] ?? 0
        }
        let you = CircleWeekEntry(member: youMember,
                                  logs: logs.filter { mine.contains($0.dayKey) },
                                  excusedDayKeys: profile.excusedDayKeys,
                                  recoveryXP: myRecovery)
        return AppState.circleRecap(mode: settings.circleMode, mirror: circleSnapshot,
                                    weekDayKeys: weekDayKeys, now: AppClock.now, you: you)
    }

    /// Everything the card needs, derived from the mirror — PURE, so the mode
    /// gate, the roster derivation and the math are all testable without an
    /// `AppState`, a clock or a schedule (which matters here: a real circle
    /// pins the developer clock to real time, so a test could not travel to a
    /// fixed week to exercise this any other way).
    ///
    /// `you` is passed in rather than dug out of the mirror because your own
    /// device is the source of truth for your own week — the same choice
    /// `weeklyScores()` makes.
    static func circleRecap(mode: CircleMode,
                            mirror: CircleSnapshot,
                            weekDayKeys: [String],
                            now: Date,
                            you: CircleWeekEntry) -> CircleWeekRecap? {
        guard mode == .real else { return nil }
        guard let lastDayKey: String = weekDayKeys.last else { return nil }
        // v4 Phase D FIX: only members who were IN the circle that week.
        //
        // Nothing used to compare membership to the week at all. Create a
        // circle on Tuesday and two friends join: the mirror holds only the
        // current week's backfill (§2), so for LAST week every buddy scores 0
        // while your own row comes from full local logs — and the card said
        // "You wore the crown 👑 / First in the circle to the weekly target"
        // for a week your friends were not in the circle. A crown nobody could
        // have raced you for is worse than no card.
        let buddies: [CircleMember] = mirror.buddyMembers.filter { member in
            AppState.wasInCircle(member: member, mirror: mirror, byDayKey: lastDayKey)
        }
        guard !buddies.isEmpty else { return nil }
        // The same question about you: a circle you joined this week has no
        // last week to recap, however full your own logs are.
        guard AppState.wasInCircle(userID: mirror.me, mirror: mirror, byDayKey: lastDayKey) else {
            return nil
        }

        // One Mon-start week is exactly one ISO week key — the same identity
        // `weeklyScores()` relies on for the live scoreboard.
        var weekKeys: [String] = []
        if let first = weekDayKeys.first, let day = AppClock.date(fromDayKey: first) {
            weekKeys.append(BuddySimulator.weekKey(for: day))
        }

        var entries: [CircleWeekEntry] = []
        for member in buddies {
            guard let userID = UUID(uuidString: member.id) else { continue }
            let theirs: [PrayerLog] = mirror.prayerLogs(userID: userID, dayKeys: weekDayKeys)
            // The same reveal the grid uses: nothing counts before its
            // `loggedAt`, so a post stamped in the future by a device with a
            // wrong clock cannot win a crown it hasn't earned yet.
            let visible: [PrayerLog] = theirs.filter { $0.loggedAt <= now }
            entries.append(CircleWeekEntry(member: member,
                                           logs: visible,
                                           excusedDayKeys: mirror.excusedDayKeys(userID: userID),
                                           recoveryXP: mirror.recoveryXP(userID: userID,
                                                                         weekKeys: weekKeys)))
        }
        entries.append(you)
        return AppState.circleRecap(weekDayKeys: weekDayKeys, entries: entries)
    }

    /// Was this member in the circle on or before `dayKey`?
    ///
    /// Compared as DAY KEYS rather than as dates: `joined_at` is an instant and
    /// `dayKey` is the local schedule day, and every other comparison in the app
    /// crosses that boundary the same way. Someone who joined on the Sunday of
    /// the recapped week counts — the join backfill publishes their week so far
    /// (§2), so they really do have a week in the circle.
    ///
    /// A member with NO `joined_at` counts too: the column is only ever nil on a
    /// mirror written before it was read back, and excluding somebody because an
    /// old `circle.json` is thin would hide the card rather than fix it.
    private static func wasInCircle(member: CircleMember, mirror: CircleSnapshot,
                                    byDayKey dayKey: String) -> Bool {
        guard let userID: UUID = UUID(uuidString: member.id) else { return false }
        return AppState.wasInCircle(userID: userID, mirror: mirror, byDayKey: dayKey)
    }

    private static func wasInCircle(userID: UUID?, mirror: CircleSnapshot,
                                    byDayKey dayKey: String) -> Bool {
        guard let userID: UUID = userID else { return false }
        guard let row = mirror.members.first(where: { $0.userID == userID }) else { return false }
        guard let joinedAt: Date = row.joinedAt else { return true }
        return AppClock.dayKey(for: joinedAt) <= dayKey
    }

    /// The recap itself — PURE, so it is testable without an `AppState`, a
    /// clock or a schedule. Every number below is `GameEngine`'s or
    /// `ChallengeEngine`'s; nothing here scores anything.
    static func circleRecap(weekDayKeys: [String],
                            entries: [CircleWeekEntry]) -> CircleWeekRecap? {
        guard let first = weekDayKeys.first, let last = weekDayKeys.last else { return nil }
        // A race of one is not a race — the same rule `race300WinnerID` follows
        // for the live crown, so the recap can never crown somebody the
        // scoreboard never did.
        guard entries.count >= 2 else { return nil }

        let keySet: Set<String> = Set(weekDayKeys)
        var standings: [CircleWeekRecap.Standing] = []
        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = []
        var bestDay: CircleWeekRecap.BestDay?
        var anyLogs: Bool = false

        for entry in entries {
            let weekLogs: [PrayerLog] = entry.logs.filter { keySet.contains($0.dayKey) }
            if !weekLogs.isEmpty { anyLogs = true }
            var prayerXP: Int = 0
            for key in weekDayKeys {
                let dayXP: Int = GameEngine.xp(forDay: key, logs: weekLogs,
                                               excusedDayKeys: entry.excusedDayKeys)
                prayerXP += dayXP
                let candidate = CircleWeekRecap.BestDay(member: entry.member, dayKey: key,
                                                        xp: dayXP)
                if AppState.isBetterDay(candidate, than: bestDay) {
                    bestDay = candidate
                }
            }
            // The scoreboard's number, so the recap agrees with what the Circle
            // tab showed all week: prayer XP plus the OPAQUE weekly recovery
            // total (§3). The crown below stays prayer-only, which is the split
            // SCORING.md already describes.
            standings.append(CircleWeekRecap.Standing(member: entry.member,
                                                      xp: prayerXP + max(0, entry.recoveryXP)))
            memberWeekLogs.append((entry.member, weekLogs))
        }
        guard anyLogs else { return nil }

        standings.sort { (lhs: CircleWeekRecap.Standing, rhs: CircleWeekRecap.Standing) -> Bool in
            if lhs.xp != rhs.xp { return lhs.xp > rhs.xp }
            return lhs.member.name < rhs.member.name
        }
        // The SAME function the live crown uses, at the same threshold, over
        // the same shape of input — the recap re-runs the race rather than
        // remembering who won it.
        let crownID: String? = ChallengeEngine.raceWinnerID(memberWeekLogs: memberWeekLogs)
        return CircleWeekRecap(weekStartDayKey: first, weekEndDayKey: last,
                               standings: standings, bestDay: bestDay, crownHolderID: crownID)
    }

    /// Which of two days is "the best day in the circle". PURE, and — the whole
    /// point — VIEWER-INDEPENDENT.
    ///
    /// v4 Phase D FIX: this used to be a plain `dayXP > best.xp` walked in
    /// "roster order, then you". That order is different on every phone, because
    /// every phone puts ITSELF last: on your device the walk is
    /// [Amina, Yusuf, you], on Amina's it is [you, Yusuf, Amina]. Two people
    /// with equally perfect Mondays — the common case, not an edge — therefore
    /// read two different "best day in the circle" for the same week.
    ///
    /// So the order is a property of the DATA: more XP, else the earlier day,
    /// else the lower name. Name and not id, because `youMember.id` is the
    /// literal "you" on whichever device is looking, while the name is what the
    /// standings already sort by. A 0-XP day never wins.
    static func isBetterDay(_ candidate: CircleWeekRecap.BestDay,
                            than current: CircleWeekRecap.BestDay?) -> Bool {
        guard let current: CircleWeekRecap.BestDay = current else { return candidate.xp > 0 }
        if candidate.xp != current.xp { return candidate.xp > current.xp }
        if candidate.dayKey != current.dayKey { return candidate.dayKey < current.dayKey }
        return candidate.member.name < current.member.name
    }

    /// One member's finished week as the circle recap sees it. Assembled by
    /// `lastCompletedWeekCircleRecap()` and handed to the pure function above,
    /// which is what keeps that function free of the mirror, the clock and the
    /// difference between you and everybody else.
    struct CircleWeekEntry {
        let member: CircleMember
        let logs: [PrayerLog]
        let excusedDayKeys: Set<String>
        /// The opaque weekly dhikr/deeds total (§3) — a number, never what
        /// earned it.
        let recoveryXP: Int
    }

    /// Journey → "The circle's week", for the most recent COMPLETED Mon–Sun
    /// week. Lives here rather than in `Models.swift` because it is assembled
    /// here and read by exactly one card.
    struct CircleWeekRecap: Equatable {
        let weekStartDayKey: String
        let weekEndDayKey: String
        /// Everyone, highest first, scored the way the weekly scoreboard scores
        /// them (prayer XP + the opaque recovery total).
        let standings: [Standing]
        /// The best single DAY anyone in the circle had — prayer XP only.
        let bestDay: BestDay?
        /// Who crossed the weekly target first that week; nil when nobody did,
        /// which is a perfectly normal week and says so on the card.
        let crownHolderID: String?

        struct Standing: Equatable, Identifiable {
            let member: CircleMember
            let xp: Int
            var id: String { member.id }
        }

        struct BestDay: Equatable {
            let member: CircleMember
            let dayKey: String
            let xp: Int
        }

        var crownHolder: CircleMember? {
            guard let crownHolderID else { return nil }
            return standings.first { $0.member.id == crownHolderID }?.member
        }

        var topScorer: CircleMember? { standings.first?.member }
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

    /// Notice that the device has crossed a meaningful number of timezones,
    /// and protect the days either side of the crossing from the streak walk.
    ///
    /// Runs at the very top of `refresh()` — before the reconcile below it —
    /// because a day has to be marked as travel BEFORE the walk decides
    /// whether to punish it. Landing in Mumbai and opening the app is the
    /// exact moment both facts are available.
    ///
    /// TWO days are marked, not one. The day you left is the truncated one:
    /// its prayers carry the departure zone's dayKey and its evening never
    /// arrived. The day you land is usually partial too, since you show up
    /// mid-afternoon into windows that already opened without you. Marking the
    /// arrival day cannot inflate anything — a complete day still increments
    /// the streak at log time via `applyStreakIncrement`, and this only ever
    /// removes a penalty, never grants a day.
    private func noteTimeZoneIfChanged() {
        let current = AppClock.utcOffsetSeconds
        defer {
            if profile.lastSeenUTCOffset != current {
                profile.lastSeenUTCOffset = current
                persistProfile()
            }
        }
        guard GameEngine.isTravelShift(from: profile.lastSeenUTCOffset, to: current) else { return }

        var marked = profile.travelDayKeys
        marked.insert(todayKey)
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: AppClock.now) {
            marked.insert(AppClock.dayKey(for: yesterday))
        }
        guard marked != profile.travelDayKeys else { return }
        profile.travelDayKeys = marked
        // Surfaced by the Today banner, which is the only thing that reads it.
        pendingTravelNotice = TravelNotice(offsetSeconds: current)
    }

    /// Recompute today's schedule and reconcile the streak for elapsed days.
    /// Call on launch, foreground, day change, and settings change.
    func refresh() {
        AppState.applyTimeTravelPolicy(for: settings.circleMode)
        noteTimeZoneIfChanged()

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
            // v4 §3: a break spans days, and each of them is a separate row on
            // the wire. Collected rather than mirrored inline, so the flags go
            // out only once the whole walk is on disk.
            var newlyExcused: [String] = []
            var day = AppClock.date(fromDayKey: since) ?? now
            let todayStart = calendar.startOfDay(for: now)
            while day <= todayStart {
                let key = AppClock.dayKey(for: day)
                if !profile.excusedDayKeys.contains(key) {
                    profile.excusedDayKeys.insert(key)
                    newlyExcused.append(key)
                    changed = true
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            if changed { persistProfile() }
            for key in newlyExcused {
                mirrorExcused(dayKey: key, on: true)
            }
        }

        reconcileStreakIfNeeded(now: now, calendar: calendar)
        awardNewlyCompletedChallenges()

        // v5 §3, LAST: the schedule this just recomputed is what decides which
        // window the home screen is about, and refresh() is the one call that
        // runs on launch, on foreground, on a day change and on a settings
        // change. Everything above it may have moved what the widget says.
        publishWidgetSnapshot()

        if settings.useDeviceLocation {
            location.refreshLocation()
        }
    }

    /// v4: keep the developer clock in step with the circle mode (SPEC-V4 §3).
    /// A real circle pins it to real time and clears any offset already set;
    /// demo mode hands time travel back. Runs at the top of every refresh —
    /// launch, foreground, day change and settings change all pass through
    /// here — and, from `init`, before anything reads `AppClock.now`.
    ///
    /// Static because `init` must call it before `self` is fully formed, and
    /// it writes only when the value actually changes: `refresh()` fires on
    /// every location callback, and each of those was a `UserDefaults` write.
    private static func applyTimeTravelPolicy(for mode: CircleMode) {
        let allowed: Bool = (mode == .demo)
        if AppClock.isTimeTravelAllowed != allowed {
            AppClock.isTimeTravelAllowed = allowed
        }
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
                                       excusedDayKeys: profile.excusedDayKeys,
                                       travelDayKeys: profile.travelDayKeys)
        persistProfile()
    }

    // MARK: - Persistence

    private func persist() {
        Store.save(profile, to: Store.profileFile)
        Store.save(logs, to: Store.logsFile)
        publishWidgetSnapshot()
    }

    private func persistProfile() {
        Store.save(profile, to: Store.profileFile)
        publishWidgetSnapshot()
    }

    // MARK: - The home screen (v5 §3)

    /// The last thing written to `widget.json`, so an unchanged state costs no
    /// disk write. Every mutation in this class ends in `persist()` or
    /// `persistProfile()` and most of them — a tasbih tap, a saved place, a
    /// settings toggle — move nothing the home screen shows.
    private var publishedWidgetSnapshot: WidgetSnapshot?

    /// v5 §3: rewrite `widget.json` from the current state.
    ///
    /// The widget is a separate process that re-derives NOTHING: no Adhan, no
    /// `GameEngine`, no simulator, no network. Everything it draws is decided
    /// here and handed over as a file in the shared container, which is why
    /// this is called from `persist()`/`persistProfile()` (every local change),
    /// from `applyCircleSnapshot` (every synced change) and from `refresh()`
    /// (the clock, the schedule and the day rolling over).
    ///
    /// `gridEntries` is the same call the Today grid makes, through the same
    /// `CircleDataSource` seam — that is §9-03's "demo renders too", and it is
    /// structural rather than remembered: by the time the builder sees them, a
    /// simulated buddy and a real friend are the same value type.
    ///
    /// `reloadTimelines` is FALSE by default and true from exactly one caller
    /// (backgrounding, in `RootView`). Writing is cheap; a reload is rationed —
    /// §5-A's budget is ~40–70 a day — and while the app is on screen the
    /// widget behind it has nothing to show anybody.
    func publishWidgetSnapshot(reloadTimelines: Bool = false) {
        let now: Date = AppClock.now
        let target: (window: PrayerWindow, dayKey: String)? =
            WidgetSnapshotBuilder.window(in: todaySchedule, carryOver: liveCarryOverIsha(), now: now)

        var entries: [GridEntry] = []
        var photoPaths: [String: String] = [:]
        var nudged: Set<String> = []
        if let target {
            let prayer: Prayer = target.window.prayer
            entries = gridEntries(for: prayer, dayKey: target.dayKey)
            let source: any CircleDataSource = circleSource
            for member in source.members {
                if let path: String = source.photoPath(forMember: member.id, prayer: prayer,
                                                       dayKey: target.dayKey, asOf: now) {
                    photoPaths[member.id] = path
                }
                if nudgesSent.contains(nudgeKey(member: member, prayer: prayer,
                                                dayKey: target.dayKey)) {
                    nudged.insert(member.id)
                }
            }
        }

        let snapshot: WidgetSnapshot = WidgetSnapshotBuilder.make(
            writtenAt: now,
            mode: settings.circleMode,
            streak: profile.streak,
            window: target,
            entries: entries,
            photoPaths: photoPaths,
            nudgedMemberIDs: nudged,
            // SPEC-V5 §7: the report hide is applied HERE, as the file is
            // written, so a photo somebody reported can never surface on their
            // home screen. See `WidgetSnapshotBuilder.thumb`.
            hiddenPhotoPaths: PhotoReports.shared.hiddenPaths)

        if publishedWidgetSnapshot?.hasSameContent(as: snapshot) != true {
            publishedWidgetSnapshot = snapshot
            WidgetFile.write(snapshot, to: Store.url(for: Store.widgetFile))
        }
        if reloadTimelines { WidgetBridge.reloadAllTimelines() }
    }

    /// Yesterday's isha while it is still the block you are standing in — the
    /// one window whose schedule day is not today's. `targetWindow` owns that
    /// decision (it also weighs whether the prayer has been logged), so it is
    /// asked rather than re-derived; this only names the answer.
    private func liveCarryOverIsha() -> (window: PrayerWindow, dayKey: String)? {
        guard let target = targetWindow(for: .isha), target.dayKey == previousDayKey else {
            return nil
        }
        return target
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

    /// What `fillDemoHistory()` actually produced, so the developer tools can
    /// confirm the action instead of leaving you guessing.
    struct DemoHistoryFill: Equatable {
        var logCount: Int
        var dayCount: Int
        var totalXP: Int

        /// Reads as a receipt, with real numbers — a generic "Done!" would not
        /// distinguish a successful fill from one that generated nothing.
        var summary: String {
            "Filled \(dayCount) days — \(logCount) prayers, \(totalXP) XP"
        }
    }

    /// 21 days of plausible history ending yesterday; profile is rebuilt from
    /// the generated logs so XP/streak/badges/perfect days stay consistent.
    /// ~70% of in-window logs get demo photos (PhotoStore.demoImage, "demo-"
    /// prefixed). Buddy history needs no filling — BuddySimulator derives it.
    ///
    /// Returns what it generated so the caller can SAY so. The action rewrites
    /// history behind the current screen and looked identical to a no-op —
    /// there is no way to tell "it worked" from "the button is dead" without
    /// leaving Settings and going to look.
    @discardableResult
    func fillDemoHistory() -> DemoHistoryFill {
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
        return DemoHistoryFill(logCount: logs.count,
                               dayCount: Set(logs.map(\.dayKey)).count,
                               totalXP: p.totalXP)
    }

    func resetAllData() {
        logs = []
        profile = UserProfile.fresh(now: AppClock.now)
        // v4: the synced mirror and the pending writes go too. `AppSettings()`
        // puts the app back in demo mode, so leaving them on disk would only
        // hide a real circle — flipping back to `.real` would resurrect the
        // roster, the posts and writes owed to a circle this device has wiped.
        circleSnapshot = .empty
        CircleSnapshot.clear()
        CircleOutbox.clear()
        // v5 §2: BEFORE the fresh settings are written, not after. `Store.delete`
        // reaches every directory the file could be in (see
        // `Store.allDirectories`) — including the copy the container migration
        // leaves in Documents — and everything else here is a delete, so this
        // is the one file that would otherwise keep its old shadow while the
        // live one was replaced.
        Store.delete(Store.settingsFile)
        // v5 §3: and the home screen, which is the one surface a reset cannot
        // reach by redrawing. `Store.delete` visits every directory the file
        // could be in; the memo goes with it so the republish below is not
        // skipped as "unchanged".
        Store.delete(Store.widgetFile)
        publishedWidgetSnapshot = nil
        settings = AppSettings()       // didSet persists + refreshes
        PhotoStore.deleteAll()
        BuddyPhotoCache.deleteAll()
        Store.delete(Store.logsFile)
        Store.delete(Store.profileFile)
        persist()
        refresh()
        // The file is current by now (`persist` wrote it), but the tile on the
        // home screen is still drawing the circle this just erased.
        WidgetBridge.reloadAllTimelines()
    }
}
