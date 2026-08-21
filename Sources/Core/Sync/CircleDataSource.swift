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
}

/// A circle with nobody in it.
///
/// v4: stands in for the real source until Phase B3 lands membership sync, so
/// `circleMode == .real` renders like a solo account instead of leaking demo
/// buddies into a real circle.
struct EmptyCircleDataSource: CircleDataSource {

    var members: [CircleMember] { [] }

    /// Never consulted while `members` is empty; mirrors the demo cap so the
    /// invite copy doesn't change shape when B3 replaces this.
    var maxMembers: Int { BuddySimulator.maxFriends }

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
