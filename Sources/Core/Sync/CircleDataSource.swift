import Foundation

/// v4: the one seam between `AppState` and whoever the OTHER members of the
/// circle are (SPEC-V4 §8). Two implementations live behind it — the local
/// simulator in demo mode, and from Phase B3 the synced mirror of a real
/// circle. `AppState` still appends "you" itself: your own logs are the
/// on-device source of truth and never round-trip through a data source.
///
/// Every method takes `now` explicitly and reads no clock of its own, so the
/// circle stays exactly as time-travel-deterministic as v3.9's simulator was.
protocol CircleDataSource {

    /// The circle's members in display order, WITHOUT you.
    var members: [CircleMember] { get }

    /// How many friends the circle can hold (you don't count) — the cap the
    /// invite UI reports.
    var maxMembers: Int { get }

    /// One square of the Today grid: the member's post for `prayer` on
    /// `dayKey`, as of `now`. `window` is nil when that day's schedule can't
    /// be computed.
    func entry(forMember id: String, prayer: Prayer, dayKey: String,
               window: PrayerWindow?, now: Date) -> (state: GridEntryState, placeLabel: String?)

    /// One cell of the week grid — the same fact as `entry`, condensed.
    func cell(forMember id: String, prayer: Prayer, dayKey: String,
              window: PrayerWindow?, now: Date) -> GridCellState

    /// The member's posts across `days` that are visible by `now`, as
    /// `PrayerLog`s so `GameEngine`/`ChallengeEngine` treat everyone alike.
    func weekLogs(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> [PrayerLog]

    /// The member's weekly prayer XP as of `now` (same math the grid shows).
    func weeklyXP(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> Int

    /// The member's dhikr/deeds XP for those weeks — one opaque total per
    /// week, never the underlying deeds (SPEC-V4 §3).
    func recoveryXP(forMember id: String, weekKeys: [String]) -> Int

    /// The Storage path behind this member's post for one square, when there is
    /// one — the key `BuddyPhotoCache` resolves to bytes.
    ///
    /// v5 §3: the widget file names each post's photo, so the path has to come
    /// through the seam rather than through a cast to `RemoteCircleDataSource`
    /// at the one call site that happens to know. `now` is not decoration — a
    /// traveller's slot can hold two posts, and the path has to be resolved by
    /// the same rule at the same instant the tier was.
    func photoPath(forMember id: String, prayer: Prayer, dayKey: String,
                   asOf now: Date) -> String?
}

extension CircleDataSource {

    /// Most sources have no photo to name. A simulated buddy's post is a seeded
    /// illustration and an empty circle has no posts at all, so only the mirror
    /// overrides this — and it already did, with this exact signature, since v4
    /// Phase C.
    func photoPath(forMember id: String, prayer: Prayer, dayKey: String,
                   asOf now: Date) -> String? {
        nil
    }
}

/// A circle with nobody in it.
///
/// v4: the degenerate source — a circle that answers nothing. `AppState` now
/// reaches for `RemoteCircleDataSource` over an empty mirror instead (which
/// gives the same answers and can fill in once membership syncs), so this
/// remains as the explicit "no circle at all" case for callers that need one.
struct EmptyCircleDataSource: CircleDataSource {

    var members: [CircleMember] { [] }

    /// Never consulted while `members` is empty, but it must still be the REAL
    /// cap: this stands in for a circle that has no members yet, and quoting
    /// the demo simulator's 8 would advertise a friend slot the server refuses
    /// (a real circle seats 8 including you, so 7 friends).
    var maxMembers: Int { RemoteCircle.maxFriends }

    func entry(forMember id: String, prayer: Prayer, dayKey: String,
               window: PrayerWindow?, now: Date) -> (state: GridEntryState, placeLabel: String?) {
        (.waiting, nil)
    }

    func cell(forMember id: String, prayer: Prayer, dayKey: String,
              window: PrayerWindow?, now: Date) -> GridCellState {
        .future
    }

    func weekLogs(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> [PrayerLog] {
        []
    }

    func weeklyXP(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> Int {
        0
    }

    func recoveryXP(forMember id: String, weekKeys: [String]) -> Int { 0 }
}
