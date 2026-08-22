import SwiftUI

// MARK: - Current prayer block (the centerpiece)

/// Prayer name + emoji, live window countdown, tier hint, and the circle's
/// photo grid for THIS prayer filling in live. Your square is the camera CTA
/// until you post. Pre-fajr this renders yesterday's isha (yesterday's dayKey).
struct CurrentPrayerBlock: View {
    let block: TodayBlock
    let onPost: () -> Void
    /// v3.8: tapping a square enlarges it — handled by HomeView as a centered
    /// modal (so it pops in place, not a sheet you have to scroll).
    var onEnlarge: (GridEntry) -> Void = { _ in }

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var showRecharge = false
    @State private var showResume = false

    /// Nothing has ever been logged on this device — so this really is the
    /// first prayer, not merely the first of today.
    private var isFirstEver: Bool { state.logs.isEmpty }

    var body: some View {
        let entries = state.gridEntries(for: block.prayer, dayKey: block.dayKey)

        VStack(alignment: .leading, spacing: 14) {
            header

            if block.combinedWith != nil, !excusedForBlockDay {
                Text("🧳 Traveling — pray them together and log once.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.qadaBlue)
            }

            // First ever visit: the camera CTA is the biggest thing on screen
            // and nothing has said why a prayer app wants a photo, or who ends
            // up seeing it. That is the question people actually have, so
            // answer it once, here, and never again.
            if isFirstEver, isWindowOpen, !excusedForBlockDay {
                Text("Your first one 🌙 The photo is just your marker — it stays on this phone unless you start a circle.")
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
                           isSolo: state.isSoloMode,
                           onPost: onPost,
                           onUndoMine: { undoMine() },
                           onTapEntry: { onEnlarge($0) })

            if iPostedInWindow(entries) {
                Text(block.combinedWith != nil
                     ? "Both logged · hold your photo to undo"
                     : "Hold your photo to undo")
                    .font(Theme.sans(11, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            nudgeRow(entries)
        }
        .padding(16)
        .cardStyle()
        .animation(Theme.spring, value: block)
        .sheet(isPresented: $showRecharge) {
            RecoverySheet().environmentObject(state)
        }
        .sheet(isPresented: $showResume) {
            ResumeSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
        }
    }

    /// v3.6 (design session): once a prayer has been in for 30 minutes,
    /// friends who still haven't posted can be nudged.
    @ViewBuilder
    private func nudgeRow(_ entries: [GridEntry]) -> some View {
        let waiting = entries.filter { !$0.member.isYou && $0.state == .waiting }
        if isWindowOpen, !excusedForBlockDay, nudgeEligible, !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nudge your friends 👋")
                    .font(Theme.sans(11, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(waiting) { entry in
                            NudgeChip(member: entry.member, prayer: block.prayer,
                                      dayKey: block.dayKey)
                        }
                    }
                }
            }
        }
    }

    /// 30+ minutes into the window (not computable for the pre-fajr
    /// yesterday-isha block — no nudges there).
    private var nudgeEligible: Bool {
        guard !block.isYesterdayIsha,
              let start = state.todaySchedule?.window(for: block.prayer)?.start else { return false }
        return now >= start.addingTimeInterval(30 * 60)
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

                // v3.9: no circle yet → drop the "never shown to your circle"
                // reassurance; there's nobody to be shown to.
                Text(state.breakReason == "period"
                     ? "These prayers are waived — nothing to make up. Stay connected with a little dhikr; those points are just for you."
                     : state.isSoloMode
                       ? "Stay connected with a little dhikr — those points are just for you."
                       : "Stay connected with a little dhikr — those points are just for you, never shown to your circle.")
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("🌟 \(state.dhikrToday) dhikr today · +\(state.recoveryXPToday) XP")
                    .font(Theme.sans(11, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.85))

                // Equal-width, single-line, same-height buttons so they line up.
                HStack(spacing: 10) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showRecharge = true
                    } label: {
                        Text("📿 Dhikr & deeds")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(Theme.lilac))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showResume = true
                    } label: {
                        Text("Resume prayers")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(Theme.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
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

    /// v3.6: per-prayer — a break that started at Asr leaves the maghrib CTA
    /// alone after a mid-day resume, and never repaints the morning.
    private var excusedForBlockDay: Bool {
        state.isExcused(prayer: block.prayer, dayKey: block.dayKey)
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
    /// v3.9: no circle yet — there's only your square, so it takes the whole
    /// width instead of sitting in a half-width cell with dead space beside it.
    var isSolo: Bool = false
    let onPost: () -> Void
    let onUndoMine: () -> Void
    let onTapEntry: (GridEntry) -> Void

    @State private var page = 0
    @State private var width: CGFloat = 0

    private let perPage = 4
    private let line: CGFloat = 2   // v3.8: hairline divider between flush cells

    var body: some View {
        Group {
            if isSolo {
                soloTile
            } else if displayEntries.count <= perPage {
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
                    .frame(height: square * 2 + line)
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

    /// Square edge from the measured content width (two flush columns + one
    /// hairline divider).
    private var square: CGFloat {
        max(60, (contentWidth - line) / 2)
    }

    /// Measured width, with a sensible pre-measurement fallback (screen minus
    /// the Today padding + card padding).
    private var contentWidth: CGFloat {
        width > 0 ? width : UIScreen.main.bounds.width - 64
    }

    /// v3.9 (solo): your one tile, full width. Same flush treatment as the
    /// grid — the cell itself is un-rounded and the outer shape does the
    /// rounding — just a single hero square instead of a 2×2. On a break your
    /// (excused) square is filtered out entirely, so this renders nothing and
    /// the break card carries the block.
    @ViewBuilder
    private var soloTile: some View {
        if let mine = displayEntries.first {
            cell(mine)
                .frame(width: contentWidth, height: contentWidth)
                .background(Theme.mist.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// v3.8 (design session): one page is a flush 2×2 — square cells, hairline
    /// dividers, rounded corners ONLY on the outer card. Partial last page
    /// keeps the rows it has (top-left "you" first).
    private func gridPage(_ pageEntries: [GridEntry]) -> some View {
        let rows = stride(from: 0, to: pageEntries.count, by: 2).map {
            Array(pageEntries[$0 ..< min($0 + 2, pageEntries.count)])
        }
        return VStack(spacing: line) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowEntries in
                HStack(spacing: line) {
                    ForEach(rowEntries) { entry in
                        cell(entry).frame(width: square, height: square)
                    }
                }
            }
        }
        .background(Theme.mist.opacity(0.55))   // shows through the gaps as dividers
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            // Tap to enlarge; long-press to undo your own post.
            sizedSquare(entry)
                .onTapGesture { onTapEntry(entry) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    onUndoMine()
                }
        } else if isPosted(entry) {
            sizedSquare(entry)
                .onTapGesture { onTapEntry(entry) }
        } else {
            sizedSquare(entry)
        }
    }

    private func sizedSquare(_ entry: GridEntry) -> some View {
        GeometryReader { geo in
            // v3.9: solo the tile is full-width (~2× a grid cell). Scale the
            // overlays like ctaSquare does (~1.4×), not linearly with the tile.
            PhotoSquare(entry: entry, size: geo.size.width, flush: true,
                        typeSize: isSolo ? geo.size.width * 0.7 : nil)
        }
        .contentShape(Rectangle())
    }

    /// Your square as the camera CTA — flush soft-green tile with a dashed
    /// inset so it still reads as "tap me" inside the edge-to-edge grid.
    /// v3.9: solo it's a full-width hero, so the icon and label scale with it.
    private var ctaSquare: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onPost()
        } label: {
            VStack(spacing: isSolo ? 12 : 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: isSolo ? 40 : 26, weight: .semibold))
                    .foregroundStyle(Theme.green)
                Text("Tap to post 📸")
                    .font(Theme.sans(isSolo ? 17 : 13, .bold))
                    .foregroundStyle(Theme.inkDeep)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.greenSoft.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: isSolo ? 18 : 12, style: .continuous)
                    .strokeBorder(Theme.green.opacity(0.7),
                                  style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(isSolo ? 12 : 8)
            )
            .contentShape(Rectangle())
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

// MARK: - Tap-to-enlarge detail (v3.8 — design session)

/// What HomeView needs to show the centered enlarge modal.
struct EnlargedPost: Identifiable, Equatable {
    let entry: GridEntry
    let prayer: Prayer
    var id: String { entry.id }
    static func == (l: EnlargedPost, r: EnlargedPost) -> Bool { l.id == r.id }
}

/// Tapping a square pops this open IN PLACE (inside `CenteredModal`, which
/// supplies the dim + close X) — the photo larger, with the details taken off
/// the small tile (location, full time, tier). No scrolling.
struct PrayerPhotoDetailContent: View {
    let entry: GridEntry
    let prayer: Prayer
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 14) {
            Text("\(prayer.emoji) \(entry.member.isYou ? "You" : entry.member.name)")
                .font(Theme.sans(20, .bold))
                .foregroundStyle(Theme.inkDeep)
            photo
            detailRow
        }
    }

    @ViewBuilder
    private var photo: some View {
        Group {
            switch entry.state {
            case .posted(.photo(let filename), _, _):
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Theme.greenSoft.opacity(0.5)
                    }
                }
                .task(id: filename) {
                    let name = filename
                    image = await Task.detached(priority: .userInitiated) {
                        PhotoStore.load(name)
                    }.value
                }
            case .posted(.illustration(let seed), _, _):
                IllustratedPrayerCard(seed: seed)
            default:
                Theme.greenSoft.opacity(0.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var detailRow: some View {
        HStack(spacing: 8) {
            if case .posted(_, let tier, let at) = entry.state {
                chip(tier.label, Theme.color(for: .inWindow(tier)))
                chip(at.formatted(date: .omitted, time: .shortened), Theme.inkMuted)
            }
            if let place = entry.placeLabel {
                chip(place, Theme.qadaBlue)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.sans(12.5, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }
}

// MARK: - Make-up (qada) section

/// Today's passed-unlogged prayers as small tap-only rows, with gentle
/// "you missed out" copy — no shaming, no red.
struct MakeUpSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // v3.6: per-prayer excuse — a miss from BEFORE a mid-day break started
        // is still make-up-able.
        let prayers = state.makeUpPrayers.filter {
            !state.isExcused(prayer: $0, dayKey: state.todayKey)
        }
        if !prayers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.makeUpIsBeforeJoiningOnly ? "Already prayed today?" : "Make up")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)

                // Day one asks a question; every other day states a fact. The
                // rows underneath are identical either way.
                if state.makeUpIsBeforeJoiningOnly {
                    Text("Add the ones you've already prayed today — they still count 💙")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.missedOutXPToday > 0 {
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
                // v3.6 (design session): a sequential TIMELINE of who prayed
                // when — earliest first, made-ups at the end, everyone who
                // hasn't logged bunched at the bottom. No photos here; past
                // photos live in YOUR Journey memories.
                PrayerTimeline(prayer: prayer, dayKey: state.todayKey,
                               entries: state.gridEntries(for: prayer, dayKey: state.todayKey))
            }
        }
        .padding(14)
        .cardStyle()
    }

    @ViewBuilder
    private var summary: some View {
        switch state.status(of: prayer) {
        case .logged(let tier):
            Text(tier.isInWindow ? tier.label : "Made up")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(tier.isInWindow ? Theme.green : Theme.qadaBlue)
        case .missedWindow:
            let excused = state.isExcused(prayer: prayer, dayKey: state.todayKey)
            Text(excused ? "Excused" : "Missed")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(excused ? Theme.lilac : Theme.inkMuted)
        case .beforeJoining:
            Text("Before you started")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted)
        default:
            EmptyView()
        }
    }
}

// MARK: - Prayer timeline (v3.6 — design session)

/// Sequential visualization of one prayer across the circle: in-window posts
/// ordered by time down a vertical timeline, made-ups appended at the end
/// (when they made up doesn't matter), excused folks resting quietly, and
/// everyone who hasn't logged bunched into one muted row (with a nudge).
struct PrayerTimeline: View {
    let prayer: Prayer
    let dayKey: String
    let entries: [GridEntry]

    @EnvironmentObject private var state: AppState

    private var posted: [GridEntry] {
        entries
            .filter { if case .posted = $0.state { return true }; return false }
            .sorted { postTime($0) < postTime($1) }
    }
    private var madeUp: [GridEntry] {
        entries.filter { if case .qada = $0.state { return true }; return false }
    }
    private var excused: [GridEntry] { entries.filter { $0.state == .excused } }
    private var notLogged: [GridEntry] {
        entries.filter { $0.state == .missed || $0.state == .waiting }
    }

    private func postTime(_ entry: GridEntry) -> Date {
        if case .posted(_, _, let at) = entry.state { return at }
        return .distantPast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(posted.enumerated()), id: \.element.id) { index, entry in
                timelineRow(entry, isLast: index == posted.count - 1
                            && madeUp.isEmpty && excused.isEmpty && notLogged.isEmpty)
            }
            ForEach(madeUp) { entry in
                plainRow(emoji: entry.member.emoji,
                         name: displayName(entry.member),
                         label: "Made up", color: Theme.qadaBlue,
                         dotColor: Theme.qadaBlue)
            }
            ForEach(excused) { entry in
                plainRow(emoji: entry.member.emoji,
                         name: displayName(entry.member),
                         label: "Resting 🌙", color: Theme.lilac,
                         dotColor: Theme.lilac)
            }
            notLoggedRow
            yourNotLoggedRow
            if posted.isEmpty && madeUp.isEmpty && excused.isEmpty && notLogged.isEmpty {
                Text(state.isSoloMode
                     ? "You haven't logged this one yet."
                     : "No one's logged this one yet.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
            }
        }
    }

    private func displayName(_ member: CircleMember) -> String {
        member.isYou ? "You" : member.name
    }

    /// One in-window post on the timeline: time column, colored dot on a
    /// connecting line, then who + how early.
    private func timelineRow(_ entry: GridEntry, isLast: Bool) -> some View {
        guard case .posted(_, let tier, let at) = entry.state else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(alignment: .top, spacing: 10) {
                Text(at.formatted(date: .omitted, time: .shortened))
                    .font(Theme.sans(11, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 56, alignment: .trailing)
                    .padding(.top, 2)

                VStack(spacing: 0) {
                    Circle()
                        .fill(Theme.color(for: .inWindow(tier)))
                        .frame(width: 10, height: 10)
                    if !isLast {
                        Rectangle()
                            .fill(Theme.mist.opacity(0.5))
                            .frame(width: 2)
                            .frame(minHeight: 14)
                    }
                }

                HStack(spacing: 6) {
                    Text(entry.member.emoji).font(.system(size: 14))
                    Text(displayName(entry.member))
                        .font(Theme.sans(13, entry.member.isYou ? .bold : .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer(minLength: 8)
                    Text(tier.label)
                        .font(Theme.sans(11.5, .bold))
                        .foregroundStyle(Theme.color(for: .inWindow(tier)))
                }
                .padding(.bottom, isLast ? 0 : 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// Off-timeline rows (made up / resting) — no time column; "the end is
    /// where they go" per the design session.
    private func plainRow(emoji: String, name: String, label: String,
                          color: Color, dotColor: Color) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 56, height: 1)
            Circle().fill(dotColor.opacity(0.7)).frame(width: 8, height: 8)
            Text(emoji).font(.system(size: 14))
            Text(name)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkDeep)
            Spacer(minLength: 8)
            Text(label)
                .font(Theme.sans(11.5, .bold))
                .foregroundStyle(color)
        }
        .padding(.top, 8)
    }

    /// Everyone who hasn't logged, bunched together so the timeline scales —
    /// "it would just say, like, seven people not logged".
    @ViewBuilder
    private var notLoggedRow: some View {
        let friends = notLogged.filter { !$0.member.isYou }
        if !friends.isEmpty {
            HStack(spacing: 8) {
                Color.clear.frame(width: 56, height: 1)
                HStack(spacing: -6) {
                    ForEach(friends.prefix(4)) { entry in
                        Text(entry.member.emoji)
                            .font(.system(size: 13))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.bg))
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                            .grayscale(0.9)
                            .opacity(0.75)
                    }
                }
                Text(friends.count == 1
                     ? "\(friends.first!.member.name) hasn't logged yet"
                     : "\(friends.count) haven't logged yet")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.85))
                Spacer(minLength: 8)
                if friends.count == 1, let only = friends.first {
                    NudgeChip(member: only.member, prayer: prayer, dayKey: dayKey)
                } else {
                    nudgeAllButton(friends.map(\.member))
                }
            }
            .padding(.top, 10)
        }
    }

    /// v3.9: `notLoggedRow` is friends-only (you can't nudge yourself), so with
    /// no circle an unlogged prayer expanded to an empty body. Solo, your own
    /// row stands in — with a one-tap make-up when the window has passed.
    @ViewBuilder
    private var yourNotLoggedRow: some View {
        if state.isSoloMode, let mine = notLogged.first(where: { $0.member.isYou }) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 56, height: 1)
                Circle().fill(Theme.mist.opacity(0.7)).frame(width: 8, height: 8)
                Text(mine.member.emoji)
                    .font(.system(size: 14))
                    .grayscale(0.9)
                    .opacity(0.75)
                Text("You")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer(minLength: 8)
                if canMakeUp(mine) {
                    makeUpButton
                } else {
                    Text("Not logged")
                        .font(Theme.sans(11.5, .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.top, 10)
        }
    }

    /// Only for today's already-passed windows — the same candidates the
    /// "Make up" section offers, so the two can't disagree.
    private func canMakeUp(_ mine: GridEntry) -> Bool {
        mine.state == .missed && dayKey == state.todayKey
            && state.makeUpPrayers.contains(prayer)
            && !state.isExcused(prayer: prayer, dayKey: dayKey)
    }

    private var makeUpButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.logQada(prayer) }
        } label: {
            Text("Make up +\(LogTier.qada.xp) XP")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(Theme.qadaBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.qadaBlue.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func nudgeAllButton(_ members: [CircleMember]) -> some View {
        let allSent = members.allSatisfy {
            state.nudgesSent.contains(state.nudgeKey(member: $0, prayer: prayer, dayKey: dayKey))
        }
        return Button {
            guard !allSent else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Theme.spring) {
                for member in members {
                    state.sendNudge(to: member, prayer: prayer, dayKey: dayKey)
                }
            }
        } label: {
            Text(allSent ? "Nudged ✓" : "Nudge all 👋")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(allSent ? Theme.inkMuted : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(allSent ? Theme.mist.opacity(0.4) : Theme.green))
        }
        .buttonStyle(.plain)
    }
}

