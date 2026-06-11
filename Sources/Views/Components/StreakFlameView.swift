import SwiftUI

// Owned by the components agent.
/// Streak indicator: gray/unlit flame when streak is 0 or today hasn't been
/// completed; warm animated flame + bold count otherwise.
struct StreakFlameView: View {
    let streak: Int
    let isLitToday: Bool

    private var isLit: Bool { isLitToday && streak > 0 }

    var body: some View {
        HStack(spacing: 5) {
            if isLit {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    litFlame(t: AppClock.now.timeIntervalSinceReferenceDate)
                }
            } else {
                Image(systemName: "flame")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.inkSoft.opacity(0.7))
            }

            Text("\(streak)")
                .font(Theme.sans(20, .heavy))
                .foregroundStyle(isLit ? Theme.ink : Theme.inkSoft)
                .contentTransition(.numericText(value: Double(streak)))
                .animation(Theme.spring, value: streak)
        }
    }

    private func litFlame(t: TimeInterval) -> some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(LinearGradient(
                colors: [Theme.coral, Theme.gold],
                startPoint: .top, endPoint: .bottom))
            .scaleEffect(1 + 0.07 * sin(t * 3.1), anchor: .bottom)
            .rotationEffect(.degrees(2.5 * sin(t * 2.3)))
            .shadow(color: Theme.gold.opacity(0.55), radius: 5)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        StreakFlameView(streak: 12, isLitToday: true)
        StreakFlameView(streak: 12, isLitToday: false)
        StreakFlameView(streak: 0, isLitToday: false)
    }
    .padding()
    .background(Theme.cream)
}
#endif
