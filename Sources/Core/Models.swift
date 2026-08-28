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

/// v3.2: window split into QUARTERS (was thirds) — a steeper early-bird curve
/// so there's always a real pull to pray sooner. Old logs keep their stored
/// xp and old tier rawValues still decode.
enum LogTier: String, Codable {
    case onTime, prayed, lastCall, closeCall, qada

    var xp: Int {
        switch self {
        case .onTime: return 30    // 1st quarter
        case .prayed: return 20    // 2nd quarter
        case .lastCall: return 15  // 3rd quarter
        case .closeCall: return 12 // 4th quarter — still beats making up later
        case .qada: return 5       // v3.7 (design session): dropped from 10 so a
                                   // make-up clearly trails any in-window log.
                                   // Old logs keep their stored xp.
        }
    }

    var label: String {
        switch self {
        case .onTime: return "On time! ⚡"
        case .prayed: return "Prayed"
        case .lastCall: return "Getting late"
        case .closeCall: return "Just made it"
        case .qada: return "Made up (Qada)"
        }
    }

    /// Logged within the window (anything but qada).
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

/// Where a prayer happened — one optional tap at post time, never required.
enum PlaceTag: String, Codable, CaseIterable, Identifiable {
    case home, masjid, work, onTheGo

    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .home: return "🏠"
        case .masjid: return "🕌"
        case .work: return "💼"
        case .onTheGo: return "📍"
        }
    }
    var displayName: String {
        switch self {
        case .home: return "Home"
        case .masjid: return "Masjid"
        case .work: return "Work"
        case .onTheGo: return "On the go"
        }
    }
}

struct PrayerLog: Codable, Identifiable, Equatable {
    var id: UUID
    var prayer: Prayer
    var dayKey: String          // "yyyy-MM-dd" local — the SCHEDULE day the window belongs to
    var loggedAt: Date
    var tier: LogTier
    var xp: Int
    var photoFilename: String?  // v2: in-window photo proof (nil for qada / v1 logs)
    var jamaat: Bool            // v2: prayed in congregation (+5 XP, tracked for challenges)
    var placeTag: PlaceTag?     // v3: optional "where I prayed" tag
    var placeName: String?      // v3: reverse-geocoded name when tagged .onTheGo
    /// v4: the device's UTC offset in SECONDS when this was logged.
    ///
    /// `dayKey` is a local-time string, so "2026-08-22" means one thing in
    /// Seattle and another in Mumbai and nothing on the log says which. This
    /// is the missing half, and it is what makes a prayer's IDENTITY
    /// `(prayer, dayKey, zone)` rather than `(prayer, dayKey)` — see
    /// `GameEngine.isSamePrayerInstance`. Scoring is untouched: `dayKey` alone
    /// still groups a day, so a six-prayer travel day is one complete day.
    ///
    /// nil for every log written before v4, and honestly so — a log written
    /// without it can never be told which zone it belonged to, so identity
    /// reads nil as "matches anything" and old data can never gain a
    /// duplicate.
    var utcOffset: Int?

    init(id: UUID, prayer: Prayer, dayKey: String, loggedAt: Date, tier: LogTier, xp: Int,
         photoFilename: String? = nil, jamaat: Bool = false,
         placeTag: PlaceTag? = nil, placeName: String? = nil,
         utcOffset: Int? = nil) {
        self.id = id
        self.prayer = prayer
        self.dayKey = dayKey
        self.loggedAt = loggedAt
        self.tier = tier
        self.xp = xp
        self.photoFilename = photoFilename
        self.jamaat = jamaat
        self.placeTag = placeTag
        self.placeName = placeName
        self.utcOffset = utcOffset
    }

    // Migration-safe decoding: v1/v2 logs (missing newer fields) must keep decoding.
    private enum CodingKeys: String, CodingKey {
        case id, prayer, dayKey, loggedAt, tier, xp, photoFilename, jamaat, placeTag, placeName
        case utcOffset
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
        placeTag = try c.decodeIfPresent(PlaceTag.self, forKey: .placeTag)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        utcOffset = try c.decodeIfPresent(Int.self, forKey: .utcOffset)
    }
}

