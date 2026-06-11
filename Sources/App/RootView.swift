import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    /// 1-second heartbeat: drives countdowns and detects day rollover.
    @State private var now = AppClock.now
    @State private var lastDayKey = AppClock.dayKey(for: AppClock.now)

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if state.settings.hasOnboarded {
                tabShell
            } else {
                OnboardingView()
            }
        }
        .environment(\.appNow, now)
        .onReceive(ticker) { _ in
            now = AppClock.now
            let key = AppClock.dayKey(for: now)
            if key != lastDayKey {
                lastDayKey = key
                state.refresh()      // new schedule + streak reconcile
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                state.refresh()
                NotificationManager.shared.reschedule()
            }
        }
    }

    private var tabShell: some View {
        TabView {
            HomeView()
                .tabItem { Label("Today", systemImage: "house.fill") }
            LeagueView()
                .tabItem { Label("League", systemImage: "trophy.fill") }
            StatsView()
                .tabItem { Label("Journey", systemImage: "map.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.green)
    }
}

// MARK: - Live "now" for countdowns

/// The RootView heartbeat publishes AppClock.now into the environment each
/// second; feature views read it to render live countdowns without their own
/// timers: `@Environment(\.appNow) var now`.
private struct AppNowKey: EnvironmentKey {
    static let defaultValue: Date = AppClock.now
}

extension EnvironmentValues {
    var appNow: Date {
        get { self[AppNowKey.self] }
        set { self[AppNowKey.self] = newValue }
    }
}
