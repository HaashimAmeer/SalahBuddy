import SwiftUI
import CoreLocation
import UserNotifications

/// Single playful onboarding flow — mascot welcome, name field, location +
/// notification permission buttons, chunky "Let's go!" CTA that sets
/// `hasOnboarded`. Owned by the home agent.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var location = LocationProvider.shared

    @State private var name = ""
    @State private var notifGranted = false
    @State private var mascotIn = false

    var body: some View {
        ZStack {
            Theme.cream.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    MascotView(mood: .happy, size: 140)
                        .scaleEffect(mascotIn ? 1 : 0.6)
                        .opacity(mascotIn ? 1 : 0)
                        .padding(.top, 28)

                    VStack(spacing: 6) {
                        Text("Hi! I'm Hilal 🌙")
                            .font(Theme.rounded(30, .heavy))
                            .foregroundStyle(Theme.ink)
                        Text("Let's build your prayer streak together —\none salah at a time.")
                            .font(Theme.rounded(15, .semibold))
                            .foregroundStyle(Theme.inkSoft)
                            .multilineTextAlignment(.center)
                    }

                    nameCard
                    permissionsCard

                    ChunkyButton(title: "Let's go! 🚀", color: Theme.green, isEnabled: true) {
                        finish()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { mascotIn = true }
            refreshNotificationStatus()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Name

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should I call you?")
                .font(Theme.rounded(15))
                .foregroundStyle(Theme.ink)
            TextField("Your name", text: $name)
                .font(Theme.rounded(18, .semibold))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.cream)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.inkSoft.opacity(0.3), lineWidth: 1)
                        )
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(spacing: 14) {
            OnboardingPermissionRow(
                icon: "location.fill",
                tint: Theme.sky,
                title: "Prayer times near you",
                subtitle: locationSubtitle,
                granted: locationGranted
            ) {
                location.requestPermission()
            }

            Divider()

            OnboardingPermissionRow(
                icon: "bell.fill",
                tint: Theme.gold,
                title: "Prayer reminders",
                subtitle: notifGranted ? "Reminders are on" : "A nudge when each prayer opens",
                granted: notifGranted
            ) {
                requestNotifications()
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var locationGranted: Bool {
        location.authorizationStatus == .authorizedWhenInUse
            || location.authorizationStatus == .authorizedAlways
    }

    private var locationSubtitle: String {
        if locationGranted {
            return location.placeName.map { "Using \($0)" } ?? "Using your location"
        }
        return "Or I'll use \(state.settings.locationName) for now"
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                notifGranted = granted
                if granted {
                    var s = state.settings
                    s.notificationsEnabled = true
                    state.settings = s
                }
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notifGranted = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    // MARK: - Finish

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.setName(trimmed) }
        var s = state.settings
        s.hasOnboarded = true
        state.settings = s   // didSet persists + refreshes
    }
}

// MARK: - Permission row

/// One tappable permission row: icon bubble, title/subtitle, check or chevron.
struct OnboardingPermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard !granted else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.rounded(16))
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(Theme.rounded(12, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: granted ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(granted ? Theme.green : Theme.inkSoft.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: granted)
    }
}
