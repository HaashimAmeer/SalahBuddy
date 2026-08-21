import SwiftUI

// Owned by the circle agent (SPEC-V2 §5: Views/Circle/*).
//
// The Circle tab — "Your Circle ☪️":
//   1. Header + week countdown (Mon-start week, resets next Monday 00:00).
//   2. Weekly scoreboard (emoji avatar, name, weekly XP bar, crown on the
//      race300 winner, your row highlighted).
//   3. Group week grid (WeekGridView — the "group data for this week").
//   4. Group challenges (ChallengeCard for the isGroup entries).
//   5. Tasteful empty state with a small MascotView when nothing has been
//      posted this week yet.
//
// v3.9 (solo-first): when the circle is EMPTY (`state.isSoloMode` — a new solo
// account, or a legacy one that removed everybody) the whole tab body is
// replaced by a single warm "build your circle" pitch. There's no leaderboard
// of one, no group grid, and no group challenges — the core already refuses to
// award those without a circle, and the tab shouldn't tease them either.
struct CircleView: View {
    @EnvironmentObject private var state: AppState
    // v4: the tab is the entry point to a REAL circle, so it needs both — the
    // service for the circle itself, and auth only to hand on to the sign-in
    // sheet it may present.
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var circleService: CircleService

    @State private var creatingChallenge = false
    @State private var showInvite = false
    @State private var showCircleSettings = false
    @State private var selectedMember: CircleMember?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Periodic redraw so the countdown and the live-filling grid /
            // scoreboard stay fresh. All time reads go through AppClock.now.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                content
            }

            // v3.6: tap a leaderboard member → centered pop-up with their
            // week + the remove option.
            if let member = selectedMember {
                CenteredModal(onClose: { selectedMember = nil }) {
                    MemberDetailContent(member: member) {
                        withAnimation(Theme.spring) {
                            state.removeMember(name: member.name)
                            selectedMember = nil
                        }
                    }
                }
                .zIndex(5)
            }
        }
        .animation(Theme.spring, value: selectedMember?.id)
        .sheet(isPresented: $creatingChallenge) {
            CreateChallengeSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
                .environmentObject(state)
                .environmentObject(auth)
                .environmentObject(circleService)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCircleSettings) {
            CircleSettingsSheet()
                .environmentObject(circleService)
                .presentationDetents([.large])
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                        .id("tour-circle-top")

                    // v4 Phase C: the brief's "waiting to sync" affordance,
                    // and it sits above everything because it is about the
                    // page below it being incomplete. Silent outside a real
                    // circle, and silent while the queue is moving.
                    if let sync: CircleSync = circleService.sync {
                        CircleSyncStatusRow(sync: sync)
                    }

                    if state.isSoloMode {
                        // v3.9: no circle yet — the whole tab is the pitch.
                        // Still a tour target, so step 4 spotlights something
                        // real instead of dimming an empty page.
                        SoloCircleCard(friendCapacity: state.friendCapacity,
                                       ctaTitle: soloCTATitle) { showInvite = true }
                            .tutorialTarget(.leaderboard)
                    } else {
                        circleBody
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            // v3.7: the guided tour scrolls its targets into view.
            .onChange(of: state.tutorialStep) { _, step in
                guard let step else { return }
                withAnimation(Theme.spring) {
                    if step == Tour.leaderboardIndex { proxy.scrollTo("tour-circle-top", anchor: .top) }
                    // v3.9: solo has no challenges section — the tour step
                    // falls back to its centered card, so don't chase the id.
                    if step == Tour.challengesIndex, !state.isSoloMode {
                        proxy.scrollTo("tour-challenges", anchor: .center)
                    }
                }
            }
        }
    }

    /// v4: with a real circle already created, the thing left to do is send the
    /// code — not build the circle again.
    private var soloCTATitle: String {
        circleService.snapshot.hasCircle ? "Share your code" : "Build your circle"
    }

    // MARK: Circle body (someone else is in here)

    /// Scoreboard + group week grid + group challenges. Only ever built when
    /// the circle has at least one friend, so none of it has to reason about
    /// a leaderboard of one.
    @ViewBuilder
    private var circleBody: some View {
        let scores = state.weeklyScores()
        // NOTE: this is an empty WEEK (nobody has posted yet), not an empty
        // CIRCLE — the solo path above takes precedence over it.
        let weekIsEmpty = scores.allSatisfy { $0.xp == 0 }
        let crownID = state.race300WinnerID

        Group {
            if weekIsEmpty {
                CircleEmptyStateCard()
            } else {
                ScoreboardCard(scores: scores, crownID: crownID) { member in
                    withAnimation(Theme.spring) { selectedMember = member }
                }
            }
        }
        .tutorialTarget(.leaderboard)

        if !weekIsEmpty {
            SectionHeader(title: "This week together", accent: "✦")
            WeekGridView(rows: state.weekRows())
        }

        // v3.7: header + cards in one container so the guided tour
        // can spotlight the whole challenges section.
        // v3.9 (belt and braces): group challenges never render without a
        // circle — the core stops awarding them, and `circleBody` is only
        // reached with friends present, but the guard keeps the two honest.
        if !state.isSoloMode {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Group challenges", accent: "✦")
                    Spacer()
                    // v3.2: circles can make their own challenges.
                    Button {
                        creatingChallenge = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.green)
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 12) {
                    ForEach(state.challenges().filter(\.isGroup)) { progress in
                        ChallengeCard(progress: progress)
                            .contextMenu {
                                if progress.id.hasPrefix("custom-") {
                                    Button(role: .destructive) {
                                        state.deleteCustomChallenge(id: progress.id)
                                    } label: {
                                        Label("Remove challenge", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
            .tutorialTarget(.challenges)
            .id("tour-challenges")
        }
    }

    // MARK: Header

    /// v3.6: same header format as every other page — title + the tiny moon
    /// icon (no more odd-one-out ☪️ emoji) — plus the invite button.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Your Circle")
                        .font(Theme.sans(30, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.green.opacity(0.55))
                        .offset(y: -6)
                }
                // v3.9: a week countdown over an empty page is noise — solo
                // gets the invitation instead.
                Text(headerSubtitle)
                    .font(Theme.sans(14, .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            headerButtons
        }
        .padding(.top, 8)
    }

    /// v4: a real circle you're the only one in isn't "nobody here yet" — it's
    /// a circle waiting on a code being sent, and saying so points at the one
    /// thing left to do.
    private var headerSubtitle: String {
        if !state.isSoloMode { return weekCountdownText }
        if circleService.snapshot.hasCircle { return "Just you so far — share your code" }
        return "Nobody here yet"
    }

    /// The gear only exists when there is a real circle behind it: in demo mode
    /// there is nothing to rename and nobody to leave.
    @ViewBuilder
    private var headerButtons: some View {
        if circleService.snapshot.hasCircle {
            headerButton(icon: "gearshape.fill") { showCircleSettings = true }
        }
        headerButton(icon: "person.badge.plus") { showInvite = true }
    }

    private func headerButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.green)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.greenSoft))
        }
        .buttonStyle(.plain)
    }

    /// "New week in 3d 4h" — counts down to next Monday 00:00 local.
    /// leagueResetDate is gone in v2; the Mon-start week end comes from
    /// the core week math.
    private var weekCountdownText: String {
        let now = AppClock.now
        let end = BuddySimulator.weekEnd(for: now)
        let remaining = max(0, end.timeIntervalSince(now))
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "New week in \(days)d \(hours)h" }
        if hours > 0 { return "New week in \(hours)h \(minutes)m" }
        return "New week in \(minutes)m"
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let accent: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.sans(17, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text(accent)
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.gold)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Weekly scoreboard

