import SwiftUI

// MARK: - Today pager (v5 mockup)

/// The Today screen: swipe sideways between today's prayers, scroll down into
/// each prayer's circle feed. Opens on the live window and follows it as the
/// day moves on. Only the sideways swipe snaps — each page scrolls freely.
struct TodayPager: View {
    let onPost: (TodayPage) -> Void
    let onEnlarge: (GridEntry, Prayer) -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var selection: String?
    @State private var travelSuggestionDismissed = false

    var body: some View {
        let pages = state.todayPages(now: now)
        let currentIndex = TodayPages.currentIndex(in: pages, now: now)
        let currentID = pages.indices.contains(currentIndex) ? pages[currentIndex].id : nil

        TabView(selection: $selection) {
            ForEach(pages) { page in
                TodayPageView(page: page,
                              pages: pages,
                              currentID: currentID,
                              select: { id in withAnimation(Theme.spring) { selection = id } },
                              onPost: onPost,
                              onEnlarge: onEnlarge,
                              travelSuggestionDismissed: $travelSuggestionDismissed)
                    .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onAppear { if selection == nil { selection = currentID } }
        // A new window opening moves you onto it; a page you swiped to on
        // purpose stays put otherwise.
        .onChange(of: currentID) { previous, current in
            if selection == nil || selection == previous { selection = current }
        }
        // A travel toggle or a new day changes the pages under you.
        .onChange(of: pages.map(\.id)) { _, ids in
            if let selection, ids.contains(selection) { return }
            self.selection = currentID
        }
        // The tour points at the live prayer's page.
        .onChange(of: state.tutorialStep) { _, step in
            if step != nil { selection = currentID }
        }
    }
}

// MARK: - One page

struct TodayPageView: View {
    let page: TodayPage
    let pages: [TodayPage]
    let currentID: String?
    let select: (String) -> Void
    let onPost: (TodayPage) -> Void
    let onEnlarge: (GridEntry, Prayer) -> Void
    @Binding var travelSuggestionDismissed: Bool

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var scrolledIntoFeed = false
    @State private var showRecharge = false
    @State private var showResume = false
    @State private var showXPInfo = false

    private var isCurrent: Bool { page.id == currentID }
    private var currentPage: TodayPage? { pages.first { $0.id == currentID } }

    var body: some View {
        let status = state.pageStatus(page, now: now)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    TodayHeader()
                        .id("tour-home-top")
                    travelNotes
                    YourDayRow(pages: pages, selectedID: page.id, select: select)
                        .tutorialTarget(.earlierToday)
                        .id("tour-earlier")
                    viewingBanner
                    PrayerCard(page: page, status: status, isCurrent: isCurrent,
                               onPost: { onPost(page) },
                               onEnlarge: { onEnlarge($0, page.prayer) },
                               showRecharge: $showRecharge,
                               showResume: $showResume,
                               showXPInfo: $showXPInfo)
                        .modifier(TourTargetIf(active: isCurrent, target: .postPhoto))
                    upNext(status)
                    if isCurrent {
                        MakeUpSection()
                    }
                    dhikrShortcut(status)
                    CircleFeed(page: page, status: status,
                               onEnlarge: { onEnlarge($0, page.prayer) })
                    endCard(proxy)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y > 520
            } action: { _, down in
                withAnimation(Theme.spring) { scrolledIntoFeed = down }
            }
            .overlay(alignment: .bottom) { floatingControls(proxy, status: status) }
            // v3.7: the guided tour scrolls its targets into view.
            .onChange(of: state.tutorialStep) { previous, step in
                guard isCurrent else { return }
                withAnimation(Theme.spring) {
                    if step == nil, previous != nil { proxy.scrollTo("tour-home-top", anchor: .top) }
                    if step == Tour.postPhotoIndex { proxy.scrollTo("tour-home-top", anchor: .top) }
                    if step == Tour.earlierTodayIndex { proxy.scrollTo("tour-earlier", anchor: .center) }
                }
            }
        }
        .sheet(isPresented: $showRecharge) {
            RecoverySheet().environmentObject(state)
        }
        .sheet(isPresented: $showResume) {
            ResumeSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showXPInfo) {
            NavigationStack {
                ScrollView { ScoringExplainerContent().padding(16) }
                    .background(Theme.bg)
                    .navigationTitle("How scoring works")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showXPInfo = false }
                        }
                    }
            }
            .environmentObject(state)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Travel

    @ViewBuilder
    private var travelNotes: some View {
        if isCurrent, state.pendingTravelNotice != nil {
            TimeZoneChangeBanner()
        } else if isCurrent, !state.isTraveling {
            TravelSuggestionBanner(dismissed: $travelSuggestionDismissed)
        }
        if state.isTraveling {
            HStack(spacing: 10) {
                Text("🧳").font(.system(size: 20))
                Text("Traveling — pray Dhuhr + Asr and Maghrib + Isha together, and log once.")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("I'm home") {
                    withAnimation(Theme.spring) { state.setTraveling(false) }
                }
                .font(Theme.sans(12, .heavy))
                .foregroundStyle(Theme.inkMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .cardStyle()
        }
    }

    // MARK: Which prayer is live

    /// On any other page, the live prayer — while it still wants your post —
    /// stays one tap away.
    @ViewBuilder
    private var viewingBanner: some View {
        if !isCurrent, let current = currentPage,
           state.pageStatus(current, now: now) == .open {
            HStack(spacing: 12) {
                Text(current.prayer.emoji).font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(current.title) is open now")
                        .font(Theme.sans(15, .heavy))
                        .foregroundStyle(Theme.inkDeep)
                    Text(openLine(current))
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Button {
                    select(current.id)
                } label: {
                    Text("Post 📸")
                        .font(Theme.sans(13, .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.green))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.greenSoft, lineWidth: 2))
        }
    }

    private func openLine(_ current: TodayPage) -> String {
        let left = "\(HomeTimeFormat.countdown(to: current.end, from: now)) left"
        guard let tier = state.pageTier(current), tier.isInWindow else { return left }
        return "\(left) · +\(tier.xp) XP now"
    }

    // MARK: Up next / dhikr

    @ViewBuilder
    private func upNext(_ status: TodayPageStatus) -> some View {
        if isCurrent, case .logged = status,
           let index = pages.firstIndex(where: { $0.id == page.id }),
           pages.indices.contains(index + 1),
           let start = pages[index + 1].start, start > now {
            let next = pages[index + 1]
            HStack(spacing: 10) {
                Text(next.prayer.emoji).font(.system(size: 20))
                Text("Up next: \(next.title) at \(HomeTimeFormat.clock(start))")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                Spacer(minLength: 4)
                Text(HomeTimeFormat.countdown(to: start, from: now))
                    .font(Theme.sans(15, .heavy))
                    .foregroundStyle(Theme.inkDeep)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func dhikrShortcut(_ status: TodayPageStatus) -> some View {
        let waiting: Bool = {
            switch status {
            case .logged, .upcoming: return true
            default: return false
            }
        }()
        if isCurrent, waiting {
            Button { showRecharge = true } label: {
                HStack(spacing: 12) {
                    Text("📿").font(.system(size: 24))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dhikr & deeds while you wait")
                            .font(Theme.sans(15, .heavy))
                            .foregroundStyle(Theme.inkDeep)
                        Text("🌟 \(state.dhikrToday) dhikr today · +\(state.recoveryXPToday) XP")
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: End of the feed

    @ViewBuilder
    private func endCard(_ proxy: ScrollViewProxy) -> some View {
        if !state.isSoloMode, scrolledIntoFeed {
            VStack(spacing: 10) {
                Text(page.prayer.emoji).font(.system(size: 36))
                Text("That's everyone for \(page.title)")
                    .font(Theme.sans(18, .heavy))
                    .foregroundStyle(Theme.inkDeep)
                Button("Back to the top") {
                    withAnimation(Theme.spring) { proxy.scrollTo("tour-home-top", anchor: .top) }
                }
                .font(Theme.sans(15, .heavy))
                .foregroundStyle(Theme.inkDeep)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    // MARK: Floating controls

    @ViewBuilder
    private func floatingControls(_ proxy: ScrollViewProxy, status: TodayPageStatus) -> some View {
        if scrolledIntoFeed {
            ZStack {
                Button {
                    withAnimation(Theme.spring) { proxy.scrollTo("tour-home-top", anchor: .top) }
                } label: {
                    Text("↑ \(page.title)")
                        .font(Theme.sans(13, .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.inkDeep))
                        .shadow(color: .black.opacity(0.2), radius: 9, y: 6)
                }
                .buttonStyle(.plain)

                if isCurrent, status == .open {
                    HStack {
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onPost(page)
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                                .background(Circle().fill(Theme.green))
                                .shadow(color: Theme.green.opacity(0.5), radius: 0, y: 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Post your \(page.title) photo")
                    }
                    .padding(.trailing, 18)
                }
            }
            .padding(.bottom, 14)
            .transition(.scale(scale: 0.86).combined(with: .opacity))
        }
    }
}

/// `.tutorialTarget` on one page only — every page carries the same card, and
/// the tour must spotlight the live one.
private struct TourTargetIf: ViewModifier {
    let active: Bool
    let target: TutorialTarget

    func body(content: Content) -> some View {
        if active { content.tutorialTarget(target) } else { content }
    }
}

// MARK: - Your day

/// Five prayers at a glance — tap one to swipe to it.
struct YourDayRow: View {
    let pages: [TodayPage]
    let selectedID: String
    let select: (String) -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR DAY")
                    .font(Theme.sans(12, .heavy))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Text(summary)
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 6) {
                ForEach(pages) { page in
                    chip(page)
                }
            }
        }
    }

    private var summary: String {
        let today = pages.filter { !$0.isYesterdayIsha }
        let done = today.filter {
            if case .logged = state.pageStatus($0, now: now) { return true }
            return false
        }
        .reduce(0) { $0 + ($1.combinedWith == nil ? 1 : 2) }
        return "\(done) of 5 · +\(state.todayXP) XP"
    }

    private func chip(_ page: TodayPage) -> some View {
        let status = state.pageStatus(page, now: now)
        let selected = page.id == selectedID
        let look = style(status)
        return Button { select(page.id) } label: {
            VStack(spacing: 2) {
                Text(page.prayer.emoji).font(.system(size: 17))
                Text(page.combinedWith == nil ? page.prayer.displayName
                                              : "\(page.prayer.displayName)+")
                    .font(Theme.sans(11, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(page.isYesterdayIsha ? "last night" : label(page, status))
                    .font(Theme.sans(10, .heavy))
                    .foregroundStyle(look.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .monospacedDigit()
            }
            .foregroundStyle(look.ink)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(look.bg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.inkDeep : .clear, lineWidth: 2))
            .scaleEffect(selected ? 1.04 : 1)
            .animation(Theme.spring, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.title), \(label(page, status))")
    }

    private func label(_ page: TodayPage, _ status: TodayPageStatus) -> String {
        switch status {
        case .logged(let log):
            return log.tier.xp > 0 ? "✓ +\(log.tier.xp)" : "✓"
        case .open:
            return HomeTimeFormat.countdown(to: page.end, from: now)
        case .upcoming:
            return page.start.map(HomeTimeFormat.clock) ?? ""
        case .missed:
            return "Missed"
        case .excused:
            return "Resting"
        }
    }

    private func style(_ status: TodayPageStatus) -> (bg: Color, ink: Color, sub: Color) {
        switch status {
        case .logged(let log):
            let color = log.tier.isInWindow ? Theme.color(for: .inWindow(log.tier))
                                            : (log.tier == .forgot ? Theme.green : Theme.qadaBlue)
            return (color.opacity(0.22), Theme.inkDeep, Theme.inkDeep)
        case .open:
            return (Theme.gold.opacity(0.28), Theme.inkDeep, Color(hex: 0x7A5600))
        case .upcoming:
            return (Theme.surface, Theme.inkDeep, Theme.inkMuted)
        case .missed:
            return (Theme.mist.opacity(0.45), Theme.inkMuted, Theme.inkMuted)
        case .excused:
            return (Theme.lilac.opacity(0.2), Theme.inkDeep, Theme.lilac)
        }
    }
}

// MARK: - The prayer card

/// One card per prayer: your photo fills it once you post; before that it is
/// the countdown and the camera; afterwards, a made-up, missed, resting or
/// coming-up card.
struct PrayerCard: View {
    let page: TodayPage
    let status: TodayPageStatus
    let isCurrent: Bool
    let onPost: () -> Void
    let onEnlarge: (GridEntry) -> Void
    @Binding var showRecharge: Bool
    @Binding var showResume: Bool
    @Binding var showXPInfo: Bool

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        switch status {
        case .logged(let log):
            loggedCard(log)
        case .open:
            openCard
        case .upcoming:
            upcomingCard
        case .missed(let canMakeUp):
            missedCard(canMakeUp: canMakeUp)
        case .excused:
            restingCard
        }
    }

    private var title: some View {
        Text("\(page.prayer.emoji) \(page.title)")
            .font(Theme.sans(22, .heavy))
            .foregroundStyle(Theme.inkDeep)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    // MARK: Logged

    @ViewBuilder
    private func loggedCard(_ log: PrayerLog) -> some View {
        let mine = state.gridEntries(for: page.prayer, dayKey: page.dayKey)
            .first { $0.member.isYou }
        if let mine, case .posted = mine.state {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 4)
                    pill(log.tier.label, Theme.color(for: .inWindow(log.tier)))
                    pill("+\(log.xp) XP", Theme.gold, ink: Color(hex: 0x3A2A00))
                }
                GeometryReader { geo in
                    PhotoSquare(entry: mine, size: geo.size.width)
                }
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture { onEnlarge(mine) }
                .shadow(color: Theme.inkDeep.opacity(0.14), radius: 12, y: 8)
                if isCurrent, page.dayKey == state.todayKey || page.isYesterdayIsha {
                    Button("Undo post") { undo() }
                        .font(Theme.sans(12, .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } else {
            // Made up, forgot to log, or an old photo-less log.
            VStack(alignment: .leading, spacing: 6) {
                title
                HStack {
                    Text(log.tier == .forgot ? "✓ \(log.tier.label)" : "💙 \(log.tier.label)")
                        .font(Theme.sans(16, .heavy))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer()
                    if log.xp > 0 {
                        Text("+\(log.xp) XP")
                            .font(Theme.sans(15, .heavy))
                            .foregroundStyle(Theme.qadaBlue)
                    }
                }
                Text("Logged \(HomeTimeFormat.clock(log.loggedAt))")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill([Color(hex: 0xE8EEFC), Color(hex: 0xC9D6F6)]))
        }
    }

    private func undo() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(Theme.spring) {
            state.undoLog(page.prayer)
            if let partner = page.combinedWith { state.undoLog(partner) }
        }
    }

    // MARK: Open

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 4)
                Text("ends \(HomeTimeFormat.clock(page.end))")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Color(hex: 0x3F6B55))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(HomeTimeFormat.countdown(to: page.end, from: now))
                    .font(Theme.sans(46, .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Theme.inkDeep)
                Text("left")
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Color(hex: 0x3F6B55))
            }
            if state.logs.isEmpty {
                Text("Your first one 🌙 The photo is just your marker — it stays on this phone unless you start a circle.")
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tierBar
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPost()
            } label: {
                Text("Tap to post 📸")
                    .font(Theme.sans(17, .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.green))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0x1F8A50)).offset(y: 4))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill([Color(hex: 0xDFF2E6), Color(hex: 0xBFE3CD)]))
    }

    /// The gold bar: how long the XP you would earn now lasts. Tap for the
    /// scoring explainer.
    @ViewBuilder
    private var tierBar: some View {
        if let tier = state.pageTier(page), tier.isInWindow {
            let combinedWindow = page.combinedWith != nil ? state.combinedWindow(lead: page.prayer) : nil
            let window = combinedWindow ?? page.window
            let boundary = window.flatMap { TodayPages.tierBoundary(for: $0, at: now) }
            Button { showXPInfo = true } label: {
                HStack(spacing: 10) {
                    if let window, let boundary {
                        let quarter = window.end.timeIntervalSince(window.start) / 4
                        let left = max(0, boundary.timeIntervalSince(now))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(hex: 0x7A5600).opacity(0.14))
                                Capsule().fill(Theme.gold)
                                    .frame(width: geo.size.width * CGFloat(quarter > 0 ? left / quarter : 0))
                            }
                        }
                        .frame(height: 6)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(barLabel(tier: tier, boundary: boundary))
                        .font(Theme.sans(12, .heavy))
                        .foregroundStyle(Color(hex: 0x7A5600))
                        .monospacedDigit()
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x7A5600))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What the XP bar means")
        }
    }

    private func barLabel(tier: LogTier, boundary: Date?) -> String {
        let each = page.combinedWith != nil ? " each" : ""
        guard let boundary else { return "⚡ +\(tier.xp) XP\(each)" }
        return "⚡ +\(tier.xp) XP\(each) · \(HomeTimeFormat.countdown(to: boundary, from: now))"
    }

    // MARK: Upcoming / missed / resting

    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            if let start = page.start {
                Text(HomeTimeFormat.countdown(to: start, from: now))
                    .font(Theme.sans(44, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("until it opens at \(HomeTimeFormat.clock(start))")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill([Theme.greenSoft.opacity(0.5), Theme.surface]))
    }

    private func missedCard(canMakeUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            Text("You didn't log it · window ended at \(HomeTimeFormat.clock(page.end))")
                .font(Theme.sans(14, .bold))
                .foregroundStyle(Theme.inkMuted)
            if canMakeUp {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(Theme.spring) {
                        let candidates = state.makeUpPrayers
                        for prayer in [page.prayer] + [page.combinedWith].compactMap({ $0 })
                        where candidates.contains(prayer) {
                            state.logQada(prayer)
                        }
                    }
                } label: {
                    Text("Make up \(page.title) · +\(LogTier.qada.xp) XP")
                        .font(Theme.sans(15, .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.qadaBlue))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill([Color(hex: 0xEEF1EF), Color(hex: 0xD6DCD8)]))
    }

    private var restingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                title
                Spacer()
                pill("Resting 🌙", Theme.lilac)
            }
            Text("Resting today — your streak is safe 💜")
                .font(Theme.sans(16, .heavy))
                .foregroundStyle(Color(hex: 0x4B3470))
            Text("Your circle just sees “Excused”.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Color(hex: 0x6B4A8C))
            HStack(spacing: 8) {
                Button { showRecharge = true } label: {
                    Text("📿 Dhikr & deeds")
                        .font(Theme.sans(14, .heavy))
                        .foregroundStyle(Color(hex: 0x4B3470))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                }
                .buttonStyle(.plain)
                if state.isOnBreak {
                    Button { showResume = true } label: {
                        Text("Resume prayers")
                            .font(Theme.sans(14, .heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.lilac))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill([Color(hex: 0xF1EAFB), Color(hex: 0xDCCDF2)]))
    }

    // MARK: Bits

    private func pill(_ text: String, _ color: Color, ink: Color = .white) -> some View {
        Text(text)
            .font(Theme.sans(12, .heavy))
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
            .lineLimit(1)
    }

    private func cardFill(_ colors: [Color]) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: Theme.inkDeep.opacity(0.1), radius: 12, y: 8)
    }
}

// MARK: - The circle feed

/// Everyone else's post for this prayer, one full-width card each, newest
/// first, then made-ups, then whoever is still to post. Scrolls freely with
/// the page, like a feed.
struct CircleFeed: View {
    let page: TodayPage
    let status: TodayPageStatus
    let onEnlarge: (GridEntry) -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        if state.isSoloMode {
            soloCard
        } else if status == .upcoming {
            note("Your circle's \(page.title) photos show up here once it opens.")
        } else {
            let entries = feedEntries
            VStack(alignment: .leading, spacing: 14) {
                header(entries)
                ForEach(entries) { entry in
                    FeedCard(entry: entry, page: page,
                             nudgeAllowed: nudgeAllowed,
                             onEnlarge: onEnlarge)
                }
            }
        }
    }

    /// The Today screen's own nudge gate — the widget's `waiting[]` reads the
    /// same function, so the two surfaces cannot name different people.
    private var nudgeAllowed: Bool {
        WidgetSnapshotBuilder.nudgesAllowed(window: page.window,
                                            isCarryOver: page.isYesterdayIsha, now: now)
            && !state.isExcused(prayer: page.prayer, dayKey: page.dayKey)
    }

    private var feedEntries: [GridEntry] {
        let others = state.gridEntries(for: page.prayer, dayKey: page.dayKey)
            .filter { !$0.member.isYou && $0.state != .excused }
        func rank(_ entry: GridEntry) -> (Int, Date) {
            switch entry.state {
            case .posted(_, _, let at): return (0, at)
            case .qada(let at): return (1, at)
            case .waiting: return (2, .distantPast)
            default: return (3, .distantPast)
            }
        }
        return others.sorted {
            let a = rank($0), b = rank($1)
            return a.0 != b.0 ? a.0 < b.0 : a.1 > b.1
        }
    }

    private func header(_ entries: [GridEntry]) -> some View {
        let prayed = entries.filter {
            switch $0.state {
            case .posted, .qada: return true
            default: return false
            }
        }.count
        return HStack(alignment: .firstTextBaseline) {
            Text("YOUR CIRCLE · \(page.title.uppercased())")
                .font(Theme.sans(12, .heavy))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Text("\(prayed) of \(entries.count) prayed")
                .font(Theme.sans(12, .bold))
                .foregroundStyle(Color(hex: 0x1F8A50))
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
    }

    private var soloCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pray with your people 🤝")
                .font(Theme.sans(16, .heavy))
                .foregroundStyle(Theme.inkDeep)
            Text("Start a circle from the Circle tab, and everyone's \(page.title) photos show up here.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(13, .semibold))
            .foregroundStyle(Theme.inkMuted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 20)
    }
}

/// One friend in the feed.
struct FeedCard: View {
    let entry: GridEntry
    let page: TodayPage
    let nudgeAllowed: Bool
    let onEnlarge: (GridEntry) -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        switch entry.state {
        case .posted(_, let tier, let at):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.member.name)
                            .font(Theme.sans(16, .heavy))
                            .foregroundStyle(Theme.inkDeep)
                        Text(HomeTimeFormat.clock(at))
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 4)
                    Text(tier.label)
                        .font(Theme.sans(12, .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.color(for: .inWindow(tier))))
                }
                GeometryReader { geo in
                    PhotoSquare(entry: entry, size: geo.size.width)
                }
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture { onEnlarge(entry) }
            }
        case .qada(let at):
            statusCard(emoji: entry.member.emoji,
                       title: "\(entry.member.name) made it up",
                       subtitle: "Logged \(HomeTimeFormat.clock(at)) 💙",
                       colors: [Color(hex: 0xE8EEFC), Color(hex: 0xC9D6F6)]) { EmptyView() }
        case .waiting:
            statusCard(emoji: entry.member.emoji,
                       title: "\(entry.member.name) hasn't posted yet",
                       subtitle: minutesIn,
                       colors: [Color(hex: 0xDCEFE2), Color(hex: 0xC4E2CF)]) {
                if nudgeAllowed {
                    NudgeChip(member: entry.member, prayer: page.prayer, dayKey: page.dayKey)
                        .scaleEffect(1.15)
                        .padding(.top, 4)
                }
            }
        case .missed, .excused:
            statusCard(emoji: entry.member.emoji,
                       title: "\(entry.member.name) · not logged",
                       subtitle: "A make-up still counts 💙",
                       colors: [Color(hex: 0xE4E8E5), Color(hex: 0xC9CFCB)]) { EmptyView() }
        }
    }

    private var avatar: some View {
        Text(entry.member.emoji)
            .font(.system(size: 19))
            .frame(width: 38, height: 38)
            .background(Circle().fill(Theme.surface))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var minutesIn: String {
        guard let start = page.start, now > start else { return "Still time to pray" }
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes < 60 { return "\(minutes) minutes into \(page.title)" }
        return "\(minutes / 60)h \(minutes % 60)m into \(page.title)"
    }

    private func statusCard<Extra: View>(emoji: String, title: String, subtitle: String,
                                         colors: [Color],
                                         @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 8) {
            Text(emoji).font(.system(size: 44))
            Text(title)
                .font(Theme.sans(17, .heavy))
                .foregroundStyle(Theme.inkDeep)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
            extra()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}
