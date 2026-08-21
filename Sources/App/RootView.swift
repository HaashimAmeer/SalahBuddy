import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var state: AppState
    /// v4: only for the foreground work below — every circle screen reads
    /// `AuthService`/`CircleService` from the environment itself.
    @EnvironmentObject private var circles: CircleStack
    @Environment(\.scenePhase) private var scenePhase

    /// 1-second heartbeat: drives countdowns and detects day rollover.
    @State private var now = AppClock.now
    @State private var lastDayKey = AppClock.dayKey(for: AppClock.now)

    /// v3.7: selection is programmatic so the guided tour can walk the tabs.
    @State private var selectedTab = 0
    @State private var tourFrames: [String: CGRect] = [:]

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if state.settings.hasOnboarded {
                tabShell
            } else {
                OnboardingView()
            }

            // v3.6: "X just joined!" celebration — shown once, whatever tab
            // is up, the first time the app opens after someone accepts.
            if state.settings.hasOnboarded,
               let newName = state.profile.pendingNewMemberName {
                NewMemberCelebration(name: newName)
                    .zIndex(20)
            }

            // v3.7: guided first-run tour — spotlights real UI across the
            // tabs and ends back on Today.
            if let step = state.tutorialStep, state.settings.hasOnboarded {
                TutorialOverlay(stepIndex: step,
                                frames: tourFrames,
                                solo: state.isSoloMode,
                                onNext: { advanceTour(from: step) },
                                onSkip: { withAnimation(Theme.spring) { state.endTutorial() } })
                    .zIndex(30)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: state.profile.pendingNewMemberName)
        .animation(Theme.spring, value: state.tutorialStep)
        .environment(\.appNow, now)
        .onPreferenceChange(TutorialFramesKey.self) { tourFrames = $0 }
        .onAppear { maybeStartTour() }
        .onChange(of: state.settings.hasOnboarded) { _, onboarded in
            if onboarded { maybeStartTour() }
        }
        .onChange(of: state.tutorialStep) { _, step in
            guard let step, Tour.steps.indices.contains(step) else { return }
            withAnimation(Theme.spring) { selectedTab = Tour.steps[step].tab }
        }
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
                // v4: the circle may have moved on someone else's phone while
                // we were away, and a profile write that failed offline is owed
                // a retry. `CircleStack` owns both halves — going straight to
                // `CircleService` here is what left the profile half unwired.
                Task { await circles.handleForeground() }
            }
        }
    }

    private var tabShell: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Today", systemImage: "house.fill") }
                .tag(0)
            CircleView()
                .tabItem { Label("Circle", systemImage: "person.2.fill") }
                .tag(1)
            StatsView()
                .tabItem { Label("Journey", systemImage: "map.fill") }
                .tag(2)
            DhikrView()
                .tabItem { Label("Dhikr", systemImage: "hands.sparkles.fill") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.green)
        // v3.7: only publish tutorial target frames while the tour runs — see
        // tutorialTarget(_:). Keeps scrolling smooth the rest of the time.
        .environment(\.tutorialActive, state.tutorialStep != nil)
    }

    /// First run after onboarding (or after an update, for existing installs
    /// that have never seen it) — skippable, replayable from Settings.
    private func maybeStartTour() {
        guard state.settings.hasOnboarded,
              !state.settings.hasSeenTutorial,
              state.tutorialStep == nil else { return }
        state.startTutorial()
    }

    private func advanceTour(from step: Int) {
        withAnimation(Theme.spring) {
            if step + 1 < Tour.steps.count {
                state.tutorialStep = step + 1
            } else {
                state.endTutorial()
            }
        }
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

// MARK: - Guided tour (v3.7 — design session)

/// UI elements the tour can spotlight. Feature views opt in with
/// `.tutorialTarget(...)`, which publishes their global frame up to RootView.
enum TutorialTarget: String {
    case postPhoto, earlierToday, leaderboard, challenges, journey
}

struct TutorialFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Publishes this view's global frame so the guided tour can spotlight it —
    /// but ONLY while the tour is running. Outside the tour it adds nothing, so
    /// the root isn't re-rendered on every scroll frame (perf: avoids app-wide
    /// jank from continuous global-frame preference churn).
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        modifier(TutorialTargetModifier(target: target))
    }
}

private struct TutorialTargetModifier: ViewModifier {
    let target: TutorialTarget
    @Environment(\.tutorialActive) private var tourActive

    func body(content: Content) -> some View {
        content.background(publisher)
    }

