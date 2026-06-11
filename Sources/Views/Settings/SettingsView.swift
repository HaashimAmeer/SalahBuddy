import SwiftUI
import UserNotifications
import UIKit

/// Settings tab — profile name, prayer-time calculation, location,
/// notifications (incl. denied state), excused-days counter, About, and a
/// DEBUG developer section with time-travel controls. Styled per SPEC-V2 §2.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var name: String = ""
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showDeniedAlert = false
    @State private var showResetConfirm = false
    @State private var showScoring = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    profileCard
                    calculationCard
                    locationCard
                    notificationsCard
                    aboutCard
                    #if DEBUG
                    developerCard
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            name = state.profile.name
            refreshNotificationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshNotificationStatus() }
        }
        .onChange(of: state.settings.calcMethod) { _, _ in
            NotificationManager.shared.reschedule()
        }
        .onChange(of: state.settings.madhab) { _, _ in
            NotificationManager.shared.reschedule()
        }
        .onChange(of: state.settings.useDeviceLocation) { _, _ in
            NotificationManager.shared.reschedule()
        }
        .alert("Notifications are off", isPresented: $showDeniedAlert) {
            Button("Open Settings") { openSystemSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("SalahBuddy needs permission to remind you. Enable notifications in the system Settings app.")
        }
        .confirmationDialog("Reset all data?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset everything", role: .destructive) {
                state.resetAllData()
                NotificationManager.shared.cancelAll()
                name = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logs, XP, streak, and badges will be erased. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(Theme.sans(30, .bold))
                .foregroundStyle(Theme.inkDeep)
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.green.opacity(0.55))
                .offset(y: -6)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Profile

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Profile", symbol: "person.fill", color: Theme.green)

            TextField("Your name", text: $name)
                .font(Theme.sans(17, .semibold))
                .foregroundStyle(Theme.inkDeep)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.bg)
                )
                .onSubmit { commitName() }
                .onChange(of: name) { _, _ in commitName() }

            Divider()

            // v3.2: excused is a break MODE now — no monthly cap, just a count.
            HStack(spacing: 8) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.lilac)
                Text(state.isOnBreak ? "On a break — excused days this month" : "Excused days this month")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer()
                Text("\(state.excusedUsedThisMonth)")
                    .font(Theme.sans(15, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.lilac.opacity(0.15)))
            }

            Divider()

            // v3.2: how scoring works — the explainer from the design session.
            Button {
                showScoring = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.gold)
                    Text("How scoring works")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .sheet(isPresented: $showScoring) {
            ScoringExplainerSheet()
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != state.profile.name else { return }
        state.setName(trimmed)
    }

    // MARK: - Calculation

    private var calculationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Prayer times", symbol: "clock.fill", color: Theme.qadaBlue)

            HStack {
                Text("Method")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer()
                Picker("Method", selection: $state.settings.calcMethod) {
                    ForEach(CalcMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.green)
            }
            Text("Method only moves Fajr and Isha — Dhuhr, Asr and Maghrib are the same for every method.")
                .font(Theme.sans(11.5, .semibold))
                .foregroundStyle(Theme.inkMuted)

            VStack(alignment: .leading, spacing: 8) {
                Text("Asr madhab")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Picker("Asr madhab", selection: $state.settings.madhab) {
                    Text("Shafi (standard)").tag(AsrMadhab.shafi)
                    Text("Hanafi (later)").tag(AsrMadhab.hanafi)
                }
                .pickerStyle(.segmented)
                Text("Madhab only moves Asr — Hanafi puts it about an hour later. Check \"Today's times\" below to see changes apply.")
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: - Location

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Location", symbol: "location.fill", color: Theme.amber)

            Toggle(isOn: locationBinding) {
                Text("Use my location")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
            }
            .tint(Theme.green)

            HStack(spacing: 6) {
                Image(systemName: state.isUsingDeviceLocation ? "location.fill" : "mappin.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                Text(state.isUsingDeviceLocation
                     ? "Using device location — \(state.activeLocationName)"
                     : "Using fixed location — \(state.activeLocationName)")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            if !state.savedPlaceTags.isEmpty {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved places")
                            .font(Theme.sans(15, .semibold))
                            .foregroundStyle(Theme.inkDeep)
                        Text(state.savedPlaceTags.map { "\($0.emoji) \($0.displayName)" }
                                .joined(separator: "  "))
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Button("Forget") {
                        state.clearSavedPlaces()
                    }
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.amber)
                    .buttonStyle(.plain)
                }
                Text("Remembered the first time you tagged each place — used to auto-suggest the tag when you post nearby.")
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            Divider()

            Text("Today's times")
                .font(Theme.sans(14, .heavy))
                .foregroundStyle(Theme.inkMuted)
                .tracking(0.5)

            if let schedule = state.todaySchedule {
                VStack(spacing: 8) {
                    ForEach(schedule.windows, id: \.prayer) { window in
                        HStack {
                            Image(systemName: window.prayer.symbolName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.color(for: window.prayer))
                                .frame(width: 24)
                            Text(window.prayer.displayName)
                                .font(Theme.sans(15, .semibold))
                                .foregroundStyle(Theme.inkDeep)
                            Spacer()
                            Text(window.start, format: .dateTime.hour().minute())
                                .font(Theme.sans(15, .bold))
                                .foregroundStyle(Theme.inkDeep)
                        }
                    }
                }
            } else {
                Text("Couldn't compute prayer times for this location.")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.amber)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var locationBinding: Binding<Bool> {
        Binding(
            get: { state.settings.useDeviceLocation },
            set: { newValue in
                state.settings.useDeviceLocation = newValue
                if newValue, state.location.authorizationStatus == .notDetermined {
                    state.location.requestPermission()
                }
            }
        )
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Reminders", symbol: "bell.fill", color: Theme.gold)

            Toggle(isOn: notificationsBinding) {
                Text("Prayer notifications")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
            }
            .tint(Theme.green)

            if notificationStatus == .denied {
                Button {
                    openSystemSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Notifications are disabled in system Settings — tap to fix")
                            .font(Theme.sans(13, .bold))
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
            } else {
                Text("A nudge the moment each prayer comes in, plus a last call 30 minutes before its window closes.")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { state.settings.notificationsEnabled },
            set: { newValue in
                if newValue {
                    enableNotifications()
                } else {
                    state.settings.notificationsEnabled = false
                    NotificationManager.shared.cancelAll()
                }
            }
        )
    }

    private func enableNotifications() {
        Task {
            let status = await NotificationManager.shared.authorizationStatus()
            switch status {
            case .denied:
                showDeniedAlert = true
            case .notDetermined:
                let granted = await NotificationManager.shared.requestPermission()
                if granted {
                    state.settings.notificationsEnabled = true
                    NotificationManager.shared.reschedule()
                } else {
                    showDeniedAlert = true
                }
            default:
                state.settings.notificationsEnabled = true
                NotificationManager.shared.reschedule()
            }
            refreshNotificationStatus()
        }
    }

    private func refreshNotificationStatus() {
        Task {
            notificationStatus = await NotificationManager.shared.authorizationStatus()
            // Keep the toggle honest if permission was revoked behind our back.
            if notificationStatus == .denied, state.settings.notificationsEnabled {
                state.settings.notificationsEnabled = false
                NotificationManager.shared.cancelAll()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About", symbol: "moon.stars.fill", color: Theme.lilac)

            aboutRow(label: "App", value: "SalahBuddy")
            aboutRow(label: "Version", value: appVersion)
            aboutRow(label: "Daily XP goal", value: "\(state.settings.dailyGoal) XP")
            aboutRow(label: "Praying since", value: state.profile.joinedAt
                .formatted(.dateTime.month(.abbreviated).day().year()))

            Text("Made with 🤲 to help you keep all five, every day.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return version
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Text(value)
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.inkDeep)
        }
    }

    // MARK: - Developer (DEBUG only)

    #if DEBUG
    private var developerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Developer", symbol: "wrench.and.screwdriver.fill", color: Theme.inkMuted)

            VStack(alignment: .leading, spacing: 8) {
                Text("Time travel")
                    .font(Theme.sans(14, .heavy))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 8) {
                    timeTravelButton("+1h", seconds: 3600)
                    timeTravelButton("+6h", seconds: 6 * 3600)
                    timeTravelButton("+1d", seconds: 24 * 3600)
                    Button {
                        AppClock.offset = 0
                        state.refresh()
                        NotificationManager.shared.reschedule()
                    } label: {
                        Text("Reset")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.amber.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                Text(offsetDescription)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            Divider()

            Button {
                state.fillDemoHistory()
                NotificationManager.shared.reschedule()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("Fill 3-week demo history")
                }
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.qadaBlue)
            }
            .buttonStyle(.plain)

            Button {
                showResetConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                    Text("Reset all data")
                }
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.amber)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func timeTravelButton(_ label: String, seconds: TimeInterval) -> some View {
        Button {
            AppClock.offset += seconds
            state.refresh()
            NotificationManager.shared.reschedule()
        } label: {
            Text(label)
                .font(Theme.sans(14, .bold))
                .foregroundStyle(Theme.inkDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.bg))
                .overlay(Capsule().strokeBorder(Theme.inkMuted.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var offsetDescription: String {
        let offset = AppClock.offset
        guard offset != 0 else { return "Clock is real time" }
        let hours = Int(offset) / 3600
        let minutes = (Int(offset) % 3600) / 60
        return "Clock offset: +\(hours)h \(minutes)m → now \(AppClock.now.formatted(.dateTime.month().day().hour().minute()))"
    }
    #endif

    // MARK: - Shared bits

    private func sectionTitle(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(Theme.sans(18, .bold))
                .foregroundStyle(Theme.inkDeep)
            Spacer()
        }
    }
}

// MARK: - Scoring explainer (v3.2)

/// Plain-English walkthrough of the point system — mirrors SCORING.md.
struct ScoringExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("How scoring works ⚡")
                            .font(Theme.sans(24, .bold))
                            .foregroundStyle(Theme.inkDeep)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.inkMuted.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 18)

                    card("⏱ Pray early, earn more") {
                        row("First quarter of the window", "+30 XP", Theme.green)
                        row("Second quarter", "+20 XP", Theme.green)
                        row("Third quarter", "+15 XP", Theme.amber)
                        row("Final quarter", "+12 XP", Theme.amber)
                        row("Made up later (Qada)", "+10 XP", Theme.qadaBlue)
                    }

                    card("🎁 Bonuses") {
                        row("Perfect day — all 5 in their windows", "+25 XP", Theme.gold)
                        row("Prayed in jamaat", "+5 XP", Theme.gold)
                        row("Jumma on Friday", "+10 XP", Theme.gold)
                        row("Dhikr while on a break (up to 5/day, private)", "+5 XP", Theme.lilac)
                    }

                    card("🔥 Streaks") {
                        bullet("Log all 5 prayers in a day to extend your streak.")
                        bullet("Every 7-day streak banks a streak freeze (max 2) that covers a missed day.")
                        bullet("Breaks (\"Can't pray right now\") pause everything — your streak is safe until you resume.")
                    }

                    card("🏆 The circle") {
                        bullet("Weekly scores reset every Monday and count prayer XP + bonuses.")
                        bullet("Dhikr XP is private — it levels you up but never appears on the scoreboard.")
                        bullet("Win the weekly race and the next target gets higher.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.sans(16, .bold))
                .foregroundStyle(Theme.inkDeep)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Text(value)
                .font(Theme.sans(14, .heavy))
                .foregroundStyle(color)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•")
                .font(Theme.sans(14, .bold))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
