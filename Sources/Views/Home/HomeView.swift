import SwiftUI

// PLACEHOLDER — owned by the home agent, which will replace this file.
struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Today")
                    .font(Theme.rounded(28))
                    .foregroundStyle(Theme.ink)
                Text("HomeView placeholder")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