    @ViewBuilder
    private var publisher: some View {
        if tourActive {
            GeometryReader { geo in
                Color.clear.preference(key: TutorialFramesKey.self,
                                       value: [target.rawValue: geo.frame(in: .global)])
            }
        } else {
            Color.clear
        }
    }
}

/// True while the guided tour is on screen — flips `tutorialTarget` publishing
/// on/off so it's free when the tour isn't running.
private struct TutorialActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tutorialActive: Bool {
        get { self[TutorialActiveKey.self] }
        set { self[TutorialActiveKey.self] = newValue }
    }
}

struct TourStep {
    let tab: Int                 // 0 Today, 1 Circle, 2 Journey
    let target: TutorialTarget?  // nil → centered card, no spotlight
    let title: String
    let message: String
    /// Shown when the target isn't on screen (empty section, below the fold).
    var emptyMessage: String? = nil
    /// v3.9: copy for someone with no circle yet — same steps, same targets,
    /// but the pitch becomes STARTING a circle instead of keeping up with one.
    /// nil falls back to the copy above.
    var soloTitle: String? = nil
    var soloMessage: String? = nil
    var soloEmptyMessage: String? = nil
}

enum Tour {
    static let postPhotoIndex = 1
    static let earlierTodayIndex = 2
    static let leaderboardIndex = 3
    static let challengesIndex = 4
    static let journeyIndex = 5

    static let steps: [TourStep] = [
        TourStep(tab: 0, target: nil,
                 title: "Welcome to SalahBuddy 🌙",
                 message: "You and your circle, keeping all five prayers together — one photo at a time. Here's a quick tour of how it works.",
                 soloMessage: "All five prayers, one photo at a time — and friends to keep them with, whenever you're ready. Here's a quick tour of how it works."),
        TourStep(tab: 0, target: .postPhoto,
                 title: "Post your prayer 📸",
                 message: "When a prayer comes in, log it by snapping a quick photo — your square fills in here, next to your circle's photos as they come in live.",
                 emptyMessage: "When a prayer window is open, a camera square appears here — snap a quick photo to log it, right next to your circle's photos.",
                 soloMessage: "When a prayer comes in, log it by snapping a quick photo — it fills in right here, and it's yours to keep.",
                 soloEmptyMessage: "When a prayer window is open, a camera square appears here — snap a quick photo to log it."),
        TourStep(tab: 0, target: .earlierToday,
                 title: "Earlier today",
                 message: "Finished prayers gather here — tap one to see a timeline of who prayed and when.",
                 emptyMessage: "As the day goes on, finished prayers gather in an \"Earlier today\" list — tap any of them for a timeline of who prayed and when.",
                 soloMessage: "Finished prayers gather here — tap one to see exactly when you prayed, or make up one you missed.",
                 soloEmptyMessage: "As the day goes on, finished prayers gather in an \"Earlier today\" list — tap any of them to see when you prayed, or to make one up."),
        TourStep(tab: 1, target: .leaderboard,
                 title: "Your circle 🏆",
                 message: "Every prayer earns XP — the earlier in its window, the more. The leaderboard shows where everyone stands this week (it resets every Monday).",
                 soloTitle: "Start your circle 🤝",
                 soloMessage: "Every prayer earns XP — the earlier in its window, the more. Invite a friend from this tab and you'll both land on a weekly leaderboard that resets every Monday."),
        TourStep(tab: 1, target: .challenges,
                 title: "Group challenges 🤝",
                 message: "Take these on together — like everyone logging Fajr three days straight — and the whole circle earns bonus XP. You can create your own, too.",
                 emptyMessage: "Further down, group challenges live — take them on together for bonus XP, or create your own.",
                 soloTitle: "Challenges 🤝",
                 soloMessage: "The moment someone joins you, group challenges open up — like everyone logging Fajr three days straight — and you all earn bonus XP together."),
        TourStep(tab: 2, target: .journey,
                 title: "Your Journey 🗺️",
                 message: "Your levels, badges, and photo memories live here — and \"How scoring works\" explains the point system whenever you want it."),
        TourStep(tab: 0, target: nil,
                 title: "That's the tour!",
                 message: "Time to post your first prayer — we'll nudge you when the next one comes in 🤲"),
    ]
}

