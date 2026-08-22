import SwiftUI
import UserNotifications
import UIKit

/// v4 DECISION (§5): the master Notifications switch stays absolute — joining
/// a circle never forces a permission sheet on someone who turned notifications
/// off. But leaving it there silently was the wrong half of that choice: nudges
/// from friends simply never arrive, with nothing on screen saying why.
///
/// So: a hint, not a prompt. It appears only where it is actionable, it says
/// what is actually happening, and it can be put away for good.
///
/// The distinction matters for the two states people are actually in. Someone
/// who tapped "Don't Allow" at onboarding cannot be re-prompted by iOS at all —
/// they need system Settings, and this routes them there. Someone who merely
/// SKIPPED the onboarding card is still `.notDetermined`, so "Turn on" really
/// does prompt. Those two were indistinguishable before, and both dead ends.
struct CirclePushHint: View {
    @EnvironmentObject private var state: AppState

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var working = false

    var body: some View {
        // Real circles only. A demo nudge never leaves the device, so there is
        // nothing for push to deliver and nothing to nag about.
        if state.settings.circleMode == .real,
           !state.settings.notificationsEnabled,
           !state.settings.circlePushHintDismissed {
            card
                .task { status = await NotificationManager.shared.authorizationStatus() }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.gold)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                Text("Notifications are off")
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Nudges from your circle won't reach you, and you won't hear when someone posts first.")
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    Button(action: turnOn) {
                        Text(status == .denied ? "Open Settings" : "Turn on")
                            .font(Theme.sans(13, .bold))
                            .foregroundStyle(Theme.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(working)

                    Button {
                        var s = state.settings
                        s.circlePushHintDismissed = true
                        state.settings = s
                    } label: {
                        Text("Not now")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Mirrors the Settings toggle's flow deliberately — same three cases, same
    /// order — because there is exactly one correct answer per authorization
    /// state and two screens must not disagree about it.
    private func turnOn() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            let current = await NotificationManager.shared.authorizationStatus()
            status = current
            switch current {
            case .notDetermined:
                guard await NotificationManager.shared.requestPermission() else {
                    status = await NotificationManager.shared.authorizationStatus()
                    return
                }
                var s = state.settings
                s.notificationsEnabled = true
                state.settings = s
                NotificationManager.shared.reschedule()
            case .denied:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            default:
                var s = state.settings
                s.notificationsEnabled = true
                state.settings = s
                NotificationManager.shared.reschedule()
            }
        }
    }
}
