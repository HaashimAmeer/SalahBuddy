import SwiftUI

/// Crescent League — weekly leaderboard vs. simulated friends.
/// Owned by the league agent.
struct LeagueView: View {
    @EnvironmentObject private var state: AppState

    /// Local tick so the countdown + board stay live (board XP moves during the day).
    @State private var now = AppClock.now

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let entries = state.leaderboard()
        let myRank = (entries.firstIndex(where: { $0.isYou }) ?? entries.count - 1) + 1

        ZStack {
            Theme.cream.ignoresSafeArea()

            VStack(spacing: 0) {
                LeagueHeader(resetsIn: resetCountdownText)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            LeagueRow(entry: entry, rank: index + 1)

                            if index == 2 && entries.count > 3 {
                                PromotionDivider()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .animation(Theme.spring, value: entries.map(\.id))
                }

                LeagueFooter(rank: myRank, total: entries.count)
            }
        }
        .onReceive(tick) { _ in now = AppClock.now }
    }

    // MARK: - Countdown

    private var resetCountdownText: String {
        let remaining = max(0, state.leagueResetDate().timeIntervalSince(now))
        let totalMinutes = Int(remaining) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }
}

// MARK: - Header

private struct LeagueHeader: View {
    let resetsIn: String

    var body: some View {
        VStack(spacing: 6) {
            Text("🌙 Crescent League")
                .font(Theme.rounded(28, .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)

            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .bold))
                Text(resetsIn)
                    .font(Theme.rounded(14, .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.18)))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [Theme.lilac, Theme.sky],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Text("✨")
                    .font(.system(size: 22))
                    .padding(.top, 14)
                    .padding(.trailing, 24)
                    .opacity(0.8)
            }
            .clipShape(
                UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous)
            )
            .ignoresSafeArea(edges: .top)
        )
    }
}

// MARK: - Row

private struct LeagueRow: View {
    let entry: LeaderboardEntry
    let rank: Int

    private var medal: String? {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }

    private var inPromotionZone: Bool { rank <= 3 }

    /// Deterministic avatar-circle color per name.
    private var avatarColor: Color {
        let palette: [Color] = [Theme.sky, Theme.gold, Theme.green, Theme.coral, Theme.lilac]
        let hash = entry.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        HStack(spacing: 12) {
            // Rank / medal
            Group {
                if let medal {
                    Text(medal).font(.system(size: 24))
                } else {
                    Text("\(rank)")
                        .font(Theme.rounded(17, .heavy))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .frame(width: 32)

            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.22))
                Text(entry.avatar)
                    .font(.system(size: 22))
            }
            .frame(width: 44, height: 44)
            .overlay(Circle().strokeBorder(avatarColor.opacity(0.45), lineWidth: 2))

            // Name
            HStack(spacing: 5) {
                Text(entry.name)
                    .font(Theme.rounded(16, .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if entry.isYou {
                    Text("(You)")
                        .font(Theme.rounded(13, .heavy))
                        .foregroundStyle(Theme.green)
                }
            }

            Spacer(minLength: 8)

            // XP
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.gold)
                Text("\(entry.xp) XP")
                    .font(Theme.rounded(15, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(inPromotionZone ? Theme.gold.opacity(0.13) : Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    entry.isYou ? Theme.green : (inPromotionZone ? Theme.gold.opacity(0.45) : .clear),
                    lineWidth: entry.isYou ? 2.5 : 1.5
                )
        )
        .scaleEffect(entry.isYou ? 1.02 : 1.0)
    }
}

// MARK: - Promotion divider

private struct PromotionDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            line
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .heavy))
                Text("PROMOTION ZONE")
                    .font(Theme.rounded(11, .heavy))
                    .kerning(1.0)
            }
            .foregroundStyle(Theme.gold)
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.gold.opacity(0.4))
            .frame(height: 2)
            .clipShape(Capsule())
    }
}

// MARK: - Footer

private struct LeagueFooter: View {
    let rank: Int
    let total: Int

    private var mood: MascotMood {
        switch rank {
        case 1: return .celebrating
        case 2...3: return .happy
        case ...(max(3, total / 2)): return .neutral
        default: return .worried
        }
    }

    private var comment: String {
        switch rank {
        case 1: return "You're #1! Mashallah, keep shining! ✨"
        case 2: return "So close to the top — one more salah!"
        case 3: return "Bronze! The promotion zone suits you 🥉"
        case ...(max(3, total / 2)): return "Solid! Every prayer climbs the board."
        case total: return "Last place is just the start of a comeback!"
        default: return "Let's climb! Your next salah moves you up."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            MascotView(mood: mood, size: 52)

            Text(comment)
                .font(Theme.rounded(14, .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
