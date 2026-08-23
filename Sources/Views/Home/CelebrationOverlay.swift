import SwiftUI

/// Full-screen celebration shown while `appState.celebration != nil`:
/// dim background, confetti, celebrating mascot, "+N XP" fly-up, and extra
/// lines for Perfect Day / level-up / new badge / streak extended.
/// Tap anywhere to dismiss (nils the celebration).
struct CelebrationOverlay: View {
    @EnvironmentObject private var state: AppState

    @State private var confettiTrigger = 0
    @State private var flyUp = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            ConfettiBurstView(trigger: confettiTrigger)
                .allowsHitTesting(false)

            if let result = state.celebration {
                VStack(spacing: 16) {
                    MascotView(mood: .celebrating, size: 140)

                    Text("+\(result.xpEarned) XP")
                        .font(Theme.rounded(46, .heavy))
                        .foregroundStyle(Theme.gold)
                        .offset(y: flyUp ? -12 : 22)
                        .scaleEffect(flyUp ? 1 : 0.5)
                        .opacity(flyUp ? 1 : 0)

                    Text("\(result.prayer.displayName) \(result.prayer.emoji) — \(result.tier.label)")
                        .font(Theme.rounded(19))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        extraLines(result)
                    }
                    .padding(.top, 4)

                    Text("Tap anywhere to continue")
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 14)
                }
                .padding(28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Bare on purpose. HomeView carries
            // `.animation(Theme.spring, value: state.celebration != nil)`,
            // which has to stay because AppState.log sets `celebration`
            // without an animation of its own — and scoring code should not be
            // reaching for one. Wrapping here too just ran the spring twice on
            // dismissal.
            state.celebration = nil
        }
        .onAppear { fire() }
        .onChange(of: state.celebration) { _, newValue in
            if newValue != nil { fire() }
        }
    }

    /// Replay confetti + fly-up + success haptic for a (new) celebration.
    private func fire() {
        confettiTrigger += 1
        flyUp = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { flyUp = true }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder
    private func extraLines(_ result: LogResult) -> some View {
        if result.perfectDay {
            celebrationRow("🌟", "Perfect Day! +\(result.bonusXP) XP bonus")
        }
        if result.streakExtended {
            celebrationRow("🔥", "Streak extended — \(state.profile.streak) days!")
        }
        if result.leveledUp {
            celebrationRow("⬆️", "Level up! Level \(state.level) — \(state.levelTitle)")
        }
        ForEach(result.newBadgeIDs, id: \.self) { id in
            if let badge = Badges.badge(id: id) {
                celebrationRow("🏅", "New badge: \(badge.name)")
            }
        }
    }

    private func celebrationRow(_ emoji: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(emoji)
                .font(.system(size: 16))
            Text(text)
                .font(Theme.rounded(15, .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.16)))
        .transition(.scale.combined(with: .opacity))
    }
}
