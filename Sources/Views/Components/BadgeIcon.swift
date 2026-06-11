import SwiftUI

// Owned by the components agent.
/// Badge tile: rich colored medallion when earned, flat grayscale when locked.
struct BadgeIcon: View {
    let badge: Badge
    let earned: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(medallionStyle)
                    .frame(width: 62, height: 62)
                    .shadow(color: earned ? Theme.gold.opacity(0.4) : .clear,
                            radius: 6, y: 3)

                if earned {
                    Circle()
                        .stroke(Color(hex: 0xE09E12).opacity(0.55), lineWidth: 2)
                        .frame(width: 62, height: 62)
                    // glint
                    Circle()
                        .fill(LinearGradient(
                            colors: [.white.opacity(0.45), .clear],
                            startPoint: .topLeading, endPoint: .center))
                        .frame(width: 56, height: 56)
                }

                Image(systemName: badge.symbolName)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(earned ? Color.white : Theme.inkSoft.opacity(0.55))
                    .shadow(color: earned ? .black.opacity(0.15) : .clear,
                            radius: 1, y: 1)
            }
            .saturation(earned ? 1 : 0)
            .scaleEffect(earned ? 1 : 0.96)
            .animation(Theme.spring, value: earned)

            Text(badge.name)
                .font(Theme.rounded(12, earned ? .bold : .semibold))
                .foregroundStyle(earned ? Theme.ink : Theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .opacity(earned ? 1 : 0.8)
    }

    private var medallionStyle: AnyShapeStyle {
        if earned {
            AnyShapeStyle(LinearGradient(
                colors: [Color(hex: 0xFFD66B), Theme.gold],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            AnyShapeStyle(Color(hex: 0xE9E4DA))
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 18) {
        BadgeIcon(
            badge: Badge(id: "streak7", name: "On Fire",
                         symbolName: "flame.fill", detail: "Reach a 7-day streak"),
            earned: true)
        BadgeIcon(
            badge: Badge(id: "xp5000", name: "Luminary",
                         symbolName: "sun.max.fill", detail: "Earn 5,000 total XP"),
            earned: false)
    }
    .padding()
    .background(Theme.cream)
}
#endif
