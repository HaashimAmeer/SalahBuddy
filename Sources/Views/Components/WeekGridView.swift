import SwiftUI

// Owned by the components agent.
/// Group data grid for the current week, v3 redesign for parseability:
/// one row per member, 7 day columns (Mon-first), and ONE summary cell per
/// member-day — a rounded square whose green depth + number show how many of
/// the 5 prayers happened. Tap any cell to expand the per-prayer breakdown
/// underneath. Scales to large circles where the old 35-mini-squares-per-row
/// matrix became unreadable.
struct WeekGridView: View {
    let rows: [MemberWeekRow]

    @State private var selected: Selection?

    private struct Selection: Equatable {
        let rowID: String
        let dayIndex: Int
    }

    private static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]

    /// Mon-first index of today, used to highlight the current column.
    private var todayIndex: Int {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let weekday = cal.component(.weekday, from: AppClock.now)   // 1 = Sun
        return (weekday + 5) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            grid
            if let selected, let row = rows.first(where: { $0.id == selected.rowID }) {
                breakdown(row: row, dayIndex: selected.dayIndex)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("Tap a square for the prayer-by-prayer breakdown.")
                    .font(Theme.sans(10.5, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.8))
            }
            legend
        }
        .animation(Theme.spring, value: selected)
    }

    // MARK: Grid

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                    .frame(width: nameColumnWidth, height: 1)
                ForEach(0..<7, id: \.self) { i in
                    Text(Self.dayInitials[i])
                        .font(Theme.sans(11, i == todayIndex ? .heavy : .bold))
                        .foregroundStyle(i == todayIndex ? Theme.green : Theme.inkMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(rows) { row in
                GridRow {
                    memberLabel(row.member)
                    ForEach(0..<7, id: \.self) { dayIndex in
                        dayCell(row: row, dayIndex: dayIndex)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private let nameColumnWidth: CGFloat = 64

    private func memberLabel(_ member: CircleMember) -> some View {
        HStack(spacing: 4) {
            MemberAvatarView(member: member, size: 16)
            Text(member.isYou ? "You" : member.name)
                .font(Theme.sans(12, member.isYou ? .bold : .semibold))
                .foregroundStyle(member.isYou ? Theme.green : Theme.inkDeep)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: nameColumnWidth, alignment: .leading)
    }

    // MARK: Day summary cell

    private enum DaySummary: Equatable {
        case future
        case excused
        case count(done: Int, anyQada: Bool)   // done = in-window + made up, 0...5
    }

    private func summarize(_ cells: [GridCellState]) -> DaySummary {
        guard !cells.isEmpty, cells.contains(where: { $0 != .future }) else { return .future }
        if cells.allSatisfy({ $0 == .excused }) { return .excused }
        var done = 0
        var anyQada = false
        for cell in cells {
            switch cell {
            case .inWindow: done += 1
            case .qada: done += 1; anyQada = true
            case .missed, .excused, .future: break
            }
        }
        return .count(done: done, anyQada: anyQada)
    }

    private func dayCell(row: MemberWeekRow, dayIndex: Int) -> some View {
        let cells = row.days.indices.contains(dayIndex) ? row.days[dayIndex] : []
        let summary = summarize(cells)
        let isSelected = selected == Selection(rowID: row.id, dayIndex: dayIndex)

        return Button {
            let target = Selection(rowID: row.id, dayIndex: dayIndex)
            selected = (selected == target) ? nil : target
        } label: {
            cellBody(summary)
                .frame(width: 26, height: 26)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.inkDeep.opacity(0.55), lineWidth: 1.6)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(summary == .future)
    }

    @ViewBuilder
    private func cellBody(_ summary: DaySummary) -> some View {
        switch summary {
        case .future:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.mist.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
        case .excused:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.lilac)
                .overlay {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
        case .count(let done, let anyQada):
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fillColor(done: done))
                .overlay {
                    Text("\(done)")
                        .font(Theme.sans(12, .heavy))
                        .foregroundStyle(done == 0 ? Theme.inkMuted : .white)
                }
                .overlay(alignment: .topTrailing) {
                    // A made-up prayer is part of the count but flagged blue.
                    if anyQada {
                        Circle()
                            .fill(Theme.qadaBlue)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Theme.surface, lineWidth: 1.2))
                            .offset(x: 2.5, y: -2.5)
                    }
                }
        }
    }

    private func fillColor(done: Int) -> Color {
        switch done {
        case 0: return Theme.mist.opacity(0.45)
        case 5: return Theme.green
        default: return Theme.green.opacity(0.25 + 0.13 * Double(done))
        }
    }

    // MARK: Breakdown panel

    private func breakdown(row: MemberWeekRow, dayIndex: Int) -> some View {
        let cells = row.days.indices.contains(dayIndex) ? row.days[dayIndex] : []
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(row.member.emoji) \(row.member.isYou ? "You" : row.member.name) · \(dayName(dayIndex))")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(Theme.inkDeep)
            HStack(spacing: 6) {
                ForEach(Array(Prayer.allCases.enumerated()), id: \.element) { i, prayer in
                    let cell = cells.indices.contains(i) ? cells[i] : .future
                    VStack(spacing: 3) {
                        Text(prayer.emoji).font(.system(size: 13))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.color(for: cell))
                            .frame(height: 8)
                        Text(shortLabel(cell))
                            .font(Theme.sans(8.5, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dayName(_ index: Int) -> String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][index]
    }

    private func shortLabel(_ cell: GridCellState) -> String {
        switch cell {
        case .inWindow(.onTime): return "On time"
        case .inWindow(.prayed): return "Prayed"
        case .inWindow(.lastCall): return "Late"
        case .inWindow(.closeCall): return "Just made it"
        case .inWindow(.qada), .qada: return "Made up"
        case .missed: return "Missed"
        case .excused: return "Excused"
        case .future: return "—"
        }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach([1, 3, 5], id: \.self) { n in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor(done: n))
                        .frame(width: 10, height: 10)
                }
                Text("prayers that day")
                    .font(Theme.sans(10.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: 4) {
                Circle().fill(Theme.qadaBlue).frame(width: 7, height: 7)
                Text("made up")
                    .font(Theme.sans(10.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.lilac)
                    .frame(width: 10, height: 10)
                    .overlay(Image(systemName: "moon.fill")
                        .font(.system(size: 5.5, weight: .bold))
                        .foregroundStyle(.white))
                Text("excused")
                    .font(Theme.sans(10.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
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
