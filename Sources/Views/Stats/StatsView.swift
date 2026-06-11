import SwiftUI
import Charts

/// Journey tab — level card, 7-day XP chart, 5-week heatmap, stat tiles,
/// badge grid.
struct StatsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    levelCard
                    weeklyXPCard
                    heatmapCard
                    statTiles
                    badgeCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Your Journey")
                .font(Theme.rounded(30))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Level card

    private var levelCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LEVEL")
                        .font(Theme.rounded(13, .heavy))
                        .foregroundStyle(Theme.inkSoft)
                        .tracking(1.5)
                    Text("\(state.level)")
                        .font(Theme.rounded(56, .heavy))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text(state.levelTitle)
                    .font(Theme.rounded(16, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.green))
            }

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.inkSoft.opacity(0.18))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.gold, Theme.green],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(12, geo.size.width * levelProgress))
                            .animation(Theme.spring, value: levelProgress)
                    }
                }
                .frame(height: 14)

                HStack {
                    Text("\(state.xpIntoLevel) / \(state.xpNeededForLevel) XP")
                        .font(Theme.rounded(13, .bold))
                        .foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Text("Level \(state.level + 1) ahead!")
                        .font(Theme.rounded(13, .bold))
                        .foregroundStyle(Theme.gold)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var levelProgress: Double {
        guard state.xpNeededForLevel > 0 else { return 0 }
        return min(1, Double(state.xpIntoLevel) / Double(state.xpNeededForLevel))
    }

    // MARK: - 7-day XP chart

    private var weeklyXPCard: some View {
        let recaps = state.recaps(daysBack: 7)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Last 7 days", symbol: "bolt.fill", color: Theme.gold)

            Chart(recaps, id: \.dayKey) { recap in
                BarMark(
                    x: .value("Day", shortWeekday(recap.date)),
                    y: .value("XP", recap.xp)
                )
                .foregroundStyle(recap.dayKey == todayKey
                                 ? Theme.green.gradient
                                 : Theme.gold.gradient)
                .cornerRadius(6)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.inkSoft.opacity(0.2))
                    AxisValueLabel()
                        .font(Theme.rounded(11, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(Theme.rounded(11, .bold))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .frame(height: 160)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var todayKey: String { AppClock.dayKey(for: AppClock.now) }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    // MARK: - 5-week heatmap

    private var heatmapCard: some View {
        let recaps = state.recaps(daysBack: 35)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Last 5 weeks", symbol: "calendar", color: Theme.green)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(recaps, id: \.dayKey) { recap in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(heatColor(inWindowCount: recap.inWindowCount))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if recap.isPerfect {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .overlay {
                            if recap.dayKey == todayKey {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.ink.opacity(0.5), lineWidth: 2)
                            }
                        }
                }
            }

            HStack(spacing: 6) {
                Text("Fewer")
                    .font(Theme.rounded(11, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                ForEach(0...5, id: \.self) { count in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatColor(inWindowCount: count))
                        .frame(width: 14, height: 14)
                }
                Text("All 5 in window")
                    .font(Theme.rounded(11, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    /// 0 → light gray, 1–5 → progressively deeper green.
    private func heatColor(inWindowCount: Int) -> Color {
        switch max(0, min(5, inWindowCount)) {
        case 0: return Theme.inkSoft.opacity(0.15)
        case 1: return Theme.green.opacity(0.25)
        case 2: return Theme.green.opacity(0.45)
        case 3: return Theme.green.opacity(0.65)
        case 4: return Theme.green.opacity(0.85)
        default: return Theme.greenDark
        }
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        let tiles: [(symbol: String, color: Color, value: String, label: String)] = [
            ("flame.fill", Theme.coral, "\(state.profile.longestStreak)", "Longest streak"),
            ("star.fill", Theme.gold, "\(state.profile.perfectDayCount)", "Perfect days"),
            ("hands.sparkles.fill", Theme.sky, "\(state.logs.count)", "Prayers logged"),
            ("bolt.fill", Theme.lilac, "\(state.profile.totalXP)", "Total XP"),
        ]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tiles, id: \.label) { tile in
                VStack(spacing: 6) {
                    Image(systemName: tile.symbol)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(tile.color)
                    Text(tile.value)
                        .font(Theme.rounded(28, .heavy))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(tile.label)
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .cardStyle()
            }
        }
    }

    // MARK: - Badge grid

    private var badgeCard: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Badges", symbol: "rosette", color: Theme.gold)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Badges.all) { badge in
                    let earnedDate = state.profile.earnedBadges[badge.id]
                    VStack(spacing: 4) {
                        BadgeIcon(badge: badge, earned: earnedDate != nil)
                        if let date = earnedDate {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .font(Theme.rounded(10, .semibold))
                                .foregroundStyle(Theme.gold)
                        } else {
                            Text(badge.detail)
                                .font(Theme.rounded(9, .medium))
                                .foregroundStyle(Theme.inkSoft.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - Shared bits

    private func sectionTitle(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(Theme.rounded(18))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
    }
}
