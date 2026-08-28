import ActivityKit
import Foundation

/// v5 §6 — the Live Activity's contract, and the second file (after
/// `WidgetSnapshot`) that BOTH processes compile.
///
/// A prayer window is a bounded event with a known end and changing state,
/// which is exactly what ActivityKit is for. The Lock Screen and the Dynamic
/// Island draw this; `LiveActivityController` (app-side) starts, moves and ends
/// it; and `notify`'s fan-out moves it with the app closed, which is the whole
/// reason §6 prefers this surface to a home-screen widget (§5: no API exists
/// for pushing an update to one of those).
///
/// **Three shapes have to agree, and only two of them are Swift.**
/// `backend/supabase/functions/_shared/liveactivity.ts` builds the JSON that
/// ActivityKit decodes into `ContentState` on the device. There is no reply, no
/// error and no log on that path: a shape that disagrees is a push that does
/// nothing, forever, silently. So:
///
/// - **Nothing here is a `Date`.** Every instant is a `Double` of seconds since
///   1970, because two JSON decoders we do not control (the server's and
///   ActivityKit's) would otherwise have to agree on a date strategy — the kind
///   of agreement that holds until an OS update.
/// - **`tier` is a bare `String`**, not `LogTier`. A tier a build has never
///   heard of must cost the colour of one chip, never the whole push. Same call
///   `WidgetSnapshot.Post`'s decoder makes.
/// - **Every field decodes with a default.** The app, the extension and the
///   function are versioned separately; a field added on one side reaches a
///   phone running last month's build of another.
///
/// **4 KB is the hard ceiling** on a pushed content state (§6), and a payload
/// one byte over is rejected whole rather than truncated. That is why there is
/// no photo field and cannot be one: the Lock Screen draws a picture only if it
/// is already in the shared container (§7 forbids a widget-only photo store),
/// and everything else is emoji, names, counts and tiers.
/// `Equatable` on top of `ActivityAttributes` (which is only `Codable`): the
/// planner compares the window a running activity is about against the window
/// the file now names, and that comparison IS the difference between moving an
/// activity and replacing it.
struct PrayerWindowAttributes: ActivityAttributes, Equatable {

    /// Which prayer, as its `Prayer.rawValue`.
    ///
    /// A STRING rather than the enum, for the tolerance reason above: a value
    /// this build cannot name costs the emoji and the colour, not the activity.
    /// `prayer` below is the typed reading of it.
    var prayerRaw: String
    /// The SCHEDULE day the window belongs to — an isha logged after midnight
    /// carries yesterday's (`Models.swift`).
    var dayKey: String
    /// Seconds since 1970. When this window closes, and therefore when the
    /// activity should end itself.
    var endsAt: Double

    var prayer: Prayer? { Prayer(rawValue: prayerRaw) }
    var endsAtDate: Date { Date(timeIntervalSince1970: endsAt) }

    init(prayerRaw: String, dayKey: String, endsAt: Double) {
        self.prayerRaw = prayerRaw
        self.dayKey = dayKey
        self.endsAt = endsAt
    }

    init(prayer: Prayer, dayKey: String, endsAt: Date) {
        self.init(prayerRaw: prayer.rawValue, dayKey: dayKey,
                  endsAt: endsAt.timeIntervalSince1970)
    }

    private enum CodingKeys: String, CodingKey {
        // `prayerRaw` crosses the wire as `prayer` — the server writes that key
        // (`buildLiveActivityAttributes`) and it is the name the JSON should
        // have; the Swift property is named for what it holds.
        case prayerRaw = "prayer"
        case dayKey
        case endsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prayerRaw = (try? c.decodeIfPresent(String.self, forKey: .prayerRaw)) ?? ""
        dayKey = (try? c.decodeIfPresent(String.self, forKey: .dayKey)) ?? ""
        endsAt = (try? c.decodeIfPresent(Double.self, forKey: .endsAt)) ?? 0
    }

