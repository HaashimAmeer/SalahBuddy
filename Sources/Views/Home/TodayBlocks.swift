import SwiftUI

// MARK: - Current prayer block (the centerpiece)

/// Prayer name + emoji, live window countdown, tier hint, and the circle's
/// photo grid for THIS prayer filling in live. Your square is the camera CTA
/// until you post. Pre-fajr this renders yesterday's isha (yesterday's dayKey).
struct CurrentPrayerBlock: View {
    let block: TodayBlock
    let onPost: () -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        let entries = state.gridEntries(for: block.prayer, dayKey: block.dayKey)

        VStack(alignment: .leading, spacing: 14) {
            header

            if block.combinedWith != nil, !excusedForBlockDay {
                Text("🧳 Traveling — pray them together and log once.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.qadaBlue)
            }

            if isWindowOpen, !excusedForBlockDay, let tier = activeTier, tier.isInWindow {
                Text(block.combinedWith != nil
                     ? "+\(tier.xp) XP each if you log now"
                     : "+\(tier.xp) XP if you pray now")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.gold)
            }

            if excusedForBlockDay, !iLogged(entries) {
                excusedBanner
            }

            LiveCircleGrid(entries: entries,
                           showCTA: isWindowOpen && !excusedForBlockDay,
                           onPost: onPost,
                           onUndoMine: { undoMine() })

            if iPostedInWindow(entries) {
                Text(block.combinedWith != nil
                     ? "Both logged · hold your photo to undo"
                     : "Hold your photo to undo")
                    .font(Theme.sans(11, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .cardStyle()
        .animation(Theme.spring, value: block)
    }

    /// Tier the log would earn now — against the combined window when traveling.
    private var activeTier: LogTier? {
        if block.combinedWith != nil, let win = state.combinedWindow(lead: block.prayer) {
            return GameEngine.tier(for: win, at: now)
        }
        return state.potentialTier(for: block.prayer)
    }

    private func undoMine() {
        withAnimation(Theme.spring) {
            state.undoLog(block.prayer)
            if let partner = block.combinedWith { state.undoLog(partner) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleText)
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)

            if block.isYesterdayIsha {
                Text("last night")
                    .font(Theme.sans(11, .bold))
                    .foregroundStyle(Theme.lilac)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.lilac.opacity(0.15)))
            }

            Spacer(minLength: 8)

            if isWindowOpen {
                Text("\(HomeTimeFormat.countdown(to: block.windowEnd, from: now)) left")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.amber)
            } else {
                Text("Window ended")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var titleText: String {
        if let partner = block.combinedWith {
            return "\(block.prayer.emoji) \(block.prayer.displayName) + \(partner.displayName)"
        }
        return "\(block.prayer.emoji) \(block.prayer.displayName)"
    }

    /// v3.2: during a break this becomes the engagement card — dhikr for
    /// private XP and a one-tap resume. Otherwise the quiet excused note.
    @ViewBuilder
    private var excusedBanner: some View {
        if state.isOnBreak {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: state.breakReason == "period" ? "drop.fill" : "moon.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.breakCopy.headline + " — streak safe")
                        .font(Theme.sans(14, .bold))
                }
                .foregroundStyle(Theme.lilac)

                Text(state.breakReason == "period"
                     ? "These prayers are waived — nothing to make up. Stay connected with a little dhikr; those points are just for you."
                     : "Stay connected with a little dhikr — those points are just for you, never shown to your circle.")
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(Theme.spring) { state.logDhikr() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("📿 Log dhikr")
                                .font(Theme.sans(14, .bold))
                            Text("+\(GameEngine.dhikrXP) XP · \(state.dhikrToday)/\(GameEngine.maxDhikrPerDay)")
                                .font(Theme.sans(12, .semibold))
                                .opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(
                            state.dhikrToday < GameEngine.maxDhikrPerDay ? Theme.lilac : Theme.mist))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.dhikrToday >= GameEngine.maxDhikrPerDay)

                    Button {
                        withAnimation(Theme.spring) { state.resumePrayers() }
                    } label: {
                        Text("Resume prayers")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().strokeBorder(Theme.green, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.lilac.opacity(0.12))
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Resting today — your streak is safe 💜")
                    .font(Theme.sans(13, .semibold))
            }
            .foregroundStyle(Theme.lilac)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.lilac.opacity(0.12))
            )
        }
    }

    /// Window still open by the clock (independent of whether I logged).
    private var isWindowOpen: Bool {
        if case .open = state.status(of: block.prayer) { return true }
        return false
    }

    private var excusedForBlockDay: Bool {
        block.isYesterdayIsha
            ? state.profile.excusedDayKeys.contains(block.dayKey)
            : state.isTodayExcused
    }

    private func iLogged(_ entries: [GridEntry]) -> Bool {
        entries.contains {
            guard $0.member.isYou else { return false }
            switch $0.state {
            case .posted, .qada: return true
            default: return false
            }
        }
    }

    private func iPostedInWindow(_ entries: [GridEntry]) -> Bool {
        entries.contains {
            guard $0.member.isYou else { return false }
            if case .posted = $0.state { return true }
            return false
        }
    }
}

