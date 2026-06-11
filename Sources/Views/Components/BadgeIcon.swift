import SwiftUI

// PLACEHOLDER — owned by the components agent, which will replace this file.
struct BadgeIcon: View {
    let badge: Badge
    let earned: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(earned ? Theme.gold : Theme.inkSoft.opacity(0.5))
            Text(badge.name)
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(earned ? Theme.ink : Theme.inkSoft)
        }
    }
}
