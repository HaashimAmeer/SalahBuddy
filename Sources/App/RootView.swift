import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var state: AppState
    /// v4: only for the foreground work below — every circle screen reads
    /// `AuthService`/`CircleService` from the environment itself.
    @EnvironmentObject private var circles: CircleStack
    @Environment(\.scenePhase) private var scenePhase

    /// Day-rollover bookkeeping. The 1-second heartbeat itself lives in
    /// `AppClockProvider` — deliberately NOT here; see the type's comment.
    @State private var lastDayKey = AppClock.dayKey(for: AppClock.now)

    /// v3.7: selection is programmatic so the guided tour can walk the tabs.
    @State private var selectedTab = 0
    @State private var tourFrames: [String: CGRect] = [:]

    var body: some View {
        AppClockProvider(onTick: handleTick) {
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
            // NOT .animation(_:value: state.tutorialStep). `advanceTour`
            // already wraps the step change in withAnimation(Theme.spring),
            // and `onChange(of:tutorialStep)` fires a THIRD withAnimation for
            // the tab switch — so one tap on Next ran three animations over
            // two values, two of them on the same one. The overlay's own
            // .transition(.opacity) is driven by the explicit withAnimation,
            // which is where the intent actually lives.
            // v4 §4: the synced mirror, so a grid tile can resolve a buddy's
            // Storage photo path without every intermediate view having to thread
            // one through. `.empty` in demo mode, which costs a tile nothing.
            .environment(\.circleMirror, state.circleSnapshot)
            .onPreferenceChange(TutorialFramesKey.self) { tourFrames = $0 }
            .onAppear { maybeStartTour() }
            .onChange(of: state.settings.hasOnboarded) { _, onboarded in
                if onboarded { maybeStartTour() }
            }
            .onChange(of: state.tutorialStep) { previous, step in
                // The tour just ended — hand the person back to Today so they
                // can actually start, instead of abandoning them on whichever
                // tab the last step happened to spotlight.
                //
                // The old seven-step tour closed with a "post your first
                // prayer" card that lived on tab 0, so this fell out for free.
                // Trimming to four steps dropped that card and, with it, the
                // only thing that returned you — the tour now finishes on the
                // Circle tab and just stops. Making the return explicit is the
                // fix; it should never have been a side effect of a step.
                if step == nil, previous != nil {
                    withAnimation(Theme.spring) { selectedTab = 0 }
                    return
                }
                guard let step, Tour.steps.indices.contains(step) else { return }
                withAnimation(Theme.spring) { selectedTab = Tour.steps[step].tab }
            }
            // The zone moved while the app was OPEN — which is the ordinary
            // case for the one feature whose entire subject is travellers:
            // land, take the phone off airplane mode, SalahBuddy already
            // foregrounded. Nothing else notices. scenePhase does not fire,
            // and until it does the schedule is still computing the departure
            // city's prayer times, the local notifications are still queued
            // against them, and `devices.utc_offset` still says the zone the
            // person left — so the server filters their pushes against a
            // clock on the other side of the world.
            //
            // refresh() is the right hammer: noteTimeZoneIfChanged sits at the
            // top of it, so the travel day gets marked in the same pass that
            // rebuilds the schedule. iOS also posts this on a DST rollover,
            // where every step below is equally wanted and the 3h threshold
            // correctly declines to call it travel.
            .onReceive(NotificationCenter.default.publisher(
                for: .NSSystemTimeZoneDidChange)) { _ in
                state.refresh()
                NotificationManager.shared.reschedule()
                Task { await circles.handleForeground() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    state.refresh()
                    NotificationManager.shared.reschedule()
                    Task { await foregroundCircleSync() }
                } else if phase == .background {
                    // v5 §3/§5-A: the moment the app leaves the screen is the
                    // moment the widget becomes the thing the person is looking
                    // at — and the only moment worth spending one of the day's
                    // ~40–70 reloads on. The file itself is already current
                    // (every mutation rewrites it); this republishes anyway
                    // because it costs nothing when nothing changed, and asks
                    // WidgetKit to come and read it.
                    state.publishWidgetSnapshot(reloadTimelines: true)
                    Task { await backgroundCircleSync() }
                }
            }
        }
    }

    /// Once a second, off `AppClockProvider`'s heartbeat. Touches `@State`
    /// only at midnight, so on every other tick it costs a comparison and
    /// invalidates nothing.
    private func handleTick(_ now: Date) {
        let key = AppClock.dayKey(for: now)
        guard key != lastDayKey else { return }
        lastDayKey = key
        state.refresh()      // new schedule + streak reconcile
        // v4 Phase C: yesterday's grid is finished and today's is empty —
        // the circle's day rolled over too.
        Task { await dayChangedCircleSync() }
    }

    // MARK: - The circle's lifecycle (v4 Phase C)

    // LAUNCH is deliberately NOT here: building the engine, handing it to
    // `AppState` and starting it are one ordered sequence with restoring the
    // session, and that sequence lives in `CircleStack.start(host:)`. A second
    // `.task` on this view ran in an undefined order against the first, which
    // is how a realtime channel came to be joined before there was a session
    // to join it with.

    /// Back to the front. Roster first, then posts: the mirror's circle id is
    /// what the post pull filters on, so a device whose membership changed on
    /// another phone learns which circle it is in before it asks what happened
    /// inside it.
    private func foregroundCircleSync() async {
        // v4: the circle may have moved on someone else's phone while we were
        // away, and a profile write that failed offline is owed a retry.
        // `CircleStack` owns both halves — going straight to `CircleService`
        // here is what left the profile half unwired.
        await circles.handleForeground()
        if let sync: CircleSync = circles.circle.sync {
            await sync.enteredForeground()
        }
        // §4: buddy photos expire with the server's ~30-day retention. The
        // download actor already sweeps every 25 fetches; this is the hook that
        // keeps the bound honest for someone who mostly reads the grid. Off the
        // main actor — it is a directory scan.
        Task.detached(priority: .utility) {
            _ = BuddyPhotoCache.sweepEverywhere()
        }
    }

    /// Gone to the back: the realtime channel closes with the app. A socket
    /// held open behind the user's back buys nothing — the next foreground
    /// catches up in one request either way.
    private func backgroundCircleSync() async {
        guard let sync: CircleSync = circles.circle.sync else { return }
        await sync.enteredBackground()
    }

    private func dayChangedCircleSync() async {
        guard let sync: CircleSync = circles.circle.sync else { return }
        await sync.dayChanged()
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

    /// v4: four steps, down from seven.
    ///
    /// Two of the removed ones explained circle features — group challenges,
    /// and a closing "post your first prayer" card — to somebody who had just
    /// installed the app and had no circle. A tour is a tax paid before any
    /// value has been received, so it should cover only what is not
    /// self-evident from the screen itself. Challenges surface on their own the
    /// moment a circle exists, the Journey tab explains itself (it owns "How
    /// scoring works"), and the old closing card restated the step before it.
    static let steps: [TourStep] = [
        TourStep(tab: 0, target: nil,
                 title: "Welcome to SalahBuddy 🌙",
                 message: "You and your circle, keeping all five prayers together — one photo at a time. Here's the quick version.",
                 soloMessage: "All five prayers, one photo at a time — and friends to keep them with, whenever you're ready. Here's the quick version."),
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
                 message: "Every prayer earns XP — the earlier in its window, the more — and the leaderboard resets every Monday. Your levels, badges and photo memories live over in Journey.",
                 soloTitle: "Start your circle 🤝",
                 soloMessage: "Every prayer earns XP — the earlier in its window, the more. Invite a friend and you'll both land on a weekly leaderboard. Your levels, badges and memories live over in Journey."),
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
            // A target taller than most of the screen cannot be "spotlit" in
            // any useful sense — dimming everything except 80% of the page
            // says nothing, and it guarantees the card lands on top of the
            // thing it is describing (the "Start your circle" step did exactly
            // that). Drop the ring and centre the card instead. Deliberately
            // NOT folded into cutoutRect: that answers "is the target on
            // screen", which is what picks the fallback copy, and an oversized
            // target is very much on screen.
            let spotlight: CGRect? = cutout.flatMap {
                $0.height > geo.size.height * 0.62 ? nil : $0
            }
            ZStack(alignment: .topLeading) {
                dim(cutout: spotlight, size: geo.size)
                if let spotlight {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.green, lineWidth: 2.5)
                        .frame(width: spotlight.width, height: spotlight.height)
                        .offset(x: spotlight.minX, y: spotlight.minY)
                }
                cardColumn(cutout: spotlight, size: geo.size)
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
    /// Put the card NEXT TO what it is describing.
    ///
    /// This used to be a binary choice — flush to the top edge or flush to the
    /// bottom edge, picked by which half of the screen the target sat in — so
    /// a target low on the page sent the card to the very top and left most of
    /// a phone's height as dead space between the explanation and the thing
    /// explained. The two were never visually connected.
    ///
    /// Now the card sits just below the spotlight when there is room, just
    /// above it when there is not, and centres only when neither side can hold
    /// it. Every offset is clamped, so an unusual target cannot push the card
    /// off screen, under the notch or behind the tab bar.
    private func cardColumn(cutout: CGRect?, size: CGSize) -> some View {
        let insets = Self.safeInsets
        let gap: CGFloat = 16
        let topLimit = insets.top + 10                  // clear the notch
        let bottomLimit = size.height - insets.bottom - 74   // clear the tab bar

        // A deliberate estimate rather than a measured height. Measuring costs
        // a layout pass to discover the size and a second to act on it, which
        // reads as the card twitching into place on every step — the exact
        // choppiness this screen is being fixed for. Both branches below
        // absorb an underestimate by growing into a flexible Spacer.
        let estimate: CGFloat = 230

        return VStack(spacing: 0) {
            if let cutout, cutout.maxY + gap + estimate <= bottomLimit {
                // Room underneath: pin the card just below the spotlight.
                Spacer().frame(height: max(topLimit, cutout.maxY + gap))
                cardBody
                Spacer(minLength: 0)
            } else if let cutout, cutout.minY - gap - estimate >= topLimit {
                // Room above: pin it just above, measured from the bottom.
                Spacer(minLength: 0)
                cardBody
                Spacer().frame(height: max(0, size.height - (cutout.minY - gap)))
            } else {
                // No cutout, or nothing fits beside it — centre.
                Spacer(minLength: 0)
                cardBody
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

// MARK: - The heartbeat

/// Publishes `AppClock.now` into the environment once a second, and — the
/// whole point — does it WITHOUT making its parent's body depend on the clock.
///
/// This used to be a `@State var now` on `RootView` itself, which meant every
/// tick invalidated `RootView.body`: the 5-tab `TabView`, the celebration and
/// the tutorial overlay were all re-evaluated once a second, forever, whether
/// or not anything on screen showed a countdown. Only a handful of Today
/// screens actually read `\.appNow`.
///
/// Here `content` is a stored value, built by the parent exactly once per
/// parent update. When `now` changes only THIS body re-runs; `content` is
/// handed back unchanged, so SwiftUI invalidates just the views that read the
/// environment value. The parent's body is not re-executed at all.
///
/// `onTick` exists so there is one timer rather than two — the day-rollover
/// check needs the same heartbeat and has no business owning its own.
private struct AppClockProvider<Content: View>: View {
    let onTick: (Date) -> Void
    @ViewBuilder let content: Content

    @State private var now = AppClock.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .environment(\.appNow, now)
            .onReceive(ticker) { _ in
                let tick = AppClock.now
                now = tick
                onTick(tick)
            }
    }
}
