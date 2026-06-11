import SwiftUI
import CoreLocation
import UserNotifications

/// v2 onboarding — three soft steps: mascot welcome + name, goal-setting
/// ("which prayer is hardest?" incl. none — seeds the goal3 challenge),
/// then permissions + "Let's go!". Owned by the home agent.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var location = LocationProvider.shared

    @State private var step = 0
    @State private var name = ""
    @State private var hardest: Prayer?
    @State private var pickedGoal = false
    @State private var notifGranted = false
    @State private var mascotIn = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            decorations

            VStack(spacing: 0) {
                stepDots
                    .padding(.top, 18)

                ScrollView(showsIndicators: false) {
                    Group {
                        switch step {
                        case 0: welcomeStep
                        case 1: goalStep
                        default: permissionsStep
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                footer
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .animation(Theme.spring, value: step)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { mascotIn = true }
            refreshNotificationStatus()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Chrome

    /// Subtle crescent/star accents per §2.
    private var decorations: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.green.opacity(0.14))
                    .padding(.trailing, 30)
                    .padding(.top, 60)
            }
            Spacer()
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.gold.opacity(0.18))
                    .padding(.leading, 34)
                    .padding(.bottom, 100)
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Theme.green : Theme.greenSoft)
                    .frame(width: i == step ? 22 : 8, height: 8)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            ChunkyButton(title: step == 2 ? "Let's go! 🚀" : "Continue",
                         color: Theme.green, isEnabled: true) {
                advance()
            }
            if step > 0 {
                Button {
                    withAnimation(Theme.spring) { step -= 1 }
                } label: {
                    Text("Back")
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func advance() {
        if step < 2 {
            withAnimation(Theme.spring) { step += 1 }
        } else {
            finish()
        }
    }

    // MARK: - Step 0: welcome + name

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            MascotView(mood: .happy, size: 140)
                .scaleEffect(mascotIn ? 1 : 0.6)
                .opacity(mascotIn ? 1 : 0)
                .padding(.top, 18)

            VStack(spacing: 6) {
                Text("Hi! I'm Hilal 🌙")
                    .font(Theme.sans(28, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("You and your circle, lifting each other up —\none salah at a time.")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            nameCard
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should we call you?")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkDeep)
            TextField("Your name", text: $name)
                .font(Theme.sans(18, .semibold))
                .foregroundStyle(Theme.inkDeep)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.inkMuted.opacity(0.25), lineWidth: 1)
                        )
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Step 1: goal setting

    private var goalStep: some View {
        VStack(spacing: 22) {
            MascotView(mood: .neutral, size: 100)
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Which prayer is hardest for you?")
                    .font(Theme.sans(22, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .multilineTextAlignment(.center)
                Text("We'll make it your goal — gentle nudges,\nextra XP when you stick with it.")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ForEach(Prayer.allCases) { prayer in
                    goalRow(title: "\(prayer.emoji) \(prayer.displayName)",
                            subtitle: goalSubtitle(for: prayer),
                            isSelected: pickedGoal && hardest == prayer) {
                        hardest = prayer
                        pickedGoal = true
                    }
                }
                goalRow(title: "😌 None, really",
                        subtitle: "I'll keep my own pace",
                        isSelected: pickedGoal && hardest == nil) {
                    hardest = nil
                    pickedGoal = true
                }
            }
        }
    }

    private func goalSubtitle(for prayer: Prayer) -> String {
        switch prayer {
        case .fajr: return "Those early mornings…"
        case .dhuhr: return "Busy middle of the day"
        case .asr: return "The afternoon slips by"
        case .maghrib: return "Right at dinnertime"
        case .isha: return "Sleep wins sometimes"
        }
    }

    private func goalRow(title: String, subtitle: String,
                         isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { action() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.sans(16, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Text(subtitle)
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.green : Theme.inkMuted.opacity(0.35))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Theme.greenSoft.opacity(0.6) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Theme.green.opacity(0.6) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: permissions

    private var permissionsStep: some View {
        VStack(spacing: 22) {
            MascotView(mood: .happy, size: 100)
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Two quick things")
                    .font(Theme.sans(22, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("So prayer times are right and you never miss one.")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            permissionsCard
        }
    }

    private var permissionsCard: some View {
        VStack(spacing: 14) {
            OnboardingPermissionRow(
                icon: "location.fill",
                tint: Theme.qadaBlue,
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
        return "Or we'll use \(state.settings.locationName) for now"
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
        s.hardestPrayer = hardest          // seeds the goal3 challenge
        s.hasOnboarded = true
        state.settings = s                 // single write: didSet persists + refreshes
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
                        .font(Theme.sans(16, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Text(subtitle)
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: granted ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(granted ? Theme.green : Theme.inkMuted.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: granted)
    }
}
