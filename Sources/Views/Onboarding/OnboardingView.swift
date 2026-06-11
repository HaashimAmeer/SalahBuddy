import SwiftUI

// PLACEHOLDER — owned by the home agent, which will replace this file.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            VStack(spacing: 16) {
                MascotView(mood: .happy, size: 120)
                Text("Welcome to SalahBuddy")
                    .font(Theme.rounded(24))
                    .foregroundStyle(Theme.ink)
                ChunkyButton(title: "Let's go!", color: Theme.green, isEnabled: true) {
                    var s = state.settings
                    s.hasOnboarded = true
                    state.settings = s
                }
                .padding(.horizontal, 32)
            }
        }
    }
}
