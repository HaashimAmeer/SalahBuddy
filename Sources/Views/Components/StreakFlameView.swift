import SwiftUI

// PLACEHOLDER — owned by the components agent, which will replace this file.
struct StreakFlameView: View {
    let streak: Int
    let isLitToday: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isLitToday ? "flame.fill" : "flame")
                .foregroundStyle(isLitToday ? Theme.gold : Theme.inkSoft)
            Text("\(streak)")
                .font(Theme.rounded(17))
                .foregroundStyle(Theme.ink)
        }
    }
}
