import SwiftUI

// PLACEHOLDER — owned by the stats-settings agent, which will replace this file.
struct StatsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Journey")
                    .font(Theme.rounded(28))
                    .foregroundStyle(Theme.ink)
                Text("StatsView placeholder")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
