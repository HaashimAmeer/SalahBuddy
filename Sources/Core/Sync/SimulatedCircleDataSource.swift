import Foundation

/// v4: the demo circle behind the `CircleDataSource` seam.
///
/// This is `AppState`'s v3.9 circle code MOVED, not rewritten — the same
/// `BuddySimulator.outcome` derivation, the same "visible only once
/// `now >= loggedAt`" reveal, the same place tags. Demo mode must stay
/// byte-for-byte what it was, so `Tests/CircleSeamTests.swift` asserts every
/// answer here against `BuddySimulator` directly.
struct SimulatedCircleDataSource: CircleDataSource {

    /// The circle as the user shaped it (see `BuddySimulator.activeBuddies`).
    let buddies: [BuddySimulator.Buddy]

    var members: [CircleMember] {
        buddies.map { BuddySimulator.member(for: $0) }
    }

    var maxMembers: Int { BuddySimulator.maxFriends }

    /// Member ids are `BuddySimulator.member(for:)`'s "buddy.<name>" — resolve
    /// through it rather than rebuilding the string here.
    private func buddy(forMember id: String) -> BuddySimulator.Buddy? {
        buddies.first { BuddySimulator.member(for: $0).id == id }
    }

    // MARK: - Grid

    func entry(forMember id: String, prayer: Prayer, dayKey: String,
               window: PrayerWindow?, now: Date) -> (state: GridEntryState, placeLabel: String?) {
        guard let buddy = buddy(forMember: id), let window else { return (.waiting, nil) }

        switch BuddySimulator.outcome(for: buddy, dayKey: dayKey, window: window) {
        case .inWindow(let tier, let loggedAt, let seed):
            guard now >= loggedAt else { return (.waiting, nil) }
            let content: PostContent = .illustration(seed: seed)
            let tag: PlaceTag? = BuddySimulator.placeTag(seed: seed)
            let label: String? = tag.map { "\($0.emoji) \($0.displayName)" }
            return (.posted(content, tier: tier, at: loggedAt), label)
        case .qada(let at):
            if now >= at { return (.qada(at: at), nil) }
            return (.waiting, nil)
        case .missed:
            if now >= window.end { return (.missed, nil) }
            return (.waiting, nil)
        }
    }

    func cell(forMember id: String, prayer: Prayer, dayKey: String,
              window: PrayerWindow?, now: Date) -> GridCellState {
        guard let buddy = buddy(forMember: id) else { return .future }
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

    // MARK: - Week

    func weekLogs(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> [PrayerLog] {
        guard let buddy = buddy(forMember: id) else { return [] }
        return BuddySimulator.visibleLogs(for: buddy, days: days, asOf: now)
    }

    func weeklyXP(forMember id: String, days: [(dayKey: String, schedule: DaySchedule)],
                  asOf now: Date) -> Int {
        guard let buddy = buddy(forMember: id) else { return 0 }
        return BuddySimulator.weeklyXP(for: buddy, days: days, asOf: now)
    }

    /// Simulated buddies never take a break, so they earn no dhikr/deeds XP —
    /// the demo scoreboard is prayer XP alone, exactly as in v3.9.
    func recoveryXP(forMember id: String, weekKeys: [String]) -> Int { 0 }
}
