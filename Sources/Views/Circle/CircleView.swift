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
struct CircleView: View {
    @EnvironmentObject private var state: AppState

    @State private var creatingChallenge = false
    @State private var showInvite = false
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
                .presentationDetents([.medium, .large])
        }
    }

    private var content: some View {
        let scores = state.weeklyScores()
        let weekIsEmpty = scores.allSatisfy { $0.xp == 0 }
        let crownID = state.race300WinnerID

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                        .id("tour-circle-top")

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
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            // v3.7: the guided tour scrolls its targets into view.
            .onChange(of: state.tutorialStep) { _, step in
                guard let step else { return }
                withAnimation(Theme.spring) {
                    if step == Tour.leaderboardIndex { proxy.scrollTo("tour-circle-top", anchor: .top) }
                    if step == Tour.challengesIndex { proxy.scrollTo("tour-challenges", anchor: .center) }
                }
            }
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
                Text(weekCountdownText)
                    .font(Theme.sans(14, .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            Button {
                showInvite = true
            } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.greenSoft))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
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

// MARK: - Empty state

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

        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = activeBuddies.map {
            (BuddySimulator.member(for: $0), BuddySimulator.visibleLogs(for: $0, days: days, asOf: now))
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

            if !member.isYou {
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

// MARK: - Invite (v3.6 — design session)

/// Add a friend: a shareable invite link, plus (demo) pool friends who can
/// "accept" so the add → celebration flow is tangible. Capped at 8 friends —
/// five photos a day is an intimate thing.
struct InviteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private let inviteLink = "https://salahbuddy.app/join/HML7-MOON"

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Theme.mist.opacity(0.6))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text("Invite a friend 🤝")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Your circle: \(state.activeBuddies.count) of \(BuddySimulator.maxFriends) friends")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)

            if state.circleIsFull {
                VStack(spacing: 6) {
                    Text("🫶")
                        .font(.system(size: 34))
                    Text("Your circle is full")
                        .font(Theme.sans(16, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text("Eight friends keeps it intimate — remove someone from the leaderboard to make room.")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
            } else {
                ShareLink(item: URL(string: inviteLink)!) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .bold))
                        Text("Share your invite link")
                            .font(Theme.sans(15, .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Theme.green))
                }
                .padding(.horizontal, 24)

                if !state.invitableBuddies.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Demo · pretend someone accepted")
                            .font(Theme.sans(11, .bold))
                            .foregroundStyle(Theme.inkMuted)
                            .textCase(.uppercase)
                        ForEach(state.invitableBuddies, id: \.name) { buddy in
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
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
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

    private var emoji: String {
        (BuddySimulator.invitablePool + BuddySimulator.buddies)
            .first { $0.name == name }?.emoji ?? "🎉"
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