/// v4: "you appear to have travelled" — raised once per crossing by
/// `AppState.noteTimeZoneIfChanged`, rendered by the Today banner.
struct TravelNotice: Equatable, Identifiable {
    /// The device's new UTC offset in seconds. Carried so the banner can say
    /// something concrete rather than gesturing at "somewhere else".
    let offsetSeconds: Int
    var id: Int { offsetSeconds }
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
    var excusedModeSince: String?              // v3.2: dayKey the "can't pray" break started (nil = not on a break)
    var dhikrByDay: [String: Int]              // v3.2: dayKey → dhikr count (taps), unlimited
    var customChallenges: [CustomChallenge]    // v3.2: group challenges the circle created
    var breakReason: String?                   // v3.4: "period" / "illness" / "other" — tailors break copy
    var recoveryXPByDay: [String: Int]         // v3.5: XP earned from dhikr+deeds per day (enforces soft cap)
    var deedsByDay: [String: [String]]         // v3.5: completed good-deed ids per day
    // v3.6 (design session Jun 11):
    var avatarFilename: String?                // profile photo (PhotoStore)
    var removedBuddyNames: [String]            // circle members removed by the user
    var invitedBuddyNames: [String]            // demo invites that "accepted" (from the invitable pool)
    var pendingNewMemberName: String?          // shows the "X just joined!" celebration once
    var partialExcuseStart: [String: Prayer]   // dayKey → first EXCUSED prayer that day (break started mid-day)
    var partialExcuseEnd: [String: Prayer]     // dayKey → first prayer that COUNTS again (resumed mid-day)
    /// v3.9 (solo-first): this account onboarded as an INDIVIDUAL — the circle
    /// starts empty and is built one invite at a time. False for every profile
    /// saved before v3.9, so existing users keep the 8-buddy demo circle.
    var startedSolo: Bool
    /// v3.9: weekKey whose group awards a mid-week removal voided. Shrinking the
    /// circle makes every group target easier, and for solo accounts the removal
    /// is free to undo — so a removal costs this week's group challenges.
    var groupAwardsFrozenWeek: String?
    /// v4: the UTC offset (seconds) this device last saw, so a change can be
    /// noticed. nil until the first observation.
    var lastSeenUTCOffset: Int?
    /// v4: days during which the device crossed a significant number of
    /// timezones. The streak walk skips them exactly as it skips excused days.
    ///
    /// Flying Seattle → Mumbai makes a local day roughly twelve hours shorter;
    /// the prayers you logged before boarding carry the departure zone's
    /// dayKey, and that day can never reach five. Breaking a streak for it
    /// punishes someone for being on a plane. This is not an excuse in the §3
    /// sense — nothing is disclosed and nothing syncs — it is the reconcile
    /// walk declining to judge a day that was not a whole day.
    var travelDayKeys: Set<String>
    /// v4.1: the dayKey whose streak increment ACTUALLY banked a freeze — the
    /// receipt undo needs and cannot reconstruct.
    ///
    /// Freezes cap at 2, so "every 7th day earns one" is not the same statement
    /// as "this 7th day earned one": a day-21 increment for somebody already
    /// holding two banks nothing. Afterwards the two profiles are identical
    /// (streak 21, two freezes), so no pure function of the profile can tell
    /// them apart, and undo used to guess — spending a freeze earned two weeks
    /// earlier. Paired with `lastStreakDayKey`; nil means the last increment
    /// banked nothing (and, for a pre-v4.1 save, that undo declines to guess).
    var lastStreakFreezeDayKey: String?

