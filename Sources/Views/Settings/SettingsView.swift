import SwiftUI
import UserNotifications
import UIKit
import PhotosUI
import CoreLocation

/// Settings tab (v3.6 rehaul) — a proper profile section (photo + name) up
/// top, then the occasional controls: breaks & travel (moved here from Today),
/// prayer-time calculation, location (editable when not using the device),
/// notification options, About, and a DEBUG developer section.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    // v4: the developer card is where demo and real circles are told apart,
    // and where an account is signed out again.
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var circleService: CircleService
    @Environment(\.scenePhase) private var scenePhase

    @State private var name: String = ""
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showDeniedAlert = false
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    profileCard
                    BreakAndTravelCard()
                    calculationCard
                    locationCard
                    notificationsCard
                    aboutCard
                    // v3.6: dev tools ship in DEBUG *and* TestFlight (so
                    // testers can time-travel / seed demo data), but auto-hide
                    // in a real App Store release — same binary, gated by the
                    // sandbox receipt at runtime.
                    if BuildEnv.showsDeveloperTools {
                        developerCard
                    }
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
        .padding(.top, 16)
    }

    // MARK: - Profile (v3.6: photo + name, more customizable)

    @State private var avatarItem: PhotosPickerItem?

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Profile", symbol: "person.fill", color: Theme.green)

            HStack(spacing: 14) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    avatarView
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your name")
                        .font(Theme.sans(12, .bold))
                        .foregroundStyle(Theme.inkMuted)
                    TextField("Your name", text: $name)
                        .font(Theme.sans(17, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.bg)
                        )
                        .onSubmit { commitName() }
                        .onChange(of: name) { _, _ in commitName() }
                }
            }

            // v3.9: solo users have no circle to be seen by yet.
            Text(state.isSoloMode
                 ? "Your name and photo go on your posts — and are what your circle will see once you add friends."
                 : "Your name and photo are what your circle sees.")
                .font(Theme.sans(11.5, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // v3.8: onboarding answers are editable here (design session).
            VStack(alignment: .leading, spacing: 8) {
                Text("You are")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 8) {
                    genderChip(nil, "Prefer not to say", "🌙")
                    genderChip("brother", "Brother", "🧔🏽‍♂️")
                    genderChip("sister", "Sister", "🧕")
                }
            }

            HStack {
                Text("Hardest prayer")
                    .font(Theme.sans(12, .bold))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Picker("Hardest prayer", selection: hardestBinding) {
                    Text("None").tag(Prayer?.none)
                    ForEach(Prayer.allCases) { p in
                        Text("\(p.emoji) \(p.displayName)").tag(Prayer?.some(p))
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.green)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    state.setAvatar(image)
                }
                avatarItem = nil
            }
        }
    }

    /// Gender chip — updates `settings.memberKind` (tailors break copy, Jumma).
    private func genderChip(_ value: String?, _ label: String, _ emoji: String) -> some View {
        let selected = state.settings.memberKind == value
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            var s = state.settings
            s.memberKind = value
            state.settings = s
        } label: {
            VStack(spacing: 3) {
                Text(emoji).font(.system(size: 20))
                Text(label)
                    .font(Theme.sans(10.5, selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Theme.inkDeep : Theme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? Theme.greenSoft : Theme.bg,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.green : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var hardestBinding: Binding<Prayer?> {
        Binding(
            get: { state.settings.hardestPrayer },
            set: { newValue in
                var s = state.settings
                s.hardestPrayer = newValue
                state.settings = s
            }
        )
    }

    /// 72-pt avatar: the chosen photo, or a soft placeholder. A little pencil
    /// badge signals it's editable.
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let filename = state.profile.avatarFilename,
                   let image = PhotoStore.load(filename) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Theme.greenSoft)
                        Image(systemName: "person.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.green.opacity(0.7))
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.green.opacity(0.4), lineWidth: 1.5))

            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.green)
                .background(Circle().fill(Theme.surface).padding(2))
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

    @State private var cityQuery = ""
    @State private var isGeocoding = false
    @State private var geocodeError: String?

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

            // v3.6: the fixed location is finally editable (it was hard-coded).
            if !state.settings.useDeviceLocation {
                HStack(spacing: 8) {
                    TextField("City, e.g. Seattle", text: $cityQuery)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.bg)
                        )
                        .onSubmit { searchCity() }
                    Button {
                        searchCity()
                    } label: {
                        Group {
                            if isGeocoding {
                                ProgressView().tint(.white)
                            } else {
                                Text("Set")
                                    .font(Theme.sans(14, .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 52, height: 36)
                        .background(Capsule().fill(Theme.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(isGeocoding || cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let geocodeError {
                    Text(geocodeError)
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.amber)
                }
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

    /// Forward-geocode the typed city into the fixed coordinates.
    private func searchCity() {
        let query = cityQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isGeocoding else { return }
        isGeocoding = true
        geocodeError = nil
        CLGeocoder().geocodeAddressString(query) { placemarks, _ in
            Task { @MainActor in
                isGeocoding = false
                guard let placemark = placemarks?.first,
                      let location = placemark.location else {
                    geocodeError = "Couldn't find \"\(query)\" — try a bigger city nearby."
                    return
                }
                var s = state.settings
                s.fixedLatitude = location.coordinate.latitude
                s.fixedLongitude = location.coordinate.longitude
                s.locationName = placemark.locality ?? placemark.name ?? query
                state.settings = s     // didSet persists + refreshes + reschedules
                cityQuery = ""
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Reminders", symbol: "bell.fill", color: Theme.gold)

            Toggle(isOn: notificationsBinding) {
                Text("Notifications")
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
            } else if state.settings.notificationsEnabled {
                // v3.6: each kind is its own choice (design session). Prayer
                // nudges stay available to disable, but defaulting them off
                // would kind of defeat the purpose.
                Divider()
                notifOption(title: "When a prayer comes in",
                            subtitle: "The moment each window opens",
                            isOn: subToggle(\.notifyPrayerStart))
                notifOption(title: "Last call",
                            subtitle: "30 minutes before a window closes",
                            isOn: subToggle(\.notifyLastCall))
                // v3.9: nothing to ping about with an empty circle — hide the
                // row rather than offer a toggle that can never fire.
                if !state.isSoloMode {
                    notifOption(title: "Friend activity",
                                subtitle: "When someone in your circle posts first",
                                isOn: subToggle(\.notifyFriendActivity))
                }
            } else {
                Text(state.isSoloMode
                     ? "A nudge the moment each prayer comes in, and a last call before it closes."
                     : "A nudge the moment each prayer comes in, a last call before it closes, and optional friend activity.")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func notifOption(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text(subtitle)
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .tint(Theme.green)
    }

    /// Binding into one of the notification sub-flags (didSet reschedules).
    private func subToggle(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                var s = state.settings
                s[keyPath: keyPath] = newValue
                state.settings = s
            }
        )
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

            Divider()

            // v3.7: the guided first-run tour, replayable any time.
            Button {
                state.startTutorial()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.green)
                    Text("Replay the tour")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .buttonStyle(.plain)

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

    // MARK: - Developer (DEBUG + TestFlight)

    private var developerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Developer", symbol: "wrench.and.screwdriver.fill", color: Theme.inkMuted)

            Text("Test-build tools — these won't appear in the public App Store release.")
                .font(Theme.sans(11.5, .semibold))
                .foregroundStyle(Theme.inkMuted)

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
                .disabled(!timeTravelEnabled)
                .opacity(timeTravelEnabled ? 1 : 0.4)

                Text(timeTravelEnabled ? offsetDescription : timeTravelPausedNote)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            circleDeveloperSection

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

    /// v4: a real circle pins the clock to real time (SPEC-V4 §3) —
    /// `AppClock.offset` refuses to move anyway; reading the mode here keeps
    /// the row greyed out in step with SwiftUI's invalidation of `settings`.
    private var timeTravelEnabled: Bool { state.settings.circleMode == .demo }

    /// The guard is keyed on the MODE, not on having a circle, and deliberately
    /// so: flipping the row above into real-circle mode pins the clock straight
    /// away, which is what stops the circle you create NEXT from being stamped
    /// with a fictional `joined_at`. The note names whichever of the two is
    /// holding it, instead of claiming a circle that may not exist yet.
    private var timeTravelPausedNote: String {
        if inRealCircle {
            return "Paused while you're in a real circle — your friends see real timestamps."
        }
        return "Paused while real-circle mode is on — a travelled clock would stamp fictional times on the circle you join next."
    }

    private var offsetDescription: String {
        let offset = AppClock.offset
        guard offset != 0 else { return "Clock is real time" }
        let hours = Int(offset) / 3600
        let minutes = (Int(offset) % 3600) / 60
        return "Clock offset: +\(hours)h \(minutes)m → now \(AppClock.now.formatted(.dateTime.month().day().hour().minute()))"
    }

    // MARK: - Developer: circles (v4)

    /// SPEC-V4 §2: the simulator survives here as "Demo circle", and it is
    /// mutually exclusive with a real one — so the row is a switch between two
    /// worlds, disabled while the real one is occupied.
    private var circleDeveloperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Circle")
                .font(Theme.sans(14, .heavy))
                .foregroundStyle(Theme.inkMuted)

            Toggle(isOn: demoCircleBinding) {
                Text("Demo circle")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
            }
            .tint(Theme.green)
            .disabled(inRealCircle)

            Text(demoCircleNote)
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            accountSection
        }
    }

    private var inRealCircle: Bool { circleService.snapshot.hasCircle }

    private var demoCircleBinding: Binding<Bool> {
        Binding(
            get: { state.settings.circleMode == .demo },
            set: { isOn in
                // Belt and braces: the row is already disabled here, and a
                // circle you are actually in must not be swapped out from
                // under the grid it is drawing.
                guard !circleService.snapshot.hasCircle else { return }
                state.settings.circleMode = isOn ? .demo : .real
            })
    }

    private var demoCircleNote: String {
        if inRealCircle {
            return "Off while you're in a real circle — the two can't run at once. Leave the circle and the simulated friends come back."
        }
        if state.settings.circleMode == .demo {
            return "Simulated friends fill the grid and the leaderboard. Nothing about them leaves this phone."
        }
        return "The simulated friends are put away — your circle is whoever is really in it."
    }

    // MARK: - Developer: account (v4)

    @ViewBuilder
    private var accountSection: some View {
        if auth.isSignedIn {
            VStack(alignment: .leading, spacing: 8) {
                Text(signedInLine)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text("You'll stay in your circle — sign back in on any phone and it's there. Your streak, XP and photos stay on this one either way.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await signOut() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(auth.isWorking ? "Signing out…" : "Sign out")
                    }
                    .font(Theme.sans(15, .bold))
                    .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .disabled(auth.isWorking)
            }
        } else {
            Text("Not signed in. The Circle tab is where a real circle starts.")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signedInLine: String {
        let name: String = state.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Signed in" }
        return "Signed in as \(name)"
    }

    /// Signing out is not a reset: `signOutAndReset` drops the session and the
    /// circle mirror, and cannot reach a log, a streak or an XP total.
    @MainActor
    private func signOut() async {
        await circleService.signOutAndReset()
    }

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

// MARK: - Breaks & travel (v3.6 — moved here from Today)

/// Two simple toggles in one card: "Can't pray right now" (starts/ends a
/// break) and "Traveling" (combine Dhuhr+Asr / Maghrib+Isha). Both are
/// occasional and change how prayers are visualized — same toggle shape, one
/// consistent home. Turning the break OFF asks WHEN you started praying again
/// (ResumeSheet), so a forgotten day still logs correctly.
struct BreakAndTravelCard: View {
    @EnvironmentObject private var state: AppState

    @State private var showResume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.lilac)
                Text("Breaks & travel")
                    .font(Theme.sans(18, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer()
            }

            Toggle(isOn: breakBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isOnBreak ? "On a break — streak safe" : "Can't pray right now")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    // v3.9: the "resting" reassurance is about what the circle
                    // sees — solo, it's just about your own days.
                    Text(state.isOnBreak
                         ? (state.isSoloMode
                            ? "Your days just show a gentle \"resting\" — no misses. Turn off to resume."
                            : "Your circle just sees a gentle \"resting\". Turn off to resume.")
                         : "Pauses everything — your streak stays safe until you resume.")
                        .font(Theme.sans(11.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.lilac)

            Divider()

            Toggle(isOn: travelBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isTraveling ? "Traveling — prayers combined" : "Traveling")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    Text("Combine Dhuhr+Asr and Maghrib+Isha (jam').")
                        .font(Theme.sans(11.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .tint(Theme.qadaBlue)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .sheet(isPresented: $showResume) {
            ResumeSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
        }
    }

    /// On → start a break immediately (no reason picker). Off → open the
    /// ResumeSheet; `isOnBreak` stays true until they actually resume, so the
    /// toggle correctly snaps back on if they dismiss without resuming.
    private var breakBinding: Binding<Bool> {
        Binding(
            get: { state.isOnBreak },
            set: { newValue in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if newValue {
                    withAnimation(Theme.spring) { state.startBreak() }
                } else {
                    showResume = true
                }
            }
        )
    }

    private var travelBinding: Binding<Bool> {
        Binding(
            get: { state.isTraveling },
            set: { newValue in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(Theme.spring) { state.setTraveling(newValue) }
            }
        )
    }
}