/// Full-screen spotlight overlay: dims everything, cuts a window around the
/// current step's target (when it's on screen), and explains it in a card.
/// Tap anywhere or Next to advance; Skip ends the tour.
struct TutorialOverlay: View {
    let stepIndex: Int
    let frames: [String: CGRect]
    /// v3.9: no circle yet — swaps in each step's solo copy (same steps).
    var solo: Bool = false
    let onNext: () -> Void
    let onSkip: () -> Void

    private var step: TourStep { Tour.steps[stepIndex] }
    private var isLast: Bool { stepIndex == Tour.steps.count - 1 }

    var body: some View {
        GeometryReader { geo in
            let cutout = cutoutRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                dim(cutout: cutout, size: geo.size)
                if let cutout {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.green, lineWidth: 2.5)
                        .frame(width: cutout.width, height: cutout.height)
                        .offset(x: cutout.minX, y: cutout.minY)
                }
                cardColumn(cutout: cutout, size: geo.size)
            }
            .contentShape(Rectangle())
            .onTapGesture { onNext() }
        }
        .ignoresSafeArea()
    }

    /// The spotlight rect (padded + clamped to above the tab bar), or nil
    /// when the target is missing/offscreen — then the card centers with the
    /// step's fallback copy.
    private func cutoutRect(in size: CGSize) -> CGRect? {
        guard let target = step.target,
              let frame = frames[target.rawValue],
              frame.width > 8, frame.height > 8 else { return nil }
        // v3.7: looser ring — more breathing room between the highlight and
        // the green outline (design feedback).
        let padded = frame.insetBy(dx: -14, dy: -12)
        let visibleArea = CGRect(x: 0, y: 0, width: size.width, height: size.height - 80)
        let visible = padded.intersection(visibleArea)
        guard !visible.isNull, visible.height > 60 else { return nil }
        return visible
    }

    private func dim(cutout: CGRect?, size: CGSize) -> some View {
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: size))
        if let cutout {
            path.addRoundedRect(in: cutout,
                                cornerSize: CGSize(width: 24, height: 24),
                                style: .continuous)
        }
        return path.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
    }

    /// The explainer card, anchored to the safe top (below the notch / Dynamic
    /// Island) or the safe bottom (above the tab bar) so it never clips —
    /// centered when there's no spotlight. When the spotlight sits high on
    /// screen the card drops low, and vice-versa, to avoid covering it.
    @ViewBuilder
    private func cardColumn(cutout: CGRect?, size: CGSize) -> some View {
        let insets = Self.safeInsets
        let cardLow = cutout.map { $0.midY < size.height * 0.42 } ?? false
        VStack(spacing: 0) {
            if cutout == nil {
                Spacer(minLength: 0)
                cardBody
                Spacer(minLength: 0)
            } else if cardLow {
                Spacer(minLength: 0)
                cardBody
                    .padding(.bottom, insets.bottom + 74)   // clear the tab bar
            } else {
                cardBody
                    .padding(.top, insets.top + 10)          // clear the notch
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Real device safe-area insets (the overlay itself ignores the safe area,
    /// so we read them from the key window).
    private static var safeInsets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets)
            ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }

    private var messageText: String {
        // Target defined but not spotlightable right now → fallback copy.
        let needsFallback = step.target != nil && cutoutAvailable == false
        if solo, let text = needsFallback ? (step.soloEmptyMessage ?? step.soloMessage)
                                          : step.soloMessage {
            return text
        }
        if needsFallback, let empty = step.emptyMessage {
            return empty
        }
        return step.message
    }

    private var titleText: String {
        if solo, let soloTitle = step.soloTitle { return soloTitle }
        return step.title
    }

    private var cutoutAvailable: Bool {
        guard let target = step.target, let frame = frames[target.rawValue] else { return false }
        return frame.width > 8 && frame.height > 60
    }

    private var cardBody: some View {
        VStack(spacing: 14) {
            Text(titleText)
                .font(Theme.sans(20, .bold))
                .foregroundStyle(Theme.inkDeep)
                .multilineTextAlignment(.center)
            Text(messageText)
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Step dots, onboarding-style.
            HStack(spacing: 6) {
                ForEach(Tour.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == stepIndex ? Theme.green : Theme.greenSoft)
                        .frame(width: i == stepIndex ? 18 : 7, height: 7)
                }
            }

            HStack(spacing: 12) {
                Button("Skip tour") { onSkip() }
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
                Spacer()
                Button {
                    onNext()
                } label: {
                    Text(isLast ? "Let's go! 🚀" : "Next")
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.green))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 330)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.20), radius: 22, x: 0, y: 8)
        )
        .padding(.horizontal, 24)
    }
}