/// One friend's nudge chip — emoji + name + a wave; flips to "✓" once sent.
struct NudgeChip: View {
    let member: CircleMember
    let prayer: Prayer
    let dayKey: String

    @EnvironmentObject private var state: AppState

    private var sent: Bool {
        state.nudgesSent.contains(state.nudgeKey(member: member, prayer: prayer, dayKey: dayKey))
    }

    var body: some View {
        Button {
            guard !sent else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Theme.spring) {
                state.sendNudge(to: member, prayer: prayer, dayKey: dayKey)
            }
        } label: {
            HStack(spacing: 5) {
                Text(member.emoji).font(.system(size: 13))
                Text(member.name)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text(sent ? "✓" : "👋")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(sent ? Theme.greenSoft.opacity(0.6) : Theme.bg))
            .overlay(Capsule().strokeBorder(
                sent ? Theme.green.opacity(0.5) : Theme.mist.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(sent)
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
// v3.6: the manual travel toggle and the "Can't pray right now?" entry moved
// to Settings (design session) — they're occasional, not everyday actions.
// Only the location-based auto-suggestion stays on Today.

/// v4: the device crossed several timezones since it last looked.
///
/// Distinct from `TravelSuggestionBanner` below, which fires on DISTANCE from
/// your saved home and only ever offers to combine prayers. This one fires on
/// the clock moving, and its job is to say the two things a traveller actually
/// wants to know on landing: the times you are looking at are the local ones
/// now, and the day you spent in the air is not going to cost you a streak.
/// HomeView shows one or the other, never both — two travel banners stacked
/// would be noise at precisely the moment someone is tired and disoriented.
struct TimeZoneChangeBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var location = LocationProvider.shared

    var body: some View {
        if let notice = state.pendingTravelNotice {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.qadaBlue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline)
                            .font(Theme.sans(13, .bold))
                            .foregroundStyle(Theme.inkDeep)
                        Text("Your streak is safe for the days you were crossing.")
                            .font(Theme.sans(11.5, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                HStack(spacing: 14) {
                    if !state.isTraveling {
                        Button("Combine prayers") {
                            withAnimation(Theme.spring) {
                                state.setTraveling(true)
                                state.pendingTravelNotice = nil
                            }
                        }
                        .font(Theme.sans(13, .bold))
                        .foregroundStyle(Theme.green)
                        .buttonStyle(.plain)
                    }
                    Button("Got it") {
                        withAnimation(Theme.spring) { state.pendingTravelNotice = nil }
                    }
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .id(notice.id)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// Name the place when CoreLocation knows it; otherwise say the true thing
    /// without pretending to know where "here" is.
    private var headline: String {
        if let place = location.placeName ?? nonEmptyFallback {
            return "Prayer times now follow \(place)"
        }
        return "Prayer times updated for your new timezone"
    }

    private var nonEmptyFallback: String? {
        let name = state.settings.locationName
        return name.isEmpty ? nil : name
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
// v3.6: gone from Today — the "Can't pray right now?" flow lives in Settings
// (BreakAndTravelCard), and resuming asks WHEN you started praying again
// (ResumeSheet in Views/Recovery).