    init(name: String, totalXP: Int, streak: Int, longestStreak: Int, streakFreezes: Int,
         lastStreakDayKey: String?, lastReconciledDayKey: String?, earnedBadges: [String: Date],
         perfectDayCount: Int, joinedAt: Date,
         excusedDayKeys: Set<String> = [], challengeCompletions: [String: Date] = [:],
         excusedModeSince: String? = nil, dhikrByDay: [String: Int] = [:],
         customChallenges: [CustomChallenge] = [], breakReason: String? = nil,
         recoveryXPByDay: [String: Int] = [:], deedsByDay: [String: [String]] = [:],
         avatarFilename: String? = nil, removedBuddyNames: [String] = [],
         invitedBuddyNames: [String] = [], pendingNewMemberName: String? = nil,
         partialExcuseStart: [String: Prayer] = [:], partialExcuseEnd: [String: Prayer] = [:],
         startedSolo: Bool = false, groupAwardsFrozenWeek: String? = nil,
         lastSeenUTCOffset: Int? = nil, travelDayKeys: Set<String> = [],
         lastStreakFreezeDayKey: String? = nil) {
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
        self.excusedModeSince = excusedModeSince
        self.dhikrByDay = dhikrByDay
        self.customChallenges = customChallenges
        self.breakReason = breakReason
        self.recoveryXPByDay = recoveryXPByDay
        self.deedsByDay = deedsByDay
        self.avatarFilename = avatarFilename
        self.removedBuddyNames = removedBuddyNames
        self.invitedBuddyNames = invitedBuddyNames
        self.pendingNewMemberName = pendingNewMemberName
        self.partialExcuseStart = partialExcuseStart
        self.partialExcuseEnd = partialExcuseEnd
        self.startedSolo = startedSolo
        self.groupAwardsFrozenWeek = groupAwardsFrozenWeek
        self.lastSeenUTCOffset = lastSeenUTCOffset
        self.travelDayKeys = travelDayKeys
        self.lastStreakFreezeDayKey = lastStreakFreezeDayKey
    }

    // Migration-safe decoding: v1 profiles lack the v2 fields.
    private enum CodingKeys: String, CodingKey {
        case name, totalXP, streak, longestStreak, streakFreezes
        case lastStreakDayKey, lastReconciledDayKey, earnedBadges, perfectDayCount, joinedAt
        case excusedDayKeys, challengeCompletions
        case excusedModeSince, dhikrByDay, customChallenges, breakReason
        case recoveryXPByDay, deedsByDay
        case avatarFilename, removedBuddyNames, invitedBuddyNames, pendingNewMemberName
        case partialExcuseStart, partialExcuseEnd
        case startedSolo, groupAwardsFrozenWeek
        case lastSeenUTCOffset, travelDayKeys
        case lastStreakFreezeDayKey
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
        excusedModeSince = (try? c.decodeIfPresent(String.self, forKey: .excusedModeSince)) ?? nil
        dhikrByDay = (try? c.decodeIfPresent([String: Int].self, forKey: .dhikrByDay)) ?? [:]
        customChallenges = (try? c.decodeIfPresent([CustomChallenge].self, forKey: .customChallenges)) ?? []
        breakReason = (try? c.decodeIfPresent(String.self, forKey: .breakReason)) ?? nil
        recoveryXPByDay = (try? c.decodeIfPresent([String: Int].self, forKey: .recoveryXPByDay)) ?? [:]
        deedsByDay = (try? c.decodeIfPresent([String: [String]].self, forKey: .deedsByDay)) ?? [:]
        avatarFilename = (try? c.decodeIfPresent(String.self, forKey: .avatarFilename)) ?? nil
        removedBuddyNames = (try? c.decodeIfPresent([String].self, forKey: .removedBuddyNames)) ?? []
        invitedBuddyNames = (try? c.decodeIfPresent([String].self, forKey: .invitedBuddyNames)) ?? []
        pendingNewMemberName = (try? c.decodeIfPresent(String.self, forKey: .pendingNewMemberName)) ?? nil
        partialExcuseStart = (try? c.decodeIfPresent([String: Prayer].self, forKey: .partialExcuseStart)) ?? [:]
        partialExcuseEnd = (try? c.decodeIfPresent([String: Prayer].self, forKey: .partialExcuseEnd)) ?? [:]
        // v3.9: absent → false, so a pre-v3.9 save keeps its 8-buddy circle.
        startedSolo = (try? c.decodeIfPresent(Bool.self, forKey: .startedSolo)) ?? false
        groupAwardsFrozenWeek = (try? c.decodeIfPresent(String.self, forKey: .groupAwardsFrozenWeek)) ?? nil
        lastSeenUTCOffset = (try? c.decodeIfPresent(Int.self, forKey: .lastSeenUTCOffset)) ?? nil
        travelDayKeys = (try? c.decodeIfPresent(Set<String>.self, forKey: .travelDayKeys)) ?? []
        // v4.1: absent → nil, i.e. "the last increment banked nothing". A save
        // written before this field existed loses the receipt for one pending
        // undo, and the default errs the safe way round: undo may decline to
        // take back a freeze it granted, but can never take one it did not.
        lastStreakFreezeDayKey = (try? c.decodeIfPresent(String.self, forKey: .lastStreakFreezeDayKey)) ?? nil
    }

