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

            if isWindowOpen, !excusedForBlockDay,
               let tier = state.potentialTier(for: block.prayer), tier.isInWindow {
                Text("+\(tier.xp) XP if you pray now")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.gold)
            }

            if excusedForBlockDay, !iLogged(entries) {
                excusedBanner
            }

            LiveCircleGrid(entries: entries,
                           showCTA: isWindowOpen && !excusedForBlockDay,
                           onPost: onPost,
                           onUndoMine: { withAnimation(Theme.spring) { state.undoLog(block.prayer) } })

            if iPostedInWindow(entries) {
                Text("Hold your photo to undo")
                    .font(Theme.sans(11, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .cardStyle()
        .animation(Theme.spring, value: block)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(block.prayer.emoji) \(block.prayer.displayName)")
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

    /// v3.2: during a break this becomes the engagement card — dhikr for
    /// private XP and a one-tap resume. Otherwise the quiet excused note.
    @ViewBuilder
    private var excusedBanner: some View {
        if state.isOnBreak {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("On a break — your streak is safe 💜")
                        .font(Theme.sans(14, .bold))
                }
                .foregroundStyle(Theme.lilac)

                Text("Stay connected with a little dhikr — those points are just for you, never shown to your circle.")
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

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(displayEntries) { entry in
                cell(entry)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
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
                        Text(window.prayer.displayName)
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
}

// MARK: - Excused-day footer

/// Quiet "Can't pray today?" flow: confirm dialog → setTodayExcused(true).
/// Shows the lilac excused banner with undo when active, and the cap state
/// ("n/10 used") when the monthly allowance is spent.
struct ExcusedTodayFooter: View {
    @EnvironmentObject private var state: AppState

    @State private var confirming = false

    var body: some View {
        Group {
            if state.isOnBreak {
                breakBanner
            } else {
                Button {
                    confirming = true
                } label: {
                    Text("Can't pray right now?")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .underline()
                }
                .buttonStyle(.plain)
                .confirmationDialog("Take a break?",
                                    isPresented: $confirming, titleVisibility: .visible) {
                    Button("Start a break 🌙") {
                        withAnimation(Theme.spring) { state.startBreak() }
                    }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("Sickness, travel, your period — whatever the reason, your streak is safe until you tap Resume. Your circle sees a gentle \"excused\", never the details. Dhikr earns you private XP meanwhile.")
                }
            }
        }
        .padding(.top, 6)
    }

    private var breakBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.lilac)
            VStack(alignment: .leading, spacing: 2) {
                Text("On a break — streak safe")
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Resume whenever you're ready 💜")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
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
