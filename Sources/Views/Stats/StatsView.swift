import SwiftUI
import Charts

/// Journey tab — level card, 7-day XP chart, 5-week heatmap (v2 grid color
/// language), photo calendar (BeReal-memories vibe), stat tiles, personal
/// challenges, badge grid. Styled per SPEC-V2 §2.
struct StatsView: View {
    @EnvironmentObject private var state: AppState

    @State private var displayedMonth: Date = AppClock.now
    @State private var selectedSummary: DayPhotoSummary?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    levelCard
                    weeklyXPCard
                    photoCalendarCard
                    heatmapCard
                    statTiles
                    challengesCard
                    badgeCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(item: $selectedSummary) { summary in
            DayPhotoSheet(summary: summary)
                .environmentObject(state)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Your Journey")
                .font(Theme.sans(30, .bold))
                .foregroundStyle(Theme.inkDeep)
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.green.opacity(0.55))
                .offset(y: -6)
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
                        .font(Theme.sans(13, .heavy))
                        .foregroundStyle(Theme.inkMuted)
                        .tracking(1.5)
                    Text("\(state.level)")
                        .font(Theme.sans(56, .heavy))
                        .foregroundStyle(Theme.inkDeep)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text(state.levelTitle)
                    .font(Theme.sans(16, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.green))
            }

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.greenSoft)
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
                        .font(Theme.sans(13, .bold))
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Text("Level \(state.level + 1) ahead!")
                        .font(Theme.sans(13, .bold))
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
                    AxisGridLine().foregroundStyle(Theme.inkMuted.opacity(0.2))
                    AxisValueLabel()
                        .font(Theme.sans(11, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(Theme.sans(11, .bold))
                        .foregroundStyle(Theme.inkMuted)
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

    // MARK: - Photo calendar (v2)

    private var photoCalendarCard: some View {
        let summaries = state.photoSummaries(monthOf: displayedMonth)
        let summaryByDayKey = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle("Memories", symbol: "camera.fill", color: Theme.green)
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.inkDeep)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.greenSoft))
                }
                .buttonStyle(.plain)
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canGoForward ? Theme.inkDeep : Theme.inkMuted.opacity(0.4))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.greenSoft.opacity(canGoForward ? 1 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
            }

            Text(monthTitle)
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.inkMuted)

            // Weekday header, Mon-first.
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["M", "T", "W", "T2", "F", "S", "S2"], id: \.self) { label in
                    Text(String(label.prefix(1)))
                        .font(Theme.sans(11, .bold))
                        .foregroundStyle(Theme.inkMuted.opacity(0.7))
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { i in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .id("blank-\(i)")
                }
                ForEach(monthDays, id: \.dayKey) { day in
                    calendarCell(day: day, summary: summaryByDayKey[day.dayKey])
                }
            }

            if summaries.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                    Text("No photos this month yet — post a prayer to start your memories!")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    @ViewBuilder
    private func calendarCell(day: (dayKey: String, date: Date, dayNumber: Int),
                              summary: DayPhotoSummary?) -> some View {
        let isFuture = day.date > AppClock.now
        let isExcused = state.profile.excusedDayKeys.contains(day.dayKey)

        Group {
            if let summary, let first = summary.photoFilenames.first {
                Button { selectedSummary = summary } label: {
                    PhotoThumb(filename: first)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Text("\(day.dayNumber)")
                                .font(Theme.sans(9, .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.inkDeep.opacity(0.55)))
                                .padding(3)
                        }
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isExcused ? Theme.lilac.opacity(0.35)
                          : isFuture ? Theme.greenSoft.opacity(0.25)
                          : Theme.greenSoft.opacity(0.5))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if isExcused {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.lilac)
                        } else {
                            Text("\(day.dayNumber)")
                                .font(Theme.sans(11, .semibold))
                                .foregroundStyle(Theme.inkMuted.opacity(isFuture ? 0.4 : 0.8))
                        }
                    }
            }
        }
        .overlay {
            if day.dayKey == todayKey {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.green, lineWidth: 2)
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private var monthDays: [(dayKey: String, date: Date, dayNumber: Int)] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        var result: [(dayKey: String, date: Date, dayNumber: Int)] = []
        var day = interval.start
        while day < interval.end {
            result.append((dayKey: AppClock.dayKey(for: day), date: day,
                           dayNumber: calendar.component(.day, from: day)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Blank cells before the 1st so the grid is Mon-first.
    private var leadingBlanks: Int {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return 0 }
        let weekday = calendar.component(.weekday, from: interval.start)   // 1 = Sunday
        return (weekday + 5) % 7
    }

    private var canGoForward: Bool {
        let calendar = Calendar.current
        return !calendar.isDate(displayedMonth, equalTo: AppClock.now, toGranularity: .month)
            && displayedMonth < AppClock.now
    }

    private func shiftMonth(_ delta: Int) {
        guard delta < 0 || canGoForward else { return }
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
        }
    }

    // MARK: - 5-week heatmap (v2 grid color language)

    private var heatmapCard: some View {
        let recaps = state.recaps(daysBack: 35)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Last 5 weeks", symbol: "calendar", color: Theme.green)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(recaps, id: \.dayKey) { recap in
                    let excused = state.profile.excusedDayKeys.contains(recap.dayKey)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(heatColor(recap: recap, excused: excused))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if excused {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                            } else if recap.isPerfect {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .overlay {
                            if recap.dayKey == todayKey {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.inkDeep.opacity(0.5), lineWidth: 2)
                            }
                        }
                }
            }

            // Legend — the §2 grid color language.
            HStack(spacing: 10) {
                legendSwatch(Color(hex: 0x1F8A50), "In window")
                legendSwatch(Theme.qadaBlue, "Made up")
                legendSwatch(Theme.lilac, "Excused")
                legendSwatch(Theme.mist, "Missed")
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(Theme.sans(11, .semibold))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    /// §2 grid language per day: lilac = excused, greens scale with in-window
    /// count (deep green at 5), blue = made-up-only day, mist = missed.
    private func heatColor(recap: DayRecap, excused: Bool) -> Color {
        if excused { return Theme.lilac }
        if recap.inWindowCount > 0 {
            switch min(5, recap.inWindowCount) {
            case 1: return Theme.green.opacity(0.30)
            case 2: return Theme.green.opacity(0.50)
            case 3: return Theme.green.opacity(0.70)
            case 4: return Theme.green.opacity(0.88)
            default: return Color(hex: 0x1F8A50)   // deep green — all 5 in window
            }
        }
        if recap.loggedCount > 0 { return Theme.qadaBlue }          // qada-only day
        if recap.dayKey == todayKey { return Theme.greenSoft.opacity(0.5) }  // today, nothing yet
        return Theme.mist                                            // missed (never red)
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        let tiles: [(symbol: String, color: Color, value: String, label: String)] = [
            ("flame.fill", Theme.amber, "\(state.profile.longestStreak)", "Longest streak"),
            ("star.fill", Theme.gold, "\(state.profile.perfectDayCount)", "Perfect days"),
            ("hands.sparkles.fill", Theme.qadaBlue, "\(state.logs.count)", "Prayers logged"),
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
                        .font(Theme.sans(28, .heavy))
                        .foregroundStyle(Theme.inkDeep)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(tile.label)
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .cardStyle()
            }
        }
    }

    // MARK: - Personal challenges (v2)

    private var challengesCard: some View {
        let personal = state.challenges().filter { !$0.isGroup }
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Challenges", symbol: "star.circle.fill", color: Theme.gold)

            if personal.isEmpty {
                Text("New challenges land here — keep praying!")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                VStack(spacing: 10) {
                    ForEach(personal) { progress in
                        ChallengeCard(progress: progress)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
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
                                .font(Theme.sans(10, .semibold))
                                .foregroundStyle(Theme.gold)
                        } else {
                            Text(badge.detail)
                                .font(Theme.sans(9, .medium))
                                .foregroundStyle(Theme.inkMuted.opacity(0.8))
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
                .font(Theme.sans(18, .bold))
                .foregroundStyle(Theme.inkDeep)
            Spacer()
        }
    }
}

// MARK: - Day photo sheet

/// Sheet shown when tapping a photo-calendar day: that day's photos plus a
/// per-prayer detail list (tier + time, qada, excused, missed).
private struct DayPhotoSheet: View {
    let summary: DayPhotoSummary
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sheetHeader
                    recapRow
                    photoStrip
                    prayerDetailCard
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Text(summary.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.gold)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.greenSoft))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
    }

    private var recapRow: some View {
        HStack(spacing: 8) {
            chip("\(summary.recap.xp) XP", color: Theme.gold)
            chip("\(summary.recap.inWindowCount)/5 in window", color: Theme.green)
            if summary.recap.isPerfect {
                chip("Perfect day ⭐", color: Theme.gold)
            }
            Spacer()
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.sans(12, .bold))
            .foregroundStyle(Theme.inkDeep)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(summary.photoFilenames, id: \.self) { filename in
                    PhotoThumb(filename: filename, pixelSize: 640)
                        .frame(width: 190, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var prayerDetailCard: some View {
        let dayLogs = state.logs.filter { $0.dayKey == summary.id }
        let excused = state.profile.excusedDayKeys.contains(summary.id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Prayers")
                .font(Theme.sans(16, .bold))
                .foregroundStyle(Theme.inkDeep)

            ForEach(Prayer.allCases) { prayer in
                prayerRow(prayer: prayer,
                          log: dayLogs.first { $0.prayer == prayer },
                          excused: excused)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func prayerRow(prayer: Prayer, log: PrayerLog?, excused: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(rowColor(log: log, excused: excused))
                .frame(width: 10, height: 10)
            Image(systemName: prayer.symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.color(for: prayer))
                .frame(width: 24)
            Text(prayer.displayName)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkDeep)
            Spacer()
            Text(rowStatus(log: log, excused: excused))
                .font(Theme.sans(13, .bold))
                .foregroundStyle(rowColor(log: log, excused: excused))
            if let filename = log?.photoFilename {
                PhotoThumb(filename: filename)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func rowColor(log: PrayerLog?, excused: Bool) -> Color {
        if let log {
            return Theme.color(for: log.tier.isInWindow ? .inWindow(log.tier) : .qada)
        }
        return excused ? Theme.lilac : Theme.mist
    }

    private func rowStatus(log: PrayerLog?, excused: Bool) -> String {
        if let log {
            let time = log.loggedAt.formatted(.dateTime.hour().minute())
            return log.tier.isInWindow ? "\(log.tier.label) · \(time)" : "Made up · \(time)"
        }
        return excused ? "Excused" : "Missed"
    }
}

// MARK: - Lazy thumbnail

/// Loads a photo off the main thread and decodes a small thumbnail so grids
/// never hold full-res UIImages (SPEC-V2 §6.10).
private struct PhotoThumb: View {
    let filename: String
    var pixelSize: CGFloat = 240

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Theme.greenSoft.opacity(0.6))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.inkMuted.opacity(0.5))
                        }
                }
            }
        }
        .task(id: filename) {
            guard image == nil else { return }
            let name = filename
            let target = CGSize(width: pixelSize, height: pixelSize)
            let thumb = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let full = PhotoStore.load(name) else { return nil }
                return full.preparingThumbnail(of: target) ?? full
            }.value
            image = thumb
        }
    }
}