    /// A brand-new account. v3.9: everyone starts solo — onboarding also sets
    /// the flag explicitly, so a new profile is safe either way.
    static func fresh(now: Date) -> UserProfile {
        UserProfile(name: "", totalXP: 0, streak: 0, longestStreak: 0,
                    streakFreezes: 0, lastStreakDayKey: nil, lastReconciledDayKey: nil,
                    earnedBadges: [:], perfectDayCount: 0, joinedAt: now,
                    startedSolo: true)
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

/// v4: which circle the app is showing. The locally simulated demo circle and
/// a real synced one are mutually exclusive (SPEC-V4 §2) — `.real` is entered
/// only by creating or joining a circle, and leaving returns to `.demo`.
enum CircleMode: String, Codable {
    case demo, real
}

/// The pre-v4.1 shape: one coordinate per tag, in a dictionary keyed by the
/// tag's rawValue. Kept ONLY so `AppSettings`'s decoder can migrate an existing
/// save — nothing else may refer to it.
private struct LegacySavedPlace: Codable {
    var latitude: Double
    var longitude: Double
}

/// A remembered spot you pray at.
///
/// v4.1: a LIST, not one-per-tag. The old shape allowed exactly one Masjid,
/// which is the unusual case — people pray at more than one, and the second
/// could never be suggested or even recorded. It also anchored on the FIRST
/// time you tagged something and never updated, so a Home saved at a friend's
/// house stayed your Home forever with no way to see or fix it.
///
/// `radiusMeters` is per-place because 250 m is a house, not a campus or a
/// hospital.
struct SavedPlace: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var tag: PlaceTag
    /// What YOU call it — "Masjid Al-Noor", "Dad's place". nil falls back to
    /// the tag's generic name.
    var name: String?
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double = SavedPlace.defaultRadiusMeters
    /// When it was first anchored. Journey shows "praying here since ...".
    var savedAt: Date?

    static let defaultRadiusMeters: Double = 250

    /// The label to show for this place: its own name if it has one, else the
    /// tag's ("Masjid").
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return tag.displayName
    }

    init(id: UUID = UUID(), tag: PlaceTag, name: String? = nil,
         latitude: Double, longitude: Double,
         radiusMeters: Double = SavedPlace.defaultRadiusMeters, savedAt: Date? = nil) {
        self.id = id
        self.tag = tag
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.savedAt = savedAt
    }

