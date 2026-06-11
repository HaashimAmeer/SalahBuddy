import SwiftUI

// PLACEHOLDER — owned by the components agent, which will replace this file.
struct XPChip: View {
    let xp: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.gold)
            Text("\(xp) XP")
                .font(Theme.rounded(15))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.gold.opacity(0.18)))
    }
}