// MARK: - Live circle grid (home-owned wrapper)

/// 2-column grid of the circle's squares. Buddy squares (and your posted
/// square) render via `PhotoSquare`; while you haven't posted and the window
/// is open, your square is the camera CTA. Long-press your posted square to
/// undo.
struct LiveCircleGrid: View {
    let entries: [GridEntry]
    let showCTA: Bool
    let onPost: () -> Void
    let onUndoMine: () -> Void

    @State private var page = 0
    @State private var width: CGFloat = 0

    private let perPage = 4
    private let spacing: CGFloat = 12

    var body: some View {
        Group {
            if displayEntries.count <= perPage {
                gridPage(displayEntries)
            } else {
                // v3.3: page the circle 4 at a time (2×2) so the Today screen
                // stays short no matter how many friends — swipe for the next 4.
                VStack(spacing: 10) {
                    TabView(selection: $page) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, pageEntries in
                            gridPage(pageEntries)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: square * 2 + spacing)
                    indicator
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GridWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(GridWidthKey.self) { w in
            if w > 0, abs(w - width) > 0.5 { width = w }
        }
        .onChange(of: pages.count) { _, count in
            if page >= count { page = max(0, count - 1) }
        }
    }

    /// `displayEntries` split into pages of `perPage`.
    private var pages: [[GridEntry]] {
        let all = displayEntries
        return stride(from: 0, to: all.count, by: perPage).map {
            Array(all[$0 ..< min($0 + perPage, all.count)])
        }
    }

    /// Square edge from the measured content width (two columns + spacing).
    private var square: CGFloat {
        let w = width > 0 ? width : UIScreen.main.bounds.width - 64
        return max(60, (w - spacing) / 2)
    }

    /// One page: up to four squares in a fixed 2-column grid, left-anchored so
    /// a partial last page keeps the top-left "you" position.
    private func gridPage(_ pageEntries: [GridEntry]) -> some View {
        let cols = [GridItem(.fixed(square), spacing: spacing),
                    GridItem(.fixed(square), spacing: spacing)]
        return LazyVGrid(columns: cols, spacing: spacing) {
            ForEach(pageEntries) { entry in
                cell(entry).frame(width: square, height: square)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Page dots + friend count, so it's clear how many more there are.
    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.green : Theme.mist.opacity(0.55))
                    .frame(width: i == page ? 16 : 6, height: 6)
                    .animation(Theme.spring, value: page)
            }
            Spacer(minLength: 8)
            Text("\(friendCount) friends · swipe")
                .font(Theme.sans(11, .semibold))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    private var friendCount: Int {
        displayEntries.filter { !$0.member.isYou }.count
    }

    /// v3.2 ordering per design session: YOUR square top-left, then the rest
    /// by most recent post first. On a break your square is removed entirely
    /// ("just remove their photo") — the break card explains your absence.
    private var displayEntries: [GridEntry] {
        let visible = entries.filter { !($0.member.isYou && $0.state == .excused) }
        let you = visible.filter(\.member.isYou)
        let others = visible.filter { !$0.member.isYou }
            .sorted { recency($0) > recency($1) }
        return you + others
    }

    private func recency(_ entry: GridEntry) -> Date {
        switch entry.state {
        case .posted(_, _, let at): return at
        case .qada(let at): return at
        default: return .distantPast
        }
    }

    @ViewBuilder
    private func cell(_ entry: GridEntry) -> some View {
        if entry.member.isYou, entry.state == .waiting, showCTA {
            ctaSquare
        } else if entry.member.isYou, isPosted(entry) {
            sizedSquare(entry)
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    onUndoMine()
                }
        } else {
            sizedSquare(entry)
        }
    }

    private func sizedSquare(_ entry: GridEntry) -> some View {
        GeometryReader { geo in
            PhotoSquare(entry: entry, size: geo.size.width)
        }
    }

    /// Your square as the camera CTA — dashed soft-green tile.
    private var ctaSquare: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onPost()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.green)
                Text("Tap to post 📸")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkDeep)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.greenSoft.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.green.opacity(0.7),
                                  style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func isPosted(_ entry: GridEntry) -> Bool {
        if case .posted = entry.state { return true }
        return false
    }
}