    // Tolerant, like every other persisted type here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        tag = try c.decode(PlaceTag.self, forKey: .tag)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radiusMeters = (try? c.decode(Double.self, forKey: .radiusMeters))
            ?? SavedPlace.defaultRadiusMeters
        savedAt = try? c.decodeIfPresent(Date.self, forKey: .savedAt)
    }

    /// Great-circle distance in meters (haversine) — pure, testable.
    func distanceMeters(latitude lat: Double, longitude lon: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat - latitude) * .pi / 180
        let dLon = (lon - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The nearest saved place you are standing inside, or nil.
    ///
    /// Each place is judged against its OWN radius rather than one global
    /// number, so a campus can be generous without making every house sloppy.
    /// Pure — the coordinate is an argument, never a location read.
    static func nearest(to lat: Double, _ lon: Double,
                        in places: [SavedPlace]) -> SavedPlace? {
        places
            .compactMap { place -> (SavedPlace, Double)? in
                let d = place.distanceMeters(latitude: lat, longitude: lon)
                return d <= place.radiusMeters ? (place, d) : nil
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Every saved place of one tag.
    static func all(_ tag: PlaceTag, in places: [SavedPlace]) -> [SavedPlace] {
        places.filter { $0.tag == tag }
    }
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
    /// v4.1: a LIST. Was `[String: SavedPlace]` keyed by tag rawValue, which
    /// permitted exactly one place per tag; the decoder below migrates that
    /// shape rather than dropping it.
    var savedPlaces: [SavedPlace] = []
    var memberKind: String? = nil      // v3.2: "brother" / "sister" (onboarding, optional) — tailors copy
    var isTraveling: Bool = false      // v3.3: travel mode — combine Dhuhr+Asr and Maghrib+Isha
    // v3.6: per-kind notification options (design session). Prayer nudges
    // default ON — turning them off kind of defeats the purpose.
    var notifyPrayerStart: Bool = true     // "X just came in" the moment a window opens
    var notifyLastCall: Bool = true        // 30 min before a window closes
    var notifyFriendActivity: Bool = false // "Mina just posted Dhuhr" (opt-in)
    var hasSeenTutorial: Bool = false      // v3.7: guided first-run tour completed/skipped
    /// v4: demo circle vs. a real synced one. Absent in a save means `.demo`,
    /// which is byte-for-byte v3.9 behaviour (a solo account's empty circle
    /// included), so every existing install keeps exactly what it had.
    var circleMode: CircleMode = .demo
    /// v4: the Circle screen's "turn notifications on" hint, once dismissed.
    /// Someone who declined at onboarding is never re-prompted by iOS, so the
    /// hint is the only thing telling them why nudges do nothing — but it is
    /// a suggestion, and a suggestion you cannot silence is an advert.
    var circlePushHintDismissed: Bool = false

    init() {}

    /// Does moving from `previous` to self change what the prayer SCHEDULE is?
    ///
    /// Exists so `AppState.settings.didSet` can stop recomputing the day for
    /// settings that have nothing to do with it. `refresh()` runs Adhan over
    /// the whole day, clears the schedule cache and reconciles streaks, and it
    /// was running synchronously on the main thread for every write — flipping
    /// a notification sub-toggle, dismissing a hint, recording a travel day.
    /// Inside whatever animation the control that made the change had started,
    /// which is what a stutter looks like.
    ///
    /// Deliberately a WHITELIST of the fields that really move the windows. A
    /// blacklist would silently stop refreshing the day the next field lands.
    func affectsSchedule(comparedTo previous: AppSettings) -> Bool {
        calcMethod != previous.calcMethod
            || madhab != previous.madhab
            || useDeviceLocation != previous.useDeviceLocation
            || fixedLatitude != previous.fixedLatitude
            || fixedLongitude != previous.fixedLongitude
            || isTraveling != previous.isTraveling
            || circleMode != previous.circleMode
            || hasOnboarded != previous.hasOnboarded
    }

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
        // The list shape first, then the pre-v4.1 dictionary. A dictionary
        // cannot decode as an array or vice versa, so the order is safe and the
        // fall-through is what carries an existing install's places across
        // instead of silently resetting somebody's Home to nothing.
        if let list = try? c.decode([SavedPlace].self, forKey: .savedPlaces) {
            savedPlaces = list
        } else if let legacy = try? c.decode([String: LegacySavedPlace].self,
                                             forKey: .savedPlaces) {
            // The tag lived in the KEY, so it has to be recovered from there.
            // An unrecognised key is dropped: it cannot be turned into a place
            // without a tag, and inventing one would be worse than losing it.
            savedPlaces = legacy.compactMap { key, place in
                guard let tag = PlaceTag(rawValue: key) else { return nil }
                return SavedPlace(tag: tag, latitude: place.latitude,
                                  longitude: place.longitude)
            }
            .sorted { $0.tag.rawValue < $1.tag.rawValue }   // dictionaries are unordered
        } else {
            savedPlaces = []
        }
        memberKind = (try? c.decodeIfPresent(String.self, forKey: .memberKind)) ?? nil
        isTraveling = (try? c.decode(Bool.self, forKey: .isTraveling)) ?? false
        notifyPrayerStart = (try? c.decode(Bool.self, forKey: .notifyPrayerStart)) ?? true
        notifyLastCall = (try? c.decode(Bool.self, forKey: .notifyLastCall)) ?? true
        notifyFriendActivity = (try? c.decode(Bool.self, forKey: .notifyFriendActivity)) ?? false
        hasSeenTutorial = (try? c.decode(Bool.self, forKey: .hasSeenTutorial)) ?? false
        // v4: absent → .demo, so a pre-v4 save keeps the simulated circle.
        circleMode = (try? c.decode(CircleMode.self, forKey: .circleMode)) ?? .demo
        circlePushHintDismissed =
            (try? c.decode(Bool.self, forKey: .circlePushHintDismissed)) ?? false
    }
}

// MARK: - Recharge (v3.5: good deeds during a break)

/// One phrase of the tasbih (dhikr after prayer): Arabic, transliteration,
/// meaning, and how many times it's repeated in a round (33 / 33 / 34 = 100).
struct TasbihPhrase: Equatable {
    let arabic: String
    let translit: String
    let meaning: String
    let count: Int
}

/// A good-deed prompt offered during a break — all universally encouraged
/// during menstruation (no Qur'an *reciting*, to sidestep the mushaf debate).
struct GoodDeed: Identifiable, Equatable {
    let id: String
    let emoji: String
    let title: String
    let arabic: String?
}

enum Recharge {
    static let roundTotal = 100

    static let tasbih: [TasbihPhrase] = [
        TasbihPhrase(arabic: "سُبْحَانَ اللّٰه", translit: "SubhanAllah",
                     meaning: "Glory be to Allah", count: 33),
        TasbihPhrase(arabic: "الْحَمْدُ لِلّٰه", translit: "Alhamdulillah",
                     meaning: "All praise is for Allah", count: 33),
        TasbihPhrase(arabic: "اللّٰهُ أَكْبَر", translit: "Allahu Akbar",
                     meaning: "Allah is the Greatest", count: 34),
    ]

    /// Phrase + how many of it are done so far, for a running total. `inSet`
    /// is 0-based within the current phrase; `phraseIndex` is 0/1/2.
    static func position(forTotal total: Int) -> (phrase: TasbihPhrase, inSet: Int, phraseIndex: Int) {
        let pos = ((total % roundTotal) + roundTotal) % roundTotal   // 0..99, safe for 0
        if pos < 33 { return (tasbih[0], pos, 0) }
        if pos < 66 { return (tasbih[1], pos - 33, 1) }
        return (tasbih[2], pos - 66, 2)
    }

    static let goodDeeds: [GoodDeed] = [
        GoodDeed(id: "salawat", emoji: "🤲", title: "Send 10 salawat ﷺ",
                 arabic: "اللّٰهُمَّ صَلِّ عَلَى مُحَمَّد"),
        GoodDeed(id: "istighfar", emoji: "💫", title: "Istighfar ×100",
                 arabic: "أَسْتَغْفِرُ اللّٰه"),
        GoodDeed(id: "dua", emoji: "💜", title: "Make du'a for someone you love", arabic: nil),
        GoodDeed(id: "sadaqah", emoji: "🌿", title: "Give a little sadaqah", arabic: nil),
        GoodDeed(id: "quran", emoji: "🎧", title: "Listen to a page of Qur'an", arabic: nil),
        GoodDeed(id: "gratitude", emoji: "🌸", title: "Note 3 things you're grateful for", arabic: nil),
    ]
}

// MARK: - Travel combining (v3.3)

/// While traveling (safar) you may combine (jam') Dhuhr+Asr and Maghrib+Isha.
/// Fajr is never combined. This helper defines the pairs and which prayer
/// leads (the earlier one). Qasr — shortening rak'ahs — isn't trackable here.
enum TravelPairs {
    /// The combinable pairs, lead (earlier) first.
    static let pairs: [(lead: Prayer, follow: Prayer)] = [(.dhuhr, .asr), (.maghrib, .isha)]

    /// The prayer combined with `prayer`, or nil for Fajr (never combined).
    static func partner(of prayer: Prayer) -> Prayer? {
        switch prayer {
        case .dhuhr: return .asr
        case .asr: return .dhuhr
        case .maghrib: return .isha
        case .isha: return .maghrib
        case .fajr: return nil
        }
    }

    /// The earlier prayer of `prayer`'s pair (itself if it's already the lead
    /// or Fajr).
    static func lead(of prayer: Prayer) -> Prayer {
        switch prayer {
        case .asr: return .dhuhr
        case .isha: return .maghrib
        default: return prayer
        }
    }

    static func isCombinable(_ prayer: Prayer) -> Bool { prayer != .fajr }
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
    /// v4: the window closed BEFORE this account existed. Not a miss — the
    /// person simply was not here yet, and telling someone they failed at
    /// four prayers within a minute of installing is the wrong first
    /// impression for an app about building a gentle habit. Distinct from
    /// `missedWindow` so nothing has to infer it from a date comparison.
    case beforeJoining
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
    /// v3.8: the user's profile photo (PhotoStore filename) — shown instead of
    /// the emoji wherever "you" appears. nil for simulated buddies.
    var avatarFilename: String? = nil
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
    /// v3: short place pill for posted squares, e.g. "🏠 Home" or "📍 Capitol Hill".
    var placeLabel: String? = nil
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

/// v3.2: a group challenge the circle defined themselves — "everyone logs
/// <prayer> for <days> days in a row". Reward scales with length.
struct CustomChallenge: Codable, Identifiable, Equatable {
    var id: String          // "custom-<uuid>"
    var prayer: Prayer
    var days: Int
    var createdAt: Date

    var rewardXP: Int { days * 15 }
    var title: String { "Everyone: \(prayer.displayName) ×\(days)" }
    var detail: String { "The whole circle logs \(prayer.displayName) \(days) days in a row" }
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

// MARK: - Weekly recap (v3.9)

/// Journey's "Your week" card for the most recent COMPLETED Mon–Sun week.
/// Personal only — no buddy data, so it reads the same solo or in a circle.
/// Built by `GameEngine.weeklyRecap` (pure) from `AppState.lastCompletedWeekRecap()`.
struct WeeklyRecap: Equatable {
    /// Monday of the recapped week, "yyyy-MM-dd".
    let weekStartDayKey: String
    /// Sunday of the recapped week, "yyyy-MM-dd".
    let weekEndDayKey: String
    let totalXP: Int
    /// Prayers logged that week, any tier (qada included).
    let prayersLogged: Int
    /// Days all 5 were logged (any tier) — the same rule the streak uses.
    let daysWithAllFive: Int
    /// Highest-XP day of the week; nil when the week earned nothing.
    let bestDay: BestDay?
    /// Photo highlights, chronological, spread across the week and capped at
    /// `GameEngine.weeklyRecapPhotoCap`. May be empty (a photo-less week).
    let photoFilenames: [String]

    struct BestDay: Equatable {
        let dayKey: String
        let xp: Int
    }
}
