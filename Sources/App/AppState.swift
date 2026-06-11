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

        // Qada (after window, same schedule day): tap-only, no photo, no jamaat.
        let inWindow = tier.isInWindow
        let normalizedPhoto: String? = {
            guard inWindow, let name = photoFilename, !name.isEmpty else { return nil }
            return name
        }()
        let countsJamaat = inWindow && jamaat
        let countsPlace: PlaceTag? = inWindow ? placeTag : nil
        let xp = tier.xp + (countsJamaat ? GameEngine.jamaatBonus : 0)

        let excused = profile.excusedDayKeys.contains(target.dayKey)
        let levelBefore = GameEngine.level(forTotalXP: profile.totalXP)
        let wasPerfect = GameEngine.isPerfectDay(logs: logs, dayKey: target.dayKey,
                                                 excusedDayKeys: profile.excusedDayKeys)

        let entry = PrayerLog(id: UUID(), prayer: prayer, dayKey: target.dayKey,
                              loggedAt: AppClock.now, tier: tier, xp: xp,
                              photoFilename: normalizedPhoto, jamaat: countsJamaat,
                              placeTag: countsPlace,
                              placeName: countsPlace == .onTheGo ? placeName : nil)
        logs.append(entry)

        var newProfile = profile
        newProfile.totalXP += xp

        var bonusXP = 0
        var perfectDay = false
        if !wasPerfect,
           GameEngine.isPerfectDay(logs: logs, dayKey: target.dayKey,
                                   excusedDayKeys: profile.excusedDayKeys) {
            perfectDay = true
            bonusXP = GameEngine.perfectDayBonus
            newProfile.totalXP += bonusXP
            newProfile.perfectDayCount += 1
        }

        var streakExtended = false
        if !excused,
           GameEngine.isDayComplete(logs: logs, dayKey: target.dayKey),
           newProfile.lastStreakDayKey != target.dayKey {
            newProfile = GameEngine.applyStreakIncrement(to: newProfile, dayKey: target.dayKey)
            streakExtended = true
        }

        let newBadgeIDs = Badges.newlyEarnedIDs(profile: newProfile, logs: logs)
        for id in newBadgeIDs { newProfile.earnedBadges[id] = AppClock.now }

        let leveledUp = GameEngine.level(forTotalXP: newProfile.totalXP) > levelBefore

        profile = newProfile
        persist()
        awardNewlyCompletedChallenges()
        // The just-logged prayer's pending "Last call" must be dropped.
        NotificationManager.shared.reschedule()

        celebration = LogResult(prayer: prayer, tier: tier, xpEarned: xp, bonusXP: bonusXP,
                                newBadgeIDs: newBadgeIDs, leveledUp: leveledUp,
                                perfectDay: perfectDay, streakExtended: streakExtended)
    }

    /// Make-up path: tap-only, no photo, 10 XP. Only effective once the
    /// window has passed (same schedule day).
    func logQada(_ prayer: Prayer) {
        log(prayer, photoFilename: nil, jamaat: false)
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
        if let photo = removed.photoFilename {
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

    // MARK: - Excused days (v2)

    var isTodayExcused: Bool { profile.excusedDayKeys.contains(todayKey) }

    var excusedUsedThisMonth: Int {
        GameEngine.excusedCount(in: profile.excusedDayKeys, monthOf: todayKey)
    }

    /// Mark/unmark today as excused. Silently no-ops at the 10/month cap.
    func setTodayExcused(_ on: Bool) {
        let key = todayKey
        if on {
            guard !profile.excusedDayKeys.contains(key) else { return }
            guard excusedUsedThisMonth < GameEngine.maxExcusedPerMonth else { return }
            profile.excusedDayKeys.insert(key)
        } else {
            profile.excusedDayKeys.remove(key)
        }
        persistProfile()
    }

    // MARK: - Circle (v2)

    /// Grid order: buddies first, you LAST (isYou flag set).
    var circleMembers: [CircleMember] {
        BuddySimulator.buddies.map { BuddySimulator.member(for: $0) } + [youMember]
    }

    private var youMember: CircleMember {
        CircleMember(id: "you", name: profile.name.isEmpty ? "You" : profile.name,
                     emoji: "😄", isYou: true)
    }

    /// The circle's squares for one prayer on one schedule day, filling in
    /// live: a buddy's post appears only once AppClock.now >= its loggedAt.
    func gridEntries(for prayer: Prayer, dayKey: String) -> [GridEntry] {
        let now = AppClock.now
        let window = schedule(forDayKey: dayKey)?.window(for: prayer)
        var entries: [GridEntry] = []

        for buddy in BuddySimulator.buddies {
            let member = BuddySimulator.member(for: buddy)
            var state: GridEntryState = .waiting
            var placeLabel: String? = nil
            if let window {
                switch BuddySimulator.outcome(for: buddy, dayKey: dayKey, window: window) {
                case .inWindow(let tier, let loggedAt, let seed):
                    if now >= loggedAt {
                        state = .posted(.illustration(seed: seed), tier: tier, at: loggedAt)
                        placeLabel = BuddySimulator.placeTag(seed: seed).map { "\($0.emoji) \($0.displayName)" }
                    }
                case .qada(let at):
                    if now >= at { state = .qada(at: at) }
                case .missed:
                    if now >= window.end { state = .missed }
                }
            }
            entries.append(GridEntry(id: "\(member.id)|\(dayKey)|\(prayer.rawValue)",
                                     member: member, state: state, placeLabel: placeLabel))
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
        } else if profile.excusedDayKeys.contains(dayKey) {
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
        var scores: [(member: CircleMember, xp: Int)] = BuddySimulator.buddies.map { buddy in
            (BuddySimulator.member(for: buddy), BuddySimulator.weeklyXP(for: buddy, days: days, asOf: now))
        }
        let myXP = GameEngine.weeklyXP(logs: logs, weekStart: BuddySimulator.weekStart(for: now),
                                       excusedDayKeys: profile.excusedDayKeys)
        scores.append((youMember, myXP))
        return scores.sorted { $0.xp > $1.xp }
    }

    /// Current-week group data grid: one row per member, 7 day-columns of
    /// 5 prayer cells each (Mon-first).
    func weekRows() -> [MemberWeekRow] {
        let now = AppClock.now
        let dayKeys = BuddySimulator.weekDayKeys(for: now)

        var rows: [MemberWeekRow] = []
        for buddy in BuddySimulator.buddies {
            let member = BuddySimulator.member(for: buddy)
            let days: [[GridCellState]] = dayKeys.map { key in
                let schedule = self.schedule(forDayKey: key)
                return Prayer.allCases.map { prayer in
                    buddyCell(buddy: buddy, dayKey: key, window: schedule?.window(for: prayer), now: now)
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

    private func buddyCell(buddy: BuddySimulator.Buddy, dayKey: String,
                           window: PrayerWindow?, now: Date) -> GridCellState {
        guard let window, now >= window.start else { return .future }
        switch BuddySimulator.outcome(for: buddy, dayKey: dayKey, window: window) {
        case .inWindow(let tier, let loggedAt, _):
            return now >= loggedAt ? .inWindow(tier) : .future
        case .qada(let at):
            return now >= at ? .qada : .future
        case .missed:
            return now >= window.end ? .missed : .future
        }
    }

    private func myCell(dayKey: String, prayer: Prayer,
                        window: PrayerWindow?, now: Date) -> GridCellState {
        if let log = logs.first(where: { $0.dayKey == dayKey && $0.prayer == prayer }) {
            return log.tier.isInWindow ? .inWindow(log.tier) : .qada
        }
        if profile.excusedDayKeys.contains(dayKey) { return .excused }
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

        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = BuddySimulator.buddies.map { buddy in
            (BuddySimulator.member(for: buddy),
             BuddySimulator.visibleLogs(for: buddy, days: days, asOf: now))
        }
        memberWeekLogs.append((youMember, logs.filter { weekDayKeySet.contains($0.dayKey) }))

        return ChallengeEngine.Context(myLogs: logs,
                                       memberWeekLogs: memberWeekLogs,
                                       todayKey: todayKey,
                                       recentDayKeys: recentDayKeys,
                                       weekDayKeys: weekDayKeys,
                                       weekKey: BuddySimulator.weekKey(for: now),
                                       hardestPrayer: settings.hardestPrayer,
                                       completions: profile.challengeCompletions)
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
            let photos = dayLogs.compactMap(\.photoFilename)
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

        reconcileStreakIfNeeded(now: now, calendar: calendar)
        awardNewlyCompletedChallenges()

        if settings.useDeviceLocation {
            location.refreshLocation()
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