private struct ScoreboardCard: View {
    let scores: [(member: CircleMember, xp: Int)]
    let crownID: String?
    let onTapMember: (CircleMember) -> Void

    @State private var expanded = false

    var body: some View {
        let maxXP = max(300, scores.map(\.xp).max() ?? 0)
        let ranked = Array(scores.enumerated())   // (offset, entry), already sorted desc
        let myIndex = ranked.firstIndex { $0.element.member.isYou }

        return VStack(spacing: 6) {
            if expanded {
                // v3.8: tapped open — the whole stack, then "show less".
                ForEach(ranked, id: \.element.member.id) { index, entry in
                    row(index: index, entry: entry, maxXP: maxXP)
                }
                toggle(expand: false, count: ranked.count)
            } else {
                // Top 3 always; then a tappable "⋯ see all"; then, if you're off
                // the podium, just the rows around you (above + you + below) so a
                // big circle never clogs the page.
                ForEach(ranked.prefix(3), id: \.element.member.id) { index, entry in
                    row(index: index, entry: entry, maxXP: maxXP)
                }
                if ranked.count > 3 {
                    toggle(expand: true, count: ranked.count)
                    if let my = myIndex, my >= 3 {
                        let lower = max(3, my - 1)
                        let upper = min(ranked.count - 1, my + 1)
                        ForEach(Array(ranked[lower...upper]), id: \.element.member.id) { index, entry in
                            row(index: index, entry: entry, maxXP: maxXP)
                        }
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
        .animation(Theme.spring, value: expanded)
    }

    private func row(index: Int, entry: (member: CircleMember, xp: Int), maxXP: Int) -> some View {
        ScoreboardRow(rank: index + 1,
                      member: entry.member,
                      xp: entry.xp,
                      maxXP: maxXP,
                      hasCrown: entry.member.id == crownID,
                      onTap: { onTapMember(entry.member) })
    }

    /// The "⋯ See all N" (collapsed) / "Show less" (expanded) control.
    private func toggle(expand: Bool, count: Int) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { expanded = expand }
        } label: {
            HStack(spacing: 6) {
                if expand {
                    Text("⋯").font(Theme.sans(18, .heavy))
                    Text("See all \(count)").font(Theme.sans(12, .bold))
                } else {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                    Text("Show less").font(Theme.sans(12, .bold))
                }
            }
            .foregroundStyle(Theme.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ScoreboardRow: View {
    let rank: Int
    let member: CircleMember
    let xp: Int
    let maxXP: Int
    let hasCrown: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                rankBadge

                // Avatar — profile photo for you, emoji for buddies.
                ZStack {
                    Circle()
                        .fill(member.isYou ? Theme.greenSoft : Theme.bg)
                    MemberAvatarView(member: member, size: 40)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(member.isYou ? "\(member.name) (you)" : member.name)
                            .font(Theme.sans(15, member.isYou ? .bold : .semibold))
                            .foregroundStyle(Theme.inkDeep)
                            .lineLimit(1)
                        if hasCrown {
                            Text("👑")
                                .font(.system(size: 14))
                        }
                    }
                    XPBar(fraction: maxXP > 0 ? Double(xp) / Double(maxXP) : 0)
                }

                Spacer(minLength: 8)

                Text("\(xp) XP")
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.gold)
                    .monospacedDigit()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(member.isYou ? Theme.greenSoft.opacity(0.55) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// v3.6 (design session): Duolingo-style medals for the podium, plain
    /// numbers for everyone else — always cute for the gamification theme.
    @ViewBuilder
    private var rankBadge: some View {
        Group {
            switch rank {
            case 1: Text("🥇").font(.system(size: 18))
            case 2: Text("🥈").font(.system(size: 18))
            case 3: Text("🥉").font(.system(size: 18))
            default:
                Text("\(rank)")
                    .font(Theme.sans(14, .heavy))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(width: 24)
    }
}

private struct XPBar: View {
    let fraction: Double   // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bg)
                Capsule()
                    .fill(Theme.gold)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 7)
        .animation(Theme.spring, value: fraction)
    }
}

// MARK: - Solo state (v3.9 — solo-first)

/// The whole Circle tab when there's nobody in it: a warm pitch for what a
/// circle actually buys you, then the one button that starts it. Deliberately
/// shows no leaderboard, no grid and no challenges — an empty scoreboard with
/// only your own row in it reads as a bug, not an invitation.
private struct SoloCircleCard: View {
    /// v4: passed in rather than read off `BuddySimulator` — a real circle
    /// seats one fewer friend than the demo one, and this card is the first
    /// place the number is quoted.
    let friendCapacity: Int
    /// v4: "Build your circle" for a solo account, "Share your code" once a
    /// real circle exists and is just waiting on people.
    var ctaTitle: String = "Build your circle"
    let onBuild: () -> Void

    private struct Perk: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private static let perks: [Perk] = [
        Perk(icon: "photo.on.rectangle.angled", title: "Prayer photos",
             detail: "Their squares fill in next to yours, live through the day."),
        Perk(icon: "square.grid.3x3.fill", title: "A shared week",
             detail: "One grid for all of you — see who's keeping all five."),
        Perk(icon: "flag.checkered", title: "Group challenges",
             detail: "Take on Fajr streaks together and everyone earns the bonus."),
    ]

    var body: some View {
        VStack(spacing: 16) {
            MascotView(mood: .happy, size: 76)

            VStack(spacing: 8) {
                Text("Better with company ✦")
                    .font(Theme.sans(20, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Keeping all five is easier when someone's keeping it with you. Add a friend and this page comes alive.")
                    .font(Theme.sans(14, .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.perks) { perk in
                    perkRow(perk)
                }
            }
            .padding(.top, 2)

            ChunkyButton(title: ctaTitle, color: Theme.green, isEnabled: true) {
                onBuild()
            }

            Text("Up to \(friendCapacity) friends — five photos a day is an intimate thing.")
                .font(Theme.sans(12, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .cardStyle()
    }

    private func perkRow(_ perk: Perk) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: perk.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.green)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.greenSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(perk.title)
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text(perk.detail)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Empty state

// MARK: - "Waiting to sync" (v4 Phase C)

/// The honest row the offline queue owes the person.
///
/// v4 Phase C FIX: `CircleSync` published `status`, `pendingCount`,
/// `discardedCount`, `stalledItem` and `retryNow()` from the day it was
/// written, and not one view read any of them — so a write the server refused
/// seven times was dropped with no trace anywhere, and the gap only ever showed
/// up as a hole in next week's grid. The brief asks for the affordance
/// "somewhere honest"; the Circle tab is the page whose contents are wrong
/// while a write is stuck.
///
/// Deliberately quiet: `.idle`, `.syncing` and `.pending` say nothing at all —
/// a queue that is merely moving is not news, and a badge that is always up is
/// a badge nobody reads.
private struct CircleSyncStatusRow: View {
    @ObservedObject var sync: CircleSync

    var body: some View {
        Group {
            if let message: String = statusMessage {
                card(message)
            }
        }
    }

    /// Nil means "nothing worth saying".
    private var statusMessage: String? {
        if sync.discardedCount > 0 {
            let count: Int = sync.discardedCount
            let noun: String = count == 1 ? "post" : "posts"
            return "\(count) \(noun) didn't reach your circle. Your own record is safe."
        }
        guard case .waiting(let count, let reason) = sync.status else { return nil }
        let noun: String = count == 1 ? "update" : "updates"
        return "\(count) \(noun) waiting to sync — \(reason.title.lowercased())."
    }

    private func card(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(message)
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try now") {
                Task { await sync.retryNow() }
            }
            .font(Theme.sans(13, .bold))
            .foregroundStyle(Theme.green)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .cardStyle()
    }
}

private struct CircleEmptyStateCard: View {
    var body: some View {
        VStack(spacing: 12) {
            MascotView(mood: .happy, size: 64)
            Text("A fresh week ✦")
                .font(Theme.sans(17, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("No one in your circle has posted yet.\nBe the first to share a prayer 📸")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .cardStyle()
    }
}

// MARK: - race300 winner (extension in circle-owned file)

// AppState doesn't expose the race300 winner directly; per the hard rules we
// extend it here using only its public surface + core APIs. Same week math
// and visible-log derivation as the scoreboard, so they always agree.
extension AppState {
    /// The member who crossed 300 weekly XP EARLIEST this week (crown holder),
    /// nil while nobody has crossed. Pure function of AppClock.now + logs —
    /// time-travel safe (no caching).
    var race300WinnerID: String? {
        // v3.9: a race of one isn't a race. The core already drops the race300
        // challenge without a circle; this keeps the crown off the (never
        // rendered) solo scoreboard too, so the two can't disagree.
        guard !isSoloMode else { return nil }

        let now = AppClock.now
        let coords = activeCoordinates
        let dayKeys = BuddySimulator.weekDayKeys(for: now)

        let days: [(dayKey: String, schedule: DaySchedule)] = dayKeys.compactMap { key in
            guard let dayStart = AppClock.date(fromDayKey: key) else { return nil }
            let schedule = PrayerTimeService.schedule(for: dayStart.addingTimeInterval(12 * 3600),
                                                      latitude: coords.latitude,
                                                      longitude: coords.longitude,
                                                      method: settings.calcMethod,
                                                      madhab: settings.madhab)
            return schedule.map { (key, $0) }
        }

        // v4: the crown reads the same seam the scoreboard does, so a real
        // circle races on synced posts without touching this math.
        let source = circleSource
        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = source.members.map { member in
            (member, source.weekLogs(forMember: member.id, days: days, asOf: now))
        }
        if let you = circleMembers.first(where: { $0.isYou }) {
            let weekKeySet = Set(dayKeys)
            memberWeekLogs.append((you, logs.filter { weekKeySet.contains($0.dayKey) }))
        }
        return ChallengeEngine.raceWinnerID(memberWeekLogs: memberWeekLogs, threshold: 300)
    }
}

// MARK: - Member detail pop-up (v3.6 — design session)

/// Tap a leaderboard member: their week at a glance (one summary square per
/// day, same color language as the group grid) plus the remove option.
/// Lives inside `CenteredModal`.
struct MemberDetailContent: View {
    let member: CircleMember
    let onRemove: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var removeConfirm = false

    private static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(member.isYou ? Theme.greenSoft : Theme.bg)
                    MemberAvatarView(member: member, size: 64)
                }
                .frame(width: 64, height: 64)
                Text(member.isYou ? "\(member.name) (you)" : member.name)
                    .font(Theme.sans(20, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("\(weeklyXP) XP this week")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.gold)
            }

            weekStrip

            // v4: a real circle is leave-only (SPEC-V4 §2) — no remove button
            // there, rather than a confirm dialog in front of a no-op.
            if !member.isYou, state.canRemoveMembers {
                if removeConfirm {
                    VStack(spacing: 8) {
                        Text("Remove \(member.name) from your circle?")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        HStack(spacing: 10) {
                            Button("Keep them") {
                                withAnimation(Theme.spring) { removeConfirm = false }
                            }
                            .font(Theme.sans(13, .bold))
                            .foregroundStyle(Theme.green)
                            .buttonStyle(.plain)
                            Button("Remove") { onRemove() }
                                .font(Theme.sans(13, .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Theme.amber))
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    Button {
                        withAnimation(Theme.spring) { removeConfirm = true }
                    } label: {
                        Text("Remove from circle")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.amber)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var weeklyXP: Int {
        state.weeklyScores().first { $0.member.id == member.id }?.xp ?? 0
    }

    /// Mon-first 7 squares — done-count per day, like the group grid cells.
    private var weekStrip: some View {
        let row = state.weekRows().first { $0.id == member.id }
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { dayIndex in
                let cells = row?.days.indices.contains(dayIndex) == true ? row!.days[dayIndex] : []
                VStack(spacing: 3) {
                    Text(Self.dayInitials[dayIndex])
                        .font(Theme.sans(10, .bold))
                        .foregroundStyle(Theme.inkMuted)
                    dayCell(cells)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cells: [GridCellState]) -> some View {
        let done = cells.filter {
            if case .inWindow = $0 { return true }
            if case .qada = $0 { return true }
            return false
        }.count
        let isFuture = cells.isEmpty || cells.allSatisfy { $0 == .future }
        let isExcused = !cells.isEmpty && cells.allSatisfy { $0 == .excused }

        Group {
            if isFuture {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.mist.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
            } else if isExcused {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.lilac)
                    .overlay(Image(systemName: "moon.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(done == 0 ? Theme.mist.opacity(0.45)
                          : done == 5 ? Theme.green
                          : Theme.green.opacity(0.25 + 0.13 * Double(done)))
                    .overlay(Text("\(done)")
                        .font(Theme.sans(11, .heavy))
                        .foregroundStyle(done == 0 ? Theme.inkMuted : .white))
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Invite (v3.6; v4 — the real share flow)

/// The circle's front door (SPEC-V4 §2, code-first).
///
/// Which of the three states you get is decided by `CircleService.phase`:
///   • **in a circle** → the six-character code, big and copyable, a share
///     message that reads like a person wrote it, and who's already here.
///   • **signed in, no circle** → start one, or type a friend's code.
///   • **signed out** → the pitch, and the one sign-in that makes it real.
///
/// The simulated roster survives ONLY on a developer build in demo mode:
/// tapping a fictional name to make them "accept" is a screenshot tool now,
/// not a feature.
struct InviteSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn: Bool = false
    @State private var showCreate: Bool = false
    @State private var showJoin: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(spacing: 18) {
                    content
                    demoSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .sheet(isPresented: $showSignIn) { signInSheet }
        .sheet(isPresented: $showCreate) { createSheet }
        .sheet(isPresented: $showJoin) { joinSheet }
    }

    // MARK: Routing

    /// `working` is a passing state, not a screen. Whatever the circle looked
    /// like a moment ago is still the truest thing to draw, and the sheet doing
    /// the work is on top of this one anyway.
    private var displayPhase: CircleService.Phase {
        guard circleService.phase == .working else { return circleService.phase }
        return circleService.snapshot.hasCircle ? .inCircle : .noCircle
    }

    @ViewBuilder
    private var content: some View {
        switch displayPhase {
        case .inCircle:
            inCircleContent
        case .noCircle:
            noCircleContent
        case .signedOut:
            signedOutContent
        case .working:
            noCircleContent
        }
    }

    private var signInSheet: some View {
        SignInSheet()
            .environmentObject(auth)
            .environmentObject(circleService)
            .presentationDetents([.large])
    }

    private var createSheet: some View {
        CreateCircleSheet()
            .environmentObject(circleService)
            .presentationDetents([.large])
    }

    private var joinSheet: some View {
        JoinCircleSheet()
            .environmentObject(circleService)
            .presentationDetents([.medium, .large])
    }

    // MARK: In a circle — the code is the invite

    @ViewBuilder
    private var inCircleContent: some View {
        circleTitle
        codeCard
        if circleService.snapshot.remainingSlots > 0 {
            shareButton
            Text(slotsLine)
                .font(Theme.sans(12, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            CircleNoticeCard(notice: InviteSheet.fullNotice)
        }
        rosterCard
    }

    private var circleTitle: some View {
        VStack(spacing: 6) {
            Text(circleEmoji)
                .font(.system(size: 38))
            Text(circleName)
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
                .multilineTextAlignment(.center)
            Text("Send this code to whoever should be in it.")
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var codeCard: some View {
        VStack(spacing: 8) {
            Text("Invite code")
                .font(Theme.sans(11, .bold))
                .foregroundStyle(Theme.inkMuted)
                .textCase(.uppercase)
            Text(inviteCode)
                .font(.system(size: 32, weight: .heavy, design: .monospaced))
                .kerning(5)
                .foregroundStyle(Theme.inkDeep)
            Text(copied ? "Copied ✓" : "Tap to copy")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(copied ? Theme.green : Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture { copyCode() }
    }

    private var shareButton: some View {
        ShareLink(item: shareMessage) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                Text("Send an invite")
                    .font(Theme.sans(15, .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(Theme.green))
        }
    }

    private var rosterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who's here")
                .font(Theme.sans(11, .bold))
                .foregroundStyle(Theme.inkMuted)
                .textCase(.uppercase)
            ForEach(state.circleMembers) { member in
                rosterRow(member)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
    }

    private func rosterRow(_ member: CircleMember) -> some View {
        HStack(spacing: 10) {
            MemberAvatarView(member: member, size: 30)
            Text(member.isYou ? "\(member.name) (you)" : member.name)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkDeep)
            Spacer(minLength: 0)
        }
    }

    // MARK: Signed in, no circle yet

    @ViewBuilder
    private var noCircleContent: some View {
        VStack(spacing: 10) {
            Text("🌱")
                .font(.system(size: 38))
            Text("Your circle starts here")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Start one and share the code, or put in the code a friend already sent you.")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)

        ChunkyButton(title: "Start a circle", color: Theme.green, isEnabled: true) {
            showCreate = true
        }

        Button {
            showJoin = true
        } label: {
            Text("I have a code")
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(Theme.greenSoft))
        }
        .buttonStyle(.plain)
    }

    // MARK: Signed out

    @ViewBuilder
    private var signedOutContent: some View {
        VStack(spacing: 10) {
            MascotView(mood: .happy, size: 68)
            Text("Build your circle")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("A circle is up to eight real people on real phones, keeping all five together. To find each other, we just need to know who you are.")
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)

        ChunkyButton(title: "Sign in to start", color: Theme.green, isEnabled: !auth.isWorking) {
            showSignIn = true
        }

        Text("Already got a code from a friend? Sign in first — you can put it in straight after.")
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Demo roster (developer builds, demo mode only)

    /// SPEC-V4 §2: the simulator survives behind `BuildEnv` as "Demo circle",
    /// mutually exclusive with a real one. It is how screenshots and the guided
    /// tour get a populated circle without eight friends and eight phones.
    @ViewBuilder
    private var demoSection: some View {
        if showsDemoSection {
            VStack(alignment: .leading, spacing: 8) {
                Text("Demo circle")
                    .font(Theme.sans(11, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)
                if state.circleIsFull {
                    Text("The demo circle is full — remove someone from the leaderboard to make room.")
                        .font(Theme.sans(12, .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(state.invitableBuddies, id: \.name) { buddy in
                        buddyRow(buddy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    /// A lone "DEMO CIRCLE" heading with nothing under it is just clutter —
    /// which is what happens once every simulated buddy is already in.
    private var showsDemoSection: Bool {
        guard BuildEnv.showsDeveloperTools, state.settings.circleMode == .demo else { return false }
        return state.circleIsFull || !state.invitableBuddies.isEmpty
    }

    private func buddyRow(_ buddy: BuddySimulator.Buddy) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Theme.spring) { state.acceptInvite(name: buddy.name) }
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(buddy.emoji).font(.system(size: 20))
                Text(buddy.name)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer()
                Text("Joins instantly")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.green)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Copy + helpers

    private var circleName: String {
        circleService.snapshot.circle?.name ?? "Your Circle"
    }

    private var circleEmoji: String {
        circleService.snapshot.circle?.emoji ?? "🤝"
    }

    private var inviteCode: String {
        circleService.snapshot.circle?.code ?? "——————"
    }

    private var slotsLine: String {
        let left: Int = circleService.snapshot.remainingSlots
        if left == 1 { return "One more seat left." }
        return "\(left) more can join — eight in total, you included."
    }

    /// Written to be forwarded as-is. Universal links land the day a domain
    /// does (§2); until then the code IS the invite, so the message has to
    /// carry it in a way a person would actually type.
    private var shareMessage: String {
        "Pray with me? 🌙 I keep my five daily prayers with a few friends on SalahBuddy — join my circle with this code: \(inviteCode)"
    }

    /// A full circle is a fact about the circle, not something you did wrong.
    private static let fullNotice = CircleNotice(
        title: "Your circle is full",
        message: "Eight people, five photos a day — that's the whole idea. There's a seat again the moment someone leaves.")

    private func copyCode() {
        guard circleService.snapshot.circle != nil else { return }
        UIPasteboard.general.string = inviteCode
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Theme.spring) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(Theme.spring) { copied = false }
        }
    }
}

// MARK: - New member celebration (v3.6 — design session)

/// One-time pop-up the first time the app opens after someone joins:
/// "X just joined!" with a welcome-XP gift. Presented from RootView so it
/// shows no matter which tab is up.
struct NewMemberCelebration: View {
    let name: String

    @EnvironmentObject private var state: AppState
    @State private var sent = false

    /// v3.9: one roster lookup — a solo circle's first friend can come from
    /// the base 8 just as easily as from the invitable extras.
    private var emoji: String {
        BuddySimulator.buddy(named: name)?.emoji ?? "🎉"
    }

    var body: some View {
        CenteredModal(onClose: { state.clearPendingNewMember() }) {
            VStack(spacing: 14) {
                Text(emoji)
                    .font(.system(size: 52))
                Text("\(name) just joined your circle!")
                    .font(Theme.sans(20, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .multilineTextAlignment(.center)
                Text("Start them off with a little welcome gift — it shows up on their journey.")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    guard !sent else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(Theme.spring) { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        withAnimation(Theme.spring) { state.clearPendingNewMember() }
                    }
                } label: {
                    Text(sent ? "Sent! 💛" : "Send +5 XP welcome ⚡")
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(sent ? Theme.gold : Theme.green))
                }
                .buttonStyle(.plain)

                Button("Say salam later") {
                    withAnimation(Theme.spring) { state.clearPendingNewMember() }
                }
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Create challenge (v3.2)

/// Wheel-picker pop-up from the design session: pick the prayer and the
/// number of days; everyone in the circle has to log it that many days in a
/// row. Reward scales with length.
struct CreateChallengeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var prayer: Prayer = .fajr
    @State private var days = 3

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Theme.mist.opacity(0.6))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text("New group challenge 🤝")
                .font(Theme.sans(20, .bold))
                .foregroundStyle(Theme.inkDeep)

            Text("Everyone in the circle logs…")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)

            HStack(spacing: 0) {
                Picker("Prayer", selection: $prayer) {
                    ForEach(Prayer.allCases) { p in
                        Text("\(p.emoji) \(p.displayName)").tag(p)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("Days", selection: $days) {
                    ForEach(2...7, id: \.self) { d in
                        Text("\(d) days").tag(d)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 130)

            Text("Reward: +\(days * 15) XP each")
                .font(Theme.sans(14, .bold))
                .foregroundStyle(Theme.gold)

            ChunkyButton(title: "Start the challenge", color: Theme.green, isEnabled: true) {
                state.createCustomChallenge(prayer: prayer, days: days)
                dismiss()
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }
}
