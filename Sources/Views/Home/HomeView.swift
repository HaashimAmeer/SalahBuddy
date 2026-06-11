import SwiftUI

/// Today screen — greeting bar, daily-goal ring, mascot, the 5 prayer cards,
/// and the celebration overlay. Owned by the home agent.
struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    HomeGreetingBar()
                    HomeGoalCard()
                    HomeMascotSection()
                    prayerCards
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }

            if state.celebration != nil {
                CelebrationOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(10)
            }
        }
        .animation(Theme.spring, value: state.celebration != nil)
    }

    private var prayerCards: some View {
        VStack(spacing: 12) {
            ForEach(Prayer.allCases) { prayer in
                PrayerCardView(prayer: prayer)
            }
        }
    }
}

// MARK: - Greeting bar

/// "Assalamu alaikum, {name}" + streak flame + XP chip.
struct HomeGreetingBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Assalamu alaikum,")
                    .font(Theme.rounded(14, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Text(displayName)
                    .font(Theme.rounded(26))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            StreakFlameView(streak: state.profile.streak, isLitToday: streakLitToday)
            XPChip(xp: state.profile.totalXP)
        }
    }

    private var displayName: String {
        let trimmed = state.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "friend" : trimmed
    }

    /// The flame is "lit" once today's streak increment has landed
    /// (all 5 prayers logged today).
    private var streakLitToday: Bool {
        state.profile.lastStreakDayKey == state.todayKey
    }
}

// MARK: - Daily goal card

/// Daily-goal progress ring (todayXP / dailyGoal) + level pill.
struct HomeGoalCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                ProgressRing(progress: goalProgress, lineWidth: 10, color: Theme.gold)
                VStack(spacing: 0) {
                    Text("\(state.todayXP)")
                        .font(Theme.rounded(24, .heavy))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text("XP")
                        .font(Theme.rounded(11, .heavy))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .frame(width: 86, height: 86)
            .animation(Theme.spring, value: state.todayXP)

            VStack(alignment: .leading, spacing: 8) {
                Text("Daily goal")
                    .font(Theme.rounded(13, .heavy))
                    .foregroundStyle(Theme.inkSoft)
                    .textCase(.uppercase)
                Text("\(state.todayXP) / \(state.settings.dailyGoal) XP")
                    .font(Theme.rounded(20))
                    .foregroundStyle(goalReached ? Theme.green : Theme.ink)
                levelPill
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardStyle()
    }

    private var goalProgress: Double {
        let goal = max(1, state.settings.dailyGoal)
        return min(1.0, Double(state.todayXP) / Double(goal))
    }

    private var goalReached: Bool { state.todayXP >= state.settings.dailyGoal }

    private var levelPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "rosette")
                .font(.system(size: 11, weight: .bold))
            Text("Lv \(state.level) · \(state.levelTitle)")
                .font(Theme.rounded(13, .heavy))
            Text("\(state.xpIntoLevel)/\(state.xpNeededForLevel)")
                .font(Theme.rounded(11, .bold))
                .foregroundStyle(Theme.greenDark.opacity(0.7))
        }
        .foregroundStyle(Theme.greenDark)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.green.opacity(0.14)))
    }
}
