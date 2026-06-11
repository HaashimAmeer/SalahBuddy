import SwiftUI

// PLACEHOLDER — owned by the league agent, which will replace this file.
struct LeagueView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("🌙 Crescent League")
                    .font(Theme.rounded(28))
                    .foregroundStyle(Theme.ink)
                Text("LeagueView placeholder")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
