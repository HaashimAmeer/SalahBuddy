import SwiftUI

// MARK: - Places you've prayed (v5 mockup)

@MainActor
extension AppState {

    /// Every place label your circle posted with this calendar month, up to
    /// now — yours included. The privacy filter is `PlacesMap`'s job.
    func placeVisitsThisMonth(now: Date) -> [PlacesMap.Visit] {
        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        var visits: [PlacesMap.Visit] = []
        var day = monthStart
        while day <= now {
            let dayKey = AppClock.dayKey(for: day)
            for prayer in Prayer.allCases {
                for entry in gridEntries(for: prayer, dayKey: dayKey) {
                    guard case .posted = entry.state, let label = entry.placeLabel else { continue }
                    visits.append(PlacesMap.Visit(memberName: entry.member.isYou ? "You" : entry.member.name,
                                                  isYou: entry.member.isYou, label: label))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return visits
    }
}

/// A stylised map — no tiles, no real geography, just the shape of the idea —
/// with the month's shared spots pinned on it, and the Explorer of the month.
struct PlacesCard: View {
    @EnvironmentObject private var state: AppState

    @State private var visits: [PlacesMap.Visit] = []

    var body: some View {
        let spots = PlacesMap.spots(from: visits)
        let explorer = PlacesMap.explorer(from: visits)
        let mine = PlacesMap.spotCounts(from: visits)["You"] ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Places you've prayed")
                    .font(Theme.sans(17, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("NEW")
                    .font(Theme.sans(10, .heavy))
                    .foregroundStyle(Color(hex: 0x7A5600))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xFFF3D1)))
                Spacer()
                Text(monthLabel)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            map(spots)

            if let explorer {
                HStack(spacing: 10) {
                    Text("🏆").font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Explorer of the month: \(explorer.name)")
                            .font(Theme.sans(14, .heavy))
                            .foregroundStyle(Theme.inkDeep)
                        Text(explorer.isYou
                             ? "\(explorer.spots) spots this month"
                             : "\(explorer.spots) spots this month · you have \(mine)")
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Tag a masjid or an on-the-go spot when you post, and it lands here.")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("🔒 Home and Work never appear here. Only on-the-go spots and masjids are shared with your circle, and only by the name you give them.")
                .font(Theme.sans(11.5, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardStyle()
        .task(id: state.todayKey) {
            visits = state.placeVisitsThisMonth(now: AppClock.now)
        }
    }

    private var monthLabel: String {
        AppClock.now.formatted(.dateTime.month(.wide))
    }

    private func map(_ spots: [PlacesMap.Spot]) -> some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xDFF2E6), Color(hex: 0xCFE8D9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                // The "land": two soft blobs and a river, purely decorative.
                Ellipse().fill(Theme.surface.opacity(0.45))
                    .frame(width: geo.size.width * 0.55, height: geo.size.height * 0.5)
                    .position(x: geo.size.width * 0.3, y: geo.size.height * 0.35)
                Ellipse().fill(Theme.surface.opacity(0.35))
                    .frame(width: geo.size.width * 0.5, height: geo.size.height * 0.55)
                    .position(x: geo.size.width * 0.72, y: geo.size.height * 0.68)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.8))
                    path.addCurve(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.25),
                                  control1: CGPoint(x: geo.size.width * 0.35, y: geo.size.height * 0.55),
                                  control2: CGPoint(x: geo.size.width * 0.6, y: geo.size.height * 0.45))
                }
                .stroke(Theme.qadaBlue.opacity(0.25), style: StrokeStyle(lineWidth: 8, lineCap: .round))

                ForEach(spots.prefix(8)) { spot in
                    pin(spot)
                        .position(x: geo.size.width * spot.position.x,
                                  y: geo.size.height * spot.position.y)
                }
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pin(_ spot: PlacesMap.Spot) -> some View {
        VStack(spacing: 2) {
            Text(String(spot.label.prefix(1)))
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.surface))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            Text(String(spot.label.dropFirst(2)))
                .font(Theme.sans(10, .heavy))
                .foregroundStyle(Theme.inkDeep)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.surface.opacity(0.85)))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spot.label), \(spot.visits) visits")
    }
}
