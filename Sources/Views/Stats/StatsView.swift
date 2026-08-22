import SwiftUI
import Charts

/// Journey tab — level card, 7-day XP chart, 5-week heatmap (v2 grid color
/// language), photo calendar (BeReal-memories vibe), stat tiles, personal
/// challenges, badge grid. Styled per SPEC-V2 §2.
struct StatsView: View {
    @EnvironmentObject private var state: AppState

    @State private var displayedMonth: Date = AppClock.now
    @State private var selectedSummary: DayPhotoSummary?
    @State private var showLevelRoad = false
    @State private var showScoring = false
    @State private var showTitleInfo = false
    @State private var selectedBadge: Badge?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        header
                            .id("tour-journey-top")
                        // v3.7: the guided tour spotlights the level + scoring
                        // + badges block as one "your progress" unit.
                        VStack(spacing: 16) {
                            levelCard
                            scoringRow
                            badgeStrip
                        }
                        .tutorialTarget(.journey)
                        weeklyXPCard
                        // v3.9: last week's payoff sits right under the live
                        // 7-day chart — recent past, then all-time below.
                        weeklyRecapCard
                        // v4 §5: the same week, seen by the circle. Second, and
                        // invisible unless there is a real circle to recap.
                        circleRecapCard
                        // v3.8: challenges surfaced above memories (design
                        // session) — they were buried at the bottom.
                        challengesCard
                        photoCalendarCard
                        statTiles
                        placesCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }

            // v3.6: centered modals (design session) — nicer than a bottom
            // sheet, X to dismiss.
            if showScoring {
                CenteredModal(onClose: { showScoring = false }) {
                    ScoringExplainerContent()
                }
                .zIndex(5)
            }
            if showTitleInfo {
                CenteredModal(onClose: { showTitleInfo = false }) {
                    titleInfoContent
                }
                .zIndex(5)
            }
            // v3.6: tap a badge ("Kindling"?) to see what it takes to earn.
            if let badge = selectedBadge {
                CenteredModal(onClose: { selectedBadge = nil }) {
                    badgeInfoContent(badge)
                }
                .zIndex(5)
            }
        }
        .animation(Theme.spring, value: showScoring)
        .animation(Theme.spring, value: showTitleInfo)
        .animation(Theme.spring, value: selectedBadge?.id)
        .sheet(item: $selectedSummary) { summary in
            DayPhotoSheet(summary: summary)
                .environmentObject(state)
        }
        .sheet(isPresented: $showLevelRoad) {
            LevelRoadSheet()
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
        .padding(.top, 16)
    }

    /// v3.6: "How scoring works" lives here now (moved from Settings) — a
    /// little box right under the levels, like it looked on the old profile.
    private var scoringRow: some View {
        Button {
            withAnimation(Theme.spring) { showScoring = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.gold)
                Text("How scoring works")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    /// What the current level title means — tap the chip on the level row.
    private var titleInfoContent: some View {
        VStack(spacing: 10) {
            Text(state.levelTitle)
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text(GameEngine.titleDescription(state.levelTitle))
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    // MARK: - Level card

    /// v3.2: condensed per the design session — one small row ("Level 1 ·
    /// Seeker · 20/100 XP" + progress bar), still tappable for the level road.
    private var levelCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Level \(state.level)")
                    .font(Theme.sans(17, .heavy))
                    .foregroundStyle(Theme.inkDeep)
                    .contentTransition(.numericText())
                // v3.6: tap the title to learn what it means.
                Button {
                    withAnimation(Theme.spring) { showTitleInfo = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(state.levelTitle)
                            .font(Theme.sans(12, .bold))
                        Image(systemName: "info.circle")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.green))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(state.xpIntoLevel)/\(state.xpNeededForLevel) XP")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.inkMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.gold)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.greenSoft)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.gold, Theme.green],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * levelProgress))
                        .animation(Theme.spring, value: levelProgress)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { showLevelRoad = true }
    }

    /// v3.2: badges out of hiding — a horizontal strip right under the level
    /// row, earned first.
    private var badgeStrip: some View {
        let earned = Badges.all.filter { state.profile.earnedBadges[$0.id] != nil }
        let unearned = Badges.all.filter { state.profile.earnedBadges[$0.id] == nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(earned + unearned) { badge in
                    // v3.6: tap a badge to see what it means / how to earn it.
                    Button {
                        withAnimation(Theme.spring) { selectedBadge = badge }
                    } label: {
                        BadgeIcon(badge: badge, earned: state.profile.earnedBadges[badge.id] != nil)
                            .frame(width: 64)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    /// What a badge is and how it's earned (tap "Kindling" etc.).
    private func badgeInfoContent(_ badge: Badge) -> some View {
        let earnedAt = state.profile.earnedBadges[badge.id]
        return VStack(spacing: 12) {
            BadgeIcon(badge: badge, earned: earnedAt != nil)
                .frame(width: 76)
            Text(badge.detail)
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let earnedAt {
                Text("Earned \(earnedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.gold)
            } else {
                Text("Not earned yet — you've got this 💪")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.green)
            }
        }
        .padding(.top, 2)
    }

    private var levelProgress: Double {
        guard state.xpNeededForLevel > 0 else { return 0 }
        return min(1, Double(state.xpIntoLevel) / Double(state.xpNeededForLevel))
    }

    // MARK: - 7-day XP chart

    private var weeklyXPCard: some View {
        let recaps = state.recaps(daysBack: 7)
        // v3.9: a brand-new (or long-idle) account used to get bare axes with
        // zero-height bars — say something friendly instead.
        let isEmpty = recaps.allSatisfy { $0.loggedCount == 0 }
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Last 7 days", symbol: "bolt.fill", color: Theme.gold)

            if isEmpty {
                weeklyXPEmptyState
            } else {
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
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    /// Same height as the chart so the card doesn't jump on the first log.
    private var weeklyXPEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.gold.opacity(0.6))
            Text("Your week will fill in here")
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Log your first prayer and this chart starts growing.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - "Your week" recap (v3.9)

    /// A small victory lap for the most recent COMPLETED Mon–Sun week — the
    /// BeReal-style payoff for a week of posts. Personal only (no buddy data),
    /// so it reads the same solo or in a circle, and it stays hidden entirely
    /// until that week holds at least one of your logs.
    @ViewBuilder
    private var weeklyRecapCard: some View {
        if let recap = state.lastCompletedWeekRecap() {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    sectionTitle("Your week", symbol: "trophy.fill", color: Theme.gold)
                    Text(weekRangeLabel(recap))
                        .font(Theme.sans(12, .bold))
                        .foregroundStyle(Theme.inkMuted)
                }

                // The XP hero — the one number the week is remembered by.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(recap.totalXP)")
                                .font(Theme.sans(32, .heavy))
                                .foregroundStyle(Theme.inkDeep)
                            Text("XP")
                                .font(Theme.sans(14, .heavy))
                                .foregroundStyle(Theme.gold)
                        }
                        Text(weekPraise(recap))
                            .font(Theme.sans(12.5, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.gold.opacity(0.75))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [Theme.gold.opacity(0.20), Theme.greenSoft.opacity(0.5)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )

                if recap.photoFilenames.isEmpty {
                    Text("No photos that week — snap one and next week's recap gets a highlight reel.")
                        .font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recap.photoFilenames, id: \.self) { filename in
                                PhotoThumb(filename: filename, pixelSize: 320)
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                HStack(spacing: 10) {
                    recapTile(symbol: "star.fill", color: Theme.gold,
                              value: "\(recap.daysWithAllFive)", label: "Days all 5")
                    recapTile(symbol: "hands.sparkles.fill", color: Theme.qadaBlue,
                              value: "\(recap.prayersLogged)", label: "Prayers")
                    if let best = recap.bestDay {
                        recapTile(symbol: "bolt.fill", color: Theme.green,
                                  value: bestDayLabel(best), label: "Best · \(best.xp) XP")
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func recapTile(symbol: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(Theme.sans(20, .heavy))
                .foregroundStyle(Theme.inkDeep)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Theme.sans(11, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Aug 11 – 17", or "Aug 28 – Sep 3" when the week straddles a month.
    private func weekRangeLabel(_ recap: WeeklyRecap) -> String {
        weekRangeLabel(startDayKey: recap.weekStartDayKey, endDayKey: recap.weekEndDayKey)
    }

    /// The same label from bare day keys — the circle page recaps the same week
    /// and must print it the same way.
    private func weekRangeLabel(startDayKey: String, endDayKey: String) -> String {
        guard let start = AppClock.date(fromDayKey: startDayKey),
              let end = AppClock.date(fromDayKey: endDayKey) else { return "" }
        let sameMonth = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
        let endText = sameMonth
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(endText)"
    }

    private func bestDayLabel(_ best: WeeklyRecap.BestDay) -> String {
        guard let date = AppClock.date(fromDayKey: best.dayKey) else { return "—" }
        return shortWeekday(date)
    }

    private func weekPraise(_ recap: WeeklyRecap) -> String {
        switch recap.daysWithAllFive {
        case 7: return "A perfect seven — masha'Allah 🌟"
        case 5, 6: return "Almost every day complete. Strong week 💪"
        case 1...4: return "\(recap.daysWithAllFive) full days in the book ✨"
        default: return "Every prayer counted — let's build on it 🌱"
        }
    }

    // MARK: - "The circle's week" (v4 §5)

    /// The circle page of the weekly recap: the crown and the best day anybody
    /// in the circle had, for the SAME finished week the personal card above
    /// recaps. It sits under that card and never in front of it — your own week
    /// is the thing you came to see.
    ///
    /// Absent entirely for a solo account and in demo mode, where
    /// `lastCompletedWeekCircleRecap()` answers nil: v3.9's Journey is
    /// byte-for-byte unchanged for both.
    @ViewBuilder
    private var circleRecapCard: some View {
        if let recap = state.lastCompletedWeekCircleRecap() {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    sectionTitle("The circle's week", symbol: "person.2.fill", color: Theme.green)
                    Text(weekRangeLabel(startDayKey: recap.weekStartDayKey,
                                        endDayKey: recap.weekEndDayKey))
                        .font(Theme.sans(12, .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
                crownRow(recap)
                if let best = recap.bestDay {
                    circleRow(symbol: "bolt.fill", tint: Theme.green,
                              title: bestDayTitle(best), subtitle: "Best day in the circle")
                }
                if let placing = placingLine(recap) {
                    Text(placing)
                        .font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func crownRow(_ recap: AppState.CircleWeekRecap) -> some View {
        circleRow(symbol: "crown.fill", tint: Theme.gold,
                  title: crownTitle(recap), subtitle: crownSubtitle(recap))
    }

    /// One glyph-and-two-lines row. Broken out with explicit `String`
    /// parameters so the card's body stays small — this file has already cost
    /// CI a type-check budget once.
    private func circleRow(symbol: String, tint: Color,
                           title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.sans(15, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func crownTitle(_ recap: AppState.CircleWeekRecap) -> String {
        guard let holder = recap.crownHolder else { return "No crown last week" }
        if holder.isYou { return "You wore the crown 👑" }
        return "\(holder.name) wore the crown 👑"
    }

    /// Deliberately says "the weekly target" rather than a number: the crown is
    /// decided by `ChallengeEngine.raceWinnerID`, and quoting a figure here
    /// would be a second place for it to drift from.
    private func crownSubtitle(_ recap: AppState.CircleWeekRecap) -> String {
        if recap.crownHolder != nil { return "First in the circle to the weekly target." }
        guard let top = recap.standings.first, top.xp > 0 else {
            return "A quiet week — this one's wide open."
        }
        let who: String = top.member.isYou ? "You led" : "\(top.member.name) led"
        return "Nobody reached the weekly target. \(who) with \(top.xp) XP."
    }

    private func bestDayTitle(_ best: AppState.CircleWeekRecap.BestDay) -> String {
        let who: String = best.member.isYou ? "You" : best.member.name
        guard let date = AppClock.date(fromDayKey: best.dayKey) else {
            return "\(who) · \(best.xp) XP"
        }
        return "\(who) · \(shortWeekday(date)) · \(best.xp) XP"
    }

    /// Where you finished — skipped when you wore the crown, because the row
    /// above has already said it better.
    private func placingLine(_ recap: AppState.CircleWeekRecap) -> String? {
        guard recap.crownHolder?.isYou != true else { return nil }
        guard let index = recap.standings.firstIndex(where: { $0.member.isYou }) else { return nil }
        let mine = recap.standings[index]
        // States the week, not the shortfall. Every neighbouring line in this
        // file stays on the user's side (the personal card's own zero case is
        // "Every prayer counted — let's build on it"), and this was the one
        // string that told them off.
        guard mine.xp > 0 else { return "A quiet week for you — this one's already running 🌱" }
        return "You finished \(ordinal(index + 1)) of \(recap.standings.count) with \(mine.xp) XP."
    }

    private func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
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

            memoriesLegend

            if summaries.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                    Text("No photos this month yet — post a prayer, then tap a day to relive it!")
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

    /// v3.2: the memories calendar IS the color calendar now (the separate
    /// 5-week heatmap is gone). Cells are colored by how the day went —
    /// distinct hues, not shades — and tapping a day with photos opens its
    /// carousel.
    @ViewBuilder
    private func calendarCell(day: (dayKey: String, date: Date, dayNumber: Int),
                              summary: DayPhotoSummary?) -> some View {
        let isFuture = day.date > AppClock.now
        let isExcused = state.profile.excusedDayKeys.contains(day.dayKey)
        let logged = loggedCount(dayKey: day.dayKey)
        let hasPhotos = (summary?.photoFilenames.isEmpty == false)

        Button {
            // v3.6: ANY past day opens — photo-less days too, so a forgotten
            // make-up can be logged retroactively from the day sheet.
            selectedSummary = summary ?? state.daySummary(dayKey: day.dayKey, date: day.date)
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dayColor(logged: logged, excused: isExcused, future: isFuture))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isExcused {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(day.dayNumber)")
                            .font(Theme.sans(11, logged > 0 ? .bold : .semibold))
                            .foregroundStyle(logged > 0 ? .white : Theme.inkMuted.opacity(isFuture ? 0.4 : 0.8))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasPhotos {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isFuture && !hasPhotos)
        .overlay {
            if day.dayKey == todayKey {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.inkDeep.opacity(0.6), lineWidth: 2)
            }
        }
    }

    /// Distinct prayers logged that day (in-window or made up).
    private func loggedCount(dayKey: String) -> Int {
        Set(state.logs.lazy.filter { $0.dayKey == dayKey }.map(\.prayer)).count
    }

    /// Distinct hues for separation (design session): green = all 5,
    /// amber = 3–4, gold = 1–2, mist = none, lilac = excused. Never red.
    private func dayColor(logged: Int, excused: Bool, future: Bool) -> Color {
        if excused { return Theme.lilac }
        if future { return Theme.greenSoft.opacity(0.25) }
        switch logged {
        case 5: return Theme.green
        case 3...4: return Theme.amber
        case 1...2: return Theme.gold.opacity(0.85)
        default: return Theme.mist.opacity(0.6)
        }
    }

    private var memoriesLegend: some View {
        HStack(spacing: 10) {
            legendSwatch(Theme.green, "All 5")
            legendSwatch(Theme.amber, "3–4")
            legendSwatch(Theme.gold.opacity(0.85), "1–2")
            legendSwatch(Theme.lilac, "Excused")
            legendSwatch(Theme.mist.opacity(0.6), "None")
            Spacer()
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

    // MARK: - All-time stats (v3.2: one compact card, explicit names)

    private var statTiles: some View {
        let rows: [(symbol: String, color: Color, value: String, label: String)] = [
            ("flame.fill", Theme.amber, "\(state.profile.longestStreak) days", "Longest streak ever"),
            ("star.fill", Theme.gold, "\(state.profile.perfectDayCount)", "Perfect days — all time"),
            ("hands.sparkles.fill", Theme.qadaBlue, "\(state.logs.count)", "Prayers logged — all time"),
            ("bolt.fill", Theme.lilac, "\(state.profile.totalXP)", "Total XP — all time"),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("All-time stats", symbol: "chart.bar.fill", color: Theme.lilac)
                .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element.label) { i, row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(row.color)
                        .frame(width: 26)
                    Text(row.label)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Text(row.value)
                        .font(Theme.sans(16, .heavy))
                        .foregroundStyle(Theme.inkDeep)
                        .contentTransition(.numericText())
                }
                .padding(.vertical, 9)
                if i < rows.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - Places (v3)

    /// Where you've been praying — counts per tag, plus the distinct
    /// on-the-go spots. Only shows once at least one post is tagged.
    @ViewBuilder
    private var placesCard: some View {
        let stats = state.placeStats()
        if !stats.counts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Places you've prayed", symbol: "mappin.and.ellipse", color: Theme.qadaBlue)

                HStack(spacing: 10) {
                    ForEach(stats.counts, id: \.tag) { item in
                        VStack(spacing: 4) {
                            Text(item.tag.emoji).font(.system(size: 22))
                            Text("\(item.count)")
                                .font(Theme.sans(20, .heavy))
                                .foregroundStyle(Theme.inkDeep)
                                .contentTransition(.numericText())
                            Text(item.tag.displayName)
                                .font(Theme.sans(11, .semibold))
                                .foregroundStyle(Theme.inkMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                if !stats.spots.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Spots on the go")
                            .font(Theme.sans(12, .bold))
                            .foregroundStyle(Theme.inkMuted)
                        ForEach(stats.spots.prefix(5), id: \.self) { spot in
                            HStack(spacing: 6) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.qadaBlue)
                                Text(spot)
                                    .font(Theme.sans(13, .semibold))
                                    .foregroundStyle(Theme.inkDeep)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
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
        // Recomputed live so a retroactive make-up updates the chips.
        let recap = state.daySummary(dayKey: summary.id, date: summary.date).recap
        return HStack(spacing: 8) {
            chip("\(recap.xp) XP", color: Theme.gold)
            chip("\(recap.inWindowCount)/5 in window", color: Theme.green)
            if recap.isPerfect {
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

    /// v3.9: photo-less days used to open with a silent empty strip — since
    /// v3.6 ANY past day opens here, so most of them have no photos at all.
    @ViewBuilder
    private var photoStrip: some View {
        if summary.photoFilenames.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.green.opacity(0.55))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No photos from this day")
                        .font(Theme.sans(14, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text("Prayers you post with the camera show up here.")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.greenSoft,
                                          style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    )
            )
        } else {
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
    }

    /// v3.6: past days are editable here — "I made it up but forgot to log
    /// it". Recent edits (≤2 days) still earn qada XP; older ones earn 0.
    private var isEditablePastDay: Bool {
        summary.id < AppClock.dayKey(for: AppClock.now)
    }

    private var prayerDetailCard: some View {
        let dayLogs = state.logs.filter { $0.dayKey == summary.id }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Prayers")
                .font(Theme.sans(16, .bold))
                .foregroundStyle(Theme.inkDeep)

            ForEach(Prayer.allCases) { prayer in
                // latestLog, not `first`: a travel day can hold TWO logs for
                // one prayer, and the week grid draws the later one. `first`
                // drew the other, so the same date showed a different tier and
                // time depending on which screen you were looking at — and any
                // future reordering of `logs` would have changed the answer
                // silently.
                prayerRow(prayer: prayer,
                          log: GameEngine.latestLog(prayer: prayer,
                                                    dayKey: summary.id, in: dayLogs),
                          excused: state.isExcused(prayer: prayer, dayKey: summary.id))
            }

            if isEditablePastDay, hasEditableMiss(dayLogs) {
                Text(state.lateEditXP(forDayKey: summary.id) > 0
                     ? "Forgot to log a make-up? Tap it — recent edits still earn +\(state.lateEditXP(forDayKey: summary.id)) XP."
                     : "Forgot to log a make-up? Tap it — edits this far back don't earn XP, but the record counts.")
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func hasEditableMiss(_ dayLogs: [PrayerLog]) -> Bool {
        Prayer.allCases.contains { prayer in
            !dayLogs.contains(where: { $0.prayer == prayer })
                && !state.isExcused(prayer: prayer, dayKey: summary.id)
        }
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
            if log == nil, !excused, isEditablePastDay {
                makeUpButton(prayer)
            } else {
                Text(rowStatus(log: log, excused: excused))
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(rowColor(log: log, excused: excused))
            }
            if let filename = log?.photoFilename {
                PhotoThumb(filename: filename)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func makeUpButton(_ prayer: Prayer) -> some View {
        let xp = state.lateEditXP(forDayKey: summary.id)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.logPastMakeUp(prayer, dayKey: summary.id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(xp > 0 ? "Made it up · +\(xp) XP" : "Made it up")
                    .font(Theme.sans(12, .bold))
            }
            .foregroundStyle(Theme.qadaBlue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.qadaBlue.opacity(0.10)))
        }
        .buttonStyle(.plain)
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

// MARK: - Scoring explainer (v3.6 — moved from Settings, now a centered modal)

/// Plain-English walkthrough of the point system — mirrors SCORING.md.
/// Hosted inside `CenteredModal` from the Journey level card.
struct ScoringExplainerContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How scoring works ⚡")
                .font(Theme.sans(20, .bold))
                .foregroundStyle(Theme.inkDeep)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    section("⏱ Pray early, earn more") {
                        row("First quarter of the window", "+30 XP", Theme.green)
                        row("Second quarter", "+20 XP", Theme.green)
                        row("Third quarter", "+15 XP", Theme.amber)
                        row("Final quarter", "+12 XP", Theme.amber)
                        row("Made up later (Qada)", "+\(LogTier.qada.xp) XP", Theme.qadaBlue)
                    }
                    section("🤝 Praying in a group") {
                        bullet("Prayed in jamaat (or Jumma on Friday)? Your prayer is lifted to 30 XP.")
                        bullet("So a late group prayer is never penalised.")
                    }
                    section("🎁 Bonuses") {
                        row("Perfect day — all 5 in window", "+25 XP", Theme.gold)
                    }
                    section("📿 Dhikr & deeds") {
                        bullet("Tasbih and good deeds earn XP toward your level — always available, on the Dhikr tab.")
                        bullet("On a break you can earn up to 200/day; otherwise dhikr tops you up to 150, so praying early always wins.")
                    }
                    section("🔥 Streaks") {
                        bullet("Log all 5 prayers in a day to extend your streak.")
                        bullet("Every 7-day streak banks a streak freeze (max 2) that covers a missed day.")
                        bullet("Breaks pause everything — your streak is safe until you resume.")
                    }
                    section("🏆 The circle") {
                        bullet("Weekly scores reset every Monday and count prayer XP + bonuses + dhikr.")
                        bullet("The crown goes to the first to the weekly target (prayer XP).")
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 380)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.inkDeep)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Text(value)
                .font(Theme.sans(13, .heavy))
                .foregroundStyle(color)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•")
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lazy thumbnail

/// Loads a photo off the main thread and decodes a small thumbnail so grids
/// never hold full-res UIImages (SPEC-V2 §6.10).
private struct PhotoThumb: View {
    let filename: String
    var pixelSize: CGFloat = 240

    @State private var image: UIImage?
    @State private var loadedFor: String?

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
            guard loadedFor != filename else { return }
            let name = filename
            let target = CGSize(width: pixelSize, height: pixelSize)
            let thumb = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let full = PhotoStore.load(name) else { return nil }
                return full.preparingThumbnail(of: target) ?? full
            }.value
            image = thumb
            loadedFor = name
        }
    }
}