    /// One person who has prayed this window.
    struct Face: Codable, Hashable, Sendable {
        var name: String
        var emoji: String
        /// `LogTier.rawValue`. See the note above on why it is not the enum.
        var tier: String

        var logTier: LogTier? { LogTier(rawValue: tier) }

        init(name: String, emoji: String, tier: String) {
            self.name = name
            self.emoji = emoji
            self.tier = tier
        }

        init(name: String, emoji: String, tier: LogTier) {
            self.init(name: name, emoji: emoji, tier: tier.rawValue)
        }

        private enum CodingKeys: String, CodingKey { case name, emoji, tier }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Friend"
            emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🙂"
            tier = (try? c.decodeIfPresent(String.self, forKey: .tier))
                ?? LogTier.prayed.rawValue
        }
    }

    struct ContentState: Codable, Hashable, Sendable {
        /// How many of `memberCount` have prayed this window, YOU INCLUDED —
        /// the same sentence the widget writes.
        var prayedCount: Int
        var memberCount: Int
        /// The one field that differs per phone, which is why the server's
        /// fan-out builds at most two payloads per event rather than one per
        /// person.
        var youLogged: Bool
        /// Newest first, capped at `PrayerWindowAttributes.faceCap`.
        var faces: [Face]
        /// Seconds since 1970 — when this state was decided. Not a timestamp
        /// for ordering (that is `aps.timestamp`, which ActivityKit uses to
        /// discard out-of-order pushes); it is what the surface may show as
        /// "as of".
        var updatedAt: Double

        init(prayedCount: Int, memberCount: Int, youLogged: Bool,
             faces: [Face] = [], updatedAt: Double = 0) {
            self.prayedCount = max(0, prayedCount)
            self.memberCount = max(0, memberCount)
            self.youLogged = youLogged
            self.faces = Array(faces.prefix(PrayerWindowAttributes.faceCap))
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case prayedCount, memberCount, youLogged, faces, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prayedCount = (try? c.decodeIfPresent(Int.self, forKey: .prayedCount)) ?? 0
            memberCount = (try? c.decodeIfPresent(Int.self, forKey: .memberCount)) ?? 0
            youLogged = (try? c.decodeIfPresent(Bool.self, forKey: .youLogged)) ?? false
            faces = (try? c.decodeIfPresent([Face].self, forKey: .faces)) ?? []
            updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
        }

        /// Nobody else in the circle. "0 of 1 prayed" is a strange way to tell
        /// somebody they have not prayed yet, and both surfaces say something
        /// else instead.
        var isSolo: Bool { memberCount <= 1 }

        /// 0…1 for the progress track. Zero-safe.
        var progress: Double {
            guard memberCount > 0 else { return 0 }
            return min(1, max(0, Double(prayedCount) / Double(memberCount)))
        }
    }

    /// How many faces the surface carries — four, matching
    /// `WidgetSnapshot.postCap` and §3's 4-up row, and matching
    /// `LIVE_ACTIVITY_FACE_CAP` on the server. A Live Activity is not a feed.
    static let faceCap: Int = 4

    /// Apple's ceiling on a pushed content state (§6). Stated here as well as
    /// on the server because it is the reason this type has no photo field:
    /// there is no way to send a picture, so the surface draws one out of the
    /// shared container or draws an emoji.
    static let pushBudgetBytes: Int = 4096

    /// Whether a state would survive the trip. PURE, and used by the app's
    /// tests rather than at runtime: the app sets its own activity's state
    /// directly (no 4 KB limit applies to a local update), and the SERVER is
    /// the side that has to trim. It is here so the budget is asserted against
    /// the SAME encoder both sides describe, in a test that fails on this side
    /// of the fence rather than on somebody's Lock Screen.
    static func fitsPushBudget(_ state: ContentState) -> Bool {
        guard let data: Data = try? JSONEncoder().encode(state) else { return false }
        return data.count <= PrayerWindowAttributes.pushBudgetBytes
    }
}
