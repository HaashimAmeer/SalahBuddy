import SwiftUI

// Owned by the components agent.
/// One challenge: emoji medallion, title + detail, progress bar
/// (current/target), reward XP chip, and a celebratory completed state.
struct ChallengeCard: View {
    let progress: ChallengeProgress

    private var isDone: Bool { progress.completedAt != nil }

    private var fraction: Double {
        guard progress.target > 0 else { return isDone ? 1 : 0 }
        if isDone { return 1 }
        return min(1, max(0, Double(progress.current) / Double(progress.target)))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Emoji medallion.
            ZStack {
                Circle()
                    .fill(isDone ? Theme.green.opacity(0.16) : Theme.greenSoft.opacity(0.6))
                Text(progress.emoji)
                    .font(.system(size: 24))
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .bottomTrailing) {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.green)
                        .background(Circle().fill(Theme.surface).padding(1))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(progress.title)
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(Theme.inkDeep)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if progress.isGroup {
                        Text("CIRCLE")
                            .font(Theme.sans(8.5, .heavy))
                            .foregroundStyle(Theme.qadaBlue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.qadaBlue.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    rewardChip
                }

                Text(progress.detail)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)

                // Progress bar + count.
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.greenSoft.opacity(0.7))
                            Capsule()
                                .fill(isDone ? Theme.green : Theme.green.opacity(0.85))
                                .frame(width: max(fraction > 0 ? 7 : 0,
                                                  geo.size.width * fraction))
                                .animation(Theme.spring, value: fraction)
                        }
                    }
                    .frame(height: 7)

                    Text(isDone ? "Done!" : "\(min(progress.current, progress.target))/\(progress.target)")
                        .font(Theme.sans(11, .bold))
                        .foregroundStyle(isDone ? Theme.green : Theme.inkMuted)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isDone ? Theme.green.opacity(0.35) : .clear, lineWidth: 1.5)
        )
        .opacity(isDone ? 1 : 0.98)
    }

    private var rewardChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .heavy))
            Text("+\(progress.rewardXP)")
                .font(Theme.sans(11, .heavy))
        }
        .foregroundStyle(isDone ? .white : Theme.gold)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isDone ? Theme.gold : Theme.gold.opacity(0.15)))
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        ChallengeCard(progress: ChallengeProgress(
            id: "fajr3", title: "Dawn Patrol Run", detail: "Fajr in-window 3 days in a row",
            emoji: "🌅", isGroup: false, target: 3, current: 2, completedAt: nil, rewardXP: 30))
        ChallengeCard(progress: ChallengeProgress(
            id: "isha3", title: "Circle Isha Streak", detail: "Every member logs Isha 3 days in a row",
            emoji: "🌙", isGroup: true, target: 3, current: 1, completedAt: nil, rewardXP: 50))
        ChallengeCard(progress: ChallengeProgress(
            id: "fullday", title: "Full Day", detail: "All 5 prayers in-window in one day",
            emoji: "✨", isGroup: false, target: 5, current: 5,
            completedAt: AppClock.now, rewardXP: 20))
    }
    .padding()
    .background(Theme.bg)
}
#endif
