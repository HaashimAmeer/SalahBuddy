import SwiftUI

/// Placeholder stub — the circle agent owns Views/Circle/* and replaces this
/// with the full v2 Circle screen (scoreboard, week grid, group challenges).
struct CircleView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Your Circle ☪️")
                    .font(Theme.sans(24, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Coming together soon")
                    .font(Theme.sans(15, .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }
}
