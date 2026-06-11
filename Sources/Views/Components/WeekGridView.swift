import SwiftUI

// Owned by the components agent.
/// Group data grid for the current week: one row per circle member, 7 day
/// columns (Mon-first), each day a stack of 5 mini-squares (Fajr→Isha)
/// colored with the §2 grid language. Legend included.
struct WeekGridView: View {
    let rows: [MemberWeekRow]

    private static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            grid
            legend
        }
    }

    // MARK: Grid

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 10) {
            // Day initials header.
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                    .frame(width: nameColumnWidth, height: 1)
                ForEach(0..<7, id: \.self) { i in
                    Text(Self.dayInitials[i])
                        .font(Theme.sans(11, .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(rows) { row in
                GridRow {
                    memberLabel(row.member)
                    ForEach(0..<7, id: \.self) { dayIndex in
                        dayColumn(row.days.indices.contains(dayIndex)
                                  ? row.days[dayIndex] : [])
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private let nameColumnWidth: CGFloat = 64

    private func memberLabel(_ member: CircleMember) -> some View {
        HStack(spacing: 4) {
            Text(member.emoji)
                .font(.system(size: 14))
            Text(member.isYou ? "You" : member.name)
                .font(Theme.sans(12, member.isYou ? .bold : .semibold))
                .foregroundStyle(member.isYou ? Theme.green : Theme.inkDeep)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: nameColumnWidth, alignment: .leading)
    }

    /// One day: 5 mini-squares stacked vertically (Fajr top → Isha bottom).
    private func dayColumn(_ cells: [GridCellState]) -> some View {
        VStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                miniSquare(cells.indices.contains(i) ? cells[i] : .future)
            }
        }
    }

    private func miniSquare(_ cell: GridCellState) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Theme.color(for: cell))
            .frame(width: 11, height: 11)
            .overlay {
                // §2: excused reads lilac + moon.
                if cell == .excused {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    // MARK: Legend

    private var legend: some View {
        let items: [(GridCellState, String)] = [
            (.inWindow(.onTime), "On time"),
            (.inWindow(.prayed), "Prayed"),
            (.inWindow(.lastCall), "Last call"),
            (.qada, "Made up"),
            (.excused, "Excused"),
            (.missed, "Missed"),
        ]
        return FlowingLegend(items: items)
    }
}

/// Compact wrapping legend: colored chip + label pairs.
private struct FlowingLegend: View {
    let items: [(GridCellState, String)]

    private let columns = [GridItem(.adaptive(minimum: 76), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.color(for: items[i].0))
                        .frame(width: 10, height: 10)
                        .overlay {
                            if items[i].0 == .excused {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 5.5, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(items[i].1)
                        .font(Theme.sans(10.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    let mina = CircleMember(id: "mina", name: "Mina", emoji: "🌸", isYou: false)
    let you = CircleMember(id: "you", name: "You", emoji: "🙂", isYou: true)
    let day: [GridCellState] = [.inWindow(.onTime), .inWindow(.prayed), .qada, .missed, .inWindow(.lastCall)]
    let excusedDay: [GridCellState] = Array(repeating: .excused, count: 5)
    let futureDay: [GridCellState] = Array(repeating: .future, count: 5)
    return WeekGridView(rows: [
        MemberWeekRow(id: "mina", member: mina,
                      days: [day, day, day, day, futureDay, futureDay, futureDay]),
        MemberWeekRow(id: "you", member: you,
                      days: [day, excusedDay, day, day, futureDay, futureDay, futureDay]),
    ])
    .padding()
    .background(Theme.surface)
}
#endif
