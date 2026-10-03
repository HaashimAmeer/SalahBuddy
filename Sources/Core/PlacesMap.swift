import Foundation

/// v5 (mockup): "Places you've prayed" on the Circle tab — the shared spots of
/// the month and the circle's Explorer of the month.
///
/// PRIVACY: only "On the go" spots (📍) and masjids (🕌) are shared. Home and
/// Work never appear, whatever a post carries, because those labels say where
/// somebody lives and works. The rule is applied HERE, to the labels, so no
/// screen can forget it.
///
/// PURE: the caller hands in every (person, place label) of the month.
enum PlacesMap {

    struct Visit: Equatable {
        let memberName: String
        let isYou: Bool
        let label: String
    }

    struct Spot: Equatable, Identifiable {
        let label: String
        let visits: Int
        let people: [String]
        var id: String { label }
        /// A stable position on the drawn map, 0…1 on each axis, kept off the
        /// edges. Seeded from the label so a spot never jumps between renders.
        var position: (x: Double, y: Double) {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in label.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            let x = Double(hash & 0xffff) / Double(0xffff)
            let y = Double((hash >> 16) & 0xffff) / Double(0xffff)
            return (0.12 + x * 0.76, 0.15 + y * 0.7)
        }
    }

    struct Explorer: Equatable {
        let name: String
        let isYou: Bool
        let spots: Int
    }

    static func isShareable(_ label: String) -> Bool {
        label.hasPrefix(PlaceTag.onTheGo.emoji) || label.hasPrefix(PlaceTag.masjid.emoji)
    }

    /// Distinct shareable spots, most visited first.
    static func spots(from visits: [Visit]) -> [Spot] {
        var counts: [String: Int] = [:]
        var people: [String: [String]] = [:]
        for visit in visits where isShareable(visit.label) {
            counts[visit.label, default: 0] += 1
            if !(people[visit.label] ?? []).contains(visit.memberName) {
                people[visit.label, default: []].append(visit.memberName)
            }
        }
        return counts
            .map { Spot(label: $0.key, visits: $0.value, people: people[$0.key] ?? []) }
            .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.label < $1.label }
    }

    /// Distinct shareable spots per person.
    static func spotCounts(from visits: [Visit]) -> [String: Int] {
        var seen: [String: Set<String>] = [:]
        for visit in visits where isShareable(visit.label) {
            seen[visit.memberName, default: []].insert(visit.label)
        }
        return seen.mapValues(\.count)
    }

    /// Whoever prayed in the most distinct shared spots this month. Ties go
    /// alphabetically so the title doesn't flicker between renders. Nil when
    /// nobody has a shared spot yet.
    static func explorer(from visits: [Visit]) -> Explorer? {
        let counts = spotCounts(from: visits)
        guard let best = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }) else { return nil }
        let isYou = visits.first { $0.memberName == best.key }?.isYou ?? false
        return Explorer(name: best.key, isYou: isYou, spots: best.value)
    }
}
