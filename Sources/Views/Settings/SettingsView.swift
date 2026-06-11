import SwiftUI

// PLACEHOLDER — owned by the stats-settings agent, which will replace this file.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Settings")
                    .font(Theme.rounded(28))
                    .foregroundStyle(Theme.ink)
                Text("SettingsView placeholder")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
