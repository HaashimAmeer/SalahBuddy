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

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Periodic redraw so the countdown and the live-filling grid /
            // scoreboard stay fresh. All time reads go through AppClock.now.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                content
            }
        }
        .sheet(isPresented: $creatingChallenge) {
            CreateChallengeSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
        }
    }

    private var content: some View {
        let scores = state.weeklyScores()
        let weekIsEmpty = scores.allSatisfy { $0.xp == 0 }
        let crownID = state.race300WinnerID

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if weekIsEmpty {
                    CircleEmptyStateCard()
                } else {
                    ScoreboardCard(scores: scores, crownID: crownID)

                    SectionHeader(title: "This week together", accent: "✦")
                    WeekGridView(rows: state.weekRows())
                }

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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Circle ☪️")
                .font(Theme.sans(28, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text(weekCountdownText)
                .font(Theme.sans(14, .medium))
                .foregroundStyle(Theme.inkMuted)
        }
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

    var body: some View {
        let maxXP = max(300, scores.map(\.xp).max() ?? 0)

        return VStack(spacing: 6) {
            ForEach(scores, id: \.member.id) { entry in
                ScoreboardRow(member: entry.member,
                              xp: entry.xp,
                              maxXP: maxXP,
                              hasCrown: entry.member.id == crownID)
            }
        }
        .padding(14)
        .cardStyle()
    }
}

private struct ScoreboardRow: View {
    let member: CircleMember
    let xp: Int
    let maxXP: Int
    let hasCrown: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Emoji avatar
            ZStack {
                Circle()
                    .fill(member.isYou ? Theme.greenSoft : Theme.bg)
                Text(member.emoji)
                    .font(.system(size: 20))
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

        var memberWeekLogs: [(member: CircleMember, logs: [PrayerLog])] = BuddySimulator.buddies.map {
            (BuddySimulator.member(for: $0), BuddySimulator.visibleLogs(for: $0, days: days, asOf: now))
        }
        if let you = circleMembers.first(where: { $0.isYou }) {
            let weekKeySet = Set(dayKeys)
            memberWeekLogs.append((you, logs.filter { weekKeySet.contains($0.dayKey) }))
        }
        return ChallengeEngine.raceWinnerID(memberWeekLogs: memberWeekLogs, threshold: 300)
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