/// Measures the circle grid's available width so the paged carousel can size
/// its square cells (and fixed page height) precisely.
private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Make-up (qada) section

/// Today's passed-unlogged prayers as small tap-only rows, with gentle
/// "you missed out" copy — no shaming, no red.
struct MakeUpSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let prayers = state.makeUpPrayers
        if !prayers.isEmpty, !state.isTodayExcused {
            VStack(alignment: .leading, spacing: 10) {
                Text("Make up")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)

                if state.missedOutXPToday > 0 {
                    Text("You missed out on +\(state.missedOutXPToday) XP today — a make-up still counts 💙")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(prayers) { prayer in
                    row(for: prayer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardStyle()
        }
    }

    private func row(for prayer: Prayer) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.logQada(prayer) }
        } label: {
            HStack(spacing: 10) {
                Text(prayer.emoji)
                Text("Make up \(prayer.displayName)")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer(minLength: 8)
                Text("+\(LogTier.qada.xp) XP")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.qadaBlue)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.qadaBlue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.qadaBlue.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Earlier today

/// Previous prayer blocks, collapsed; tap to expand a compact photo grid.
struct EarlierTodaySection: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var expanded: Set<Prayer> = []

    var body: some View {
        let earlier = state.earlierTodayPrayers(now: now)
        if !earlier.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Earlier today")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)

                ForEach(earlier) { prayer in
                    EarlierTodayBlock(prayer: prayer,
                                      isExpanded: expanded.contains(prayer)) {
                        withAnimation(Theme.spring) {
                            if expanded.contains(prayer) { expanded.remove(prayer) }
                            else { expanded.insert(prayer) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One collapsed earlier-prayer row; expanding reveals its compact grid.
struct EarlierTodayBlock: View {
    let prayer: Prayer
    let isExpanded: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Text(prayer.emoji)
                    Text(prayer.displayName)
                        .font(Theme.sans(16, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer(minLength: 8)
                    summary
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // v3.2: status only, no photos — past photos live in YOUR
                // Journey memories; here it's just who prayed and who didn't.
                statusRows(state.gridEntries(for: prayer, dayKey: state.todayKey))
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func statusRows(_ entries: [GridEntry]) -> some View {
        VStack(spacing: 6) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.member.emoji)
                        .font(.system(size: 14))
                    Text(entry.member.isYou ? "You" : entry.member.name)
                        .font(Theme.sans(13, entry.member.isYou ? .bold : .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer(minLength: 8)
                    statusChip(entry.state)
                }
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ entryState: GridEntryState) -> some View {
        switch entryState {
        case .posted(_, let tier, let at):
            HStack(spacing: 4) {
                Circle().fill(Theme.color(for: .inWindow(tier)))
                    .frame(width: 8, height: 8)
                Text("Prayed · \(at.formatted(date: .omitted, time: .shortened))")
            }
            .font(Theme.sans(12, .semibold))
            .foregroundStyle(Theme.inkMuted)
        case .qada:
            Text("Made up")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(Theme.qadaBlue)
        case .missed:
            Text("Not yet")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted.opacity(0.7))
        case .excused:
            HStack(spacing: 3) {
                Image(systemName: "moon.fill").font(.system(size: 9, weight: .bold))
                Text("Excused")
            }
            .font(Theme.sans(12, .bold))
            .foregroundStyle(Theme.lilac)
        case .waiting:
            Text("…")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted.opacity(0.5))
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch state.status(of: prayer) {
        case .logged(let tier):
            Text(tier.isInWindow ? tier.label : "Made up")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(tier.isInWindow ? Theme.green : Theme.qadaBlue)
        case .missedWindow:
            Text(state.isTodayExcused ? "Excused" : "Missed")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(state.isTodayExcused ? Theme.lilac : Theme.inkMuted)
        default:
            EmptyView()
        }
    }
}

// MARK: - Upcoming

/// The rest of today's prayers, dimmed, with opens-in countdowns.
struct UpcomingSection: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        let upcoming = state.upcomingTodayWindows(now: now)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Coming up")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)

                ForEach(upcoming, id: \.prayer) { window in
                    HStack(spacing: 10) {
                        Text(window.prayer.emoji)
                        Text(upcomingLabel(window.prayer))
                            .font(Theme.sans(15, .semibold))
                            .foregroundStyle(Theme.inkDeep)
                        Spacer(minLength: 8)
                        Text("in \(HomeTimeFormat.countdown(to: window.start, from: now))")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.surface.opacity(0.7))
                    )
                    .opacity(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Dhuhr + Asr" when traveling and the pair is still ahead.
    private func upcomingLabel(_ prayer: Prayer) -> String {
        if let partner = state.upcomingCombinedPartner(for: prayer, now: now) {
            return "\(prayer.displayName) + \(partner.displayName)"
        }
        return prayer.displayName
    }
}

// MARK: - Travel mode (v3.3)

/// Quiet manual "I'm traveling" toggle — combines Dhuhr+Asr and Maghrib+Isha.
struct TravelToggleRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.setTraveling(!state.isTraveling) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: state.isTraveling ? "airplane.circle.fill" : "airplane")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state.isTraveling ? Theme.qadaBlue : Theme.inkMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isTraveling ? "Traveling — prayers combined" : "Traveling?")
                        .font(Theme.sans(14, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text(state.isTraveling
                         ? "Dhuhr+Asr and Maghrib+Isha log together. Tap to turn off."
                         : "Combine Dhuhr+Asr and Maghrib+Isha (jam').")
                        .font(Theme.sans(11.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: state.isTraveling ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(state.isTraveling ? Theme.qadaBlue : Theme.mist)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(state.isTraveling ? Theme.qadaBlue.opacity(0.10) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(state.isTraveling ? Theme.qadaBlue.opacity(0.5) : Theme.mist.opacity(0.4),
                                  lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Auto-suggestion banner: shows when you're far from your saved Home.
struct TravelSuggestionBanner: View {
    @EnvironmentObject private var state: AppState
    @Binding var dismissed: Bool

    var body: some View {
        if !dismissed, !state.isTraveling, state.shouldSuggestTravel() {
            HStack(spacing: 10) {
                Image(systemName: "airplane")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.qadaBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Looks like you're away from home")
                        .font(Theme.sans(13, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text("Combine prayers while you travel?")
                        .font(Theme.sans(11.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 8)
                Button("Not now") { withAnimation(Theme.spring) { dismissed = true } }
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
                Button("Enable") {
                    withAnimation(Theme.spring) { state.setTraveling(true) }
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.qadaBlue))
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Theme.qadaBlue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Excused-day footer

/// Quiet "Can't pray today?" flow: confirm dialog → setTodayExcused(true).
/// Shows the lilac excused banner with undo when active, and the cap state
/// ("n/10 used") when the monthly allowance is spent.
struct ExcusedTodayFooter: View {
    @EnvironmentObject private var state: AppState

    // v3.4: the entry routes differently by gender (memberKind).
    @State private var sisterConfirm = false
    @State private var brotherConfirm = false
    @State private var genericConfirm = false

    var body: some View {
        Group {
            if state.isOnBreak {
                breakBanner
            } else {
                entryButton
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var entryButton: some View {
        Button {
            if state.isSister { sisterConfirm = true }
            else if state.isBrother { brotherConfirm = true }
            else { genericConfirm = true }
        } label: {
            Text("Can't pray right now?")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .underline()
        }
        .buttonStyle(.plain)
        // Sisters: period leads, framed as completely normal.
        .confirmationDialog("Need a break?", isPresented: $sisterConfirm, titleVisibility: .visible) {
            Button("On my period 🌸") { withAnimation(Theme.spring) { state.startBreak(reason: "period") } }
            Button("Another reason") { withAnimation(Theme.spring) { state.startBreak(reason: "other") } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Your prayers are waived while you rest — nothing to make up, and your streak stays safe. Your circle only sees a gentle \"resting\". Dhikr earns private XP meanwhile.")
        }
        // Brothers: travel routes to combining (you can still pray); only
        // genuine inability starts a break.
        .confirmationDialog("Can't pray right now?", isPresented: $brotherConfirm, titleVisibility: .visible) {
            Button("I'm traveling ✈️") { withAnimation(Theme.spring) { state.setTraveling(true) } }
            Button("I'm unwell 🤒") { withAnimation(Theme.spring) { state.startBreak(reason: "illness") } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Traveling? You can still pray — turn on combining to log Dhuhr+Asr and Maghrib+Isha together. A break is for when you genuinely can't; your streak stays safe either way.")
        }
        // Unknown gender: the unified break.
        .confirmationDialog("Take a break?", isPresented: $genericConfirm, titleVisibility: .visible) {
            Button("Start a break 🌙") { withAnimation(Theme.spring) { state.startBreak(reason: "other") } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Sickness, travel, your period — whatever the reason, your streak is safe until you tap Resume. Your circle sees a gentle \"excused\", never the details.")
        }
    }

    private var breakBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: state.breakReason == "period" ? "drop.fill" : "moon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.lilac)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.breakCopy.headline)
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text(state.breakCopy.subtext)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Resume") {
                withAnimation(Theme.spring) { state.resumePrayers() }
            }
            .font(Theme.sans(13, .bold))
            .foregroundStyle(Theme.green)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.lilac.opacity(0.12))
        )
    }
}
