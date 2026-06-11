import SwiftUI

// Owned by the components agent.
/// Gold lightning bolt + XP count in a pill. The number rolls with a
/// numeric-text transition when XP changes.
struct XPChip: View {
    let xp: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: 0xFFD66B), Theme.gold],
                    startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.gold.opacity(0.4), radius: 2)

            Text("\(xp)")
                .font(Theme.rounded(16, .heavy))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: Double(xp)))
                .animation(Theme.spring, value: xp)

            Text("XP")
                .font(Theme.rounded(11, .heavy))
                .foregroundStyle(Theme.gold)
                .baselineOffset(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.gold.opacity(0.16)))
        .overlay(Capsule().stroke(Theme.gold.opacity(0.35), lineWidth: 1.5))
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 14) {
        XPChip(xp: 0)
        XPChip(xp: 85)
        XPChip(xp: 12480)
    }
    .padding()
    .background(Theme.cream)
}
#endif
