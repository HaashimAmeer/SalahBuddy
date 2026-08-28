import ActivityKit
import Foundation

/// v5 §6 (P4) — the app's one line of contact with ActivityKit.
///
/// Same split as `WidgetBridge`/`WidgetSnapshotBuilder`, and for the same
/// reason: `LiveActivityPlanner` decides and this performs. Every ActivityKit
/// call in the app is in this file, so what the app can ask a Lock Screen to do
/// is one file long — and the decision behind each call is a pure function a
/// test can drive without a device that can show an activity.
///
/// **Who starts an activity.** This side does. The server cannot: a
/// push-to-start payload must carry the activity's attributes, attributes carry
/// the window's `endsAt`, and prayer times are derived on-device from
/// coordinates the backend deliberately does not hold. Any client that could
/// tell the server when the window ends is a client that is running — and a
/// running client starts its own activity without a push. The full argument,
/// with the two rejected alternatives, is in `backend/README.md` under "Who
/// starts a Live Activity". What the SERVER does is the half it can do
/// honestly: move a running activity as the circle posts, with the app closed,
/// which is what §6 wanted push for.
///
/// **The push-to-start token is still registered.** It is the input that has to
/// exist before that decision could ever be revisited, and it is the half that
/// only a real device can prove works.
///
/// **The same gap closes the activity as opens it, and it is worth stating
/// plainly because §6's wording ("ending itself when the window closes") reads
/// like a promise this file cannot keep.** `end()` is reachable from `apply()`
/// and from `endAll()`, and `apply()` runs from `AppState.publishWidgetSnapshot`
/// — so the app has to be RUNNING. Nothing schedules an end: ActivityKit takes
/// no dismissal date at request time, and `ActivityContent(state:staleDate:)`
/// only tells iOS to dim the card. So Fajr closes at 06:40, the phone is not
/// touched, nobody in the circle posts afterwards, and the Lock Screen sits on
/// "Fajr · window closed" until iOS's own ~8h/12h limits retire it. Two things
/// soften it and both are the same two that soften the START gap: the app runs
/// on every §5 quiet reload push and on every foreground, and either one ends
/// the activity through `apply()`. The server's `end` push covers the case where
/// somebody else posts after the window closed. Written up at both ends in
/// `backend/README.md` under "Who starts a Live Activity".
@MainActor
final class LiveActivityController {

    /// One controller, for the reason `PushRegistrar` is one: the call sites
    /// are scattered (every publish, sign-out, reset) and none of them should
    /// have to be handed a dependency to move a Lock Screen.
    static let shared: LiveActivityController = LiveActivityController()

    private let registrar: PushRegistrar

    init(registrar: PushRegistrar = PushRegistrar.shared) {
        self.registrar = registrar
    }

    // MARK: State

    /// The activity this process believes is on screen. Recovered from
    /// ActivityKit on first use rather than assumed — the app is relaunched all
    /// the time and an activity outlives the process that started it.
    private var activity: Activity<PrayerWindowAttributes>?

    /// The per-activity token stream, and the app-wide push-to-start stream.
    /// Cancelled and replaced with the activity they belong to; a leaked one
    /// would keep re-registering a token for an activity that is gone.
    private var updateTokenTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?

    /// The last plan this controller acted on. Nothing renders it; it is here
    /// so a developer card can, and so a test can see the decision without
    /// ActivityKit having to be real.
    private(set) var lastPlan: LiveActivityPlanner.Plan = .none

    /// Whether the person has Live Activities turned on for this app. iOS lets
    /// them off in Settings, and `Activity.request` throws when they are —
    /// asking first turns a thrown error on every publish into one check.
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: - The launch hook

    /// Adopt whatever is already running and start listening for a
    /// push-to-start token. Called once, from `CircleStack.start`.
    ///
    /// Adoption is the half that matters on a cold launch: an activity survives
    /// the app being killed, so a controller that assumed `nil` would start a
    /// SECOND activity for the same window — two countdowns on one Lock Screen,
    /// and the first one orphaned with a token the server still pushes to.
    func adoptRunningActivity() {
        if activity == nil, let existing = Activity<PrayerWindowAttributes>.activities.first {
            activity = existing
            observeUpdateToken(of: existing)
        }
        observePushToStartToken()
    }

    // MARK: - The one entry point

    /// Bring the Lock Screen in line with the file the home screen reads.
    ///
    /// Called from `AppState.publishWidgetSnapshot` — the same moment, from the
    /// same snapshot, so the two surfaces cannot disagree about a window.
    ///
    /// Fire-and-forget: nothing waits on a Lock Screen, and every path inside
    /// swallows its own failures. An activity that fails to start is a surface
    /// that is not there, which is exactly what the person had a second ago.
    func apply(snapshot: WidgetSnapshot?, now: Date) {
        let running: LiveActivityPlanner.Running? = activity.map {
            LiveActivityPlanner.Running(attributes: $0.attributes, state: $0.content.state)
        }
        let plan: LiveActivityPlanner.Plan =
            LiveActivityPlanner.plan(snapshot: snapshot, running: running, now: now)
        lastPlan = plan
        switch plan {
        case .none:
            return
        case .start(let attributes, let state):
            Task { await start(attributes: attributes, state: state) }
        case .update(let state):
            Task { await update(to: state) }
        case .end:
            Task { await end() }
        case .restart(let attributes, let state):
            Task {
                await end()
                await start(attributes: attributes, state: state)
            }
        }
    }

    /// Everything down, and the tokens with it. Sign-out, "leave the circle",
    /// and `resetAllData` — the three moments the surface would otherwise keep
    /// showing a circle that is no longer yours.
    func endAll() async {
        await end()
        // Belt and braces: `activity` is only ever ONE, but an activity
        // orphaned by a crash mid-restart would not be in it.
        for stray in Activity<PrayerWindowAttributes>.activities {
            await stray.end(nil, dismissalPolicy: .immediate)
        }
        startTokenTask?.cancel()
        startTokenTask = nil
    }

    // MARK: - Effects

    private func start(attributes: PrayerWindowAttributes,
                       state: PrayerWindowAttributes.ContentState) async {
        guard isAvailable, activity == nil else { return }
        let content = ActivityContent(state: state, staleDate: attributes.endsAtDate)
        do {
            // `.token` is what asks ActivityKit for a per-activity push token —
            // without it the server has no address for this activity and §6's
            // "fills in as the circle posts, with the app closed" is a sentence
            // about nothing.
            let started = try Activity.request(attributes: attributes,
                                               content: content,
                                               pushType: .token)
            activity = started
            observeUpdateToken(of: started)
        } catch {
            // Throws for reasons that are all ordinary: the person turned Live
            // Activities off between the check above and here, the app is in a
            // state iOS will not start one from, or the system's per-app limit
            // is reached. None of them is worth surfacing.
            activity = nil
        }
    }

    private func update(to state: PrayerWindowAttributes.ContentState) async {
        guard let activity else { return }
        await activity.update(
            ActivityContent(state: state, staleDate: activity.attributes.endsAtDate))
    }

    private func end() async {
        updateTokenTask?.cancel()
        updateTokenTask = nil
        guard let activity else { return }
        self.activity = nil
        // `.after` rather than `.immediate`: the window closing is the moment
        // somebody might glance down and want to see how the circle finished.
        // Five minutes, matching `LIVE_ACTIVITY_DISMISSAL_SECONDS` on the
        // server so a locally-ended and a push-ended activity behave the same.
        await activity.end(nil, dismissalPolicy: .after(AppClock.now.addingTimeInterval(
            LiveActivityController.dismissalDelay)))
        // The row is dead the moment the activity is. Not owed and not retried
        // — the sweep collects a missed one within twelve hours.
        if let token: String = lastRegisteredUpdateToken {
            lastRegisteredUpdateToken = nil
            await registrar.forgetLiveActivityToken(token)
        }
    }

    /// Matches `LIVE_ACTIVITY_DISMISSAL_SECONDS` in
    /// `backend/supabase/functions/notify/handlers.ts`.
    static let dismissalDelay: TimeInterval = 5 * 60

    // MARK: - Tokens

    private var lastRegisteredUpdateToken: String?

    /// The per-activity token. ActivityKit hands it over ASYNCHRONOUSLY, some
    /// time after `request` returns, and re-emits it whenever it rotates — so
    /// this is a stream and not a property, and the registrar de-duplicates by
    /// fingerprint rather than this file trying to.
    private func observeUpdateToken(of activity: Activity<PrayerWindowAttributes>) {
        updateTokenTask?.cancel()
        let attributes: PrayerWindowAttributes = activity.attributes
        let activityID: String = activity.id
        updateTokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard let self else { return }
                let token: String = PushRegistrar.hexToken(from: tokenData)
                self.lastRegisteredUpdateToken = token
                await self.registrar.registerLiveActivityToken(
                    LiveActivityRegistration(
                        token: token,
                        kind: .update,
                        activityID: activityID,
                        dayKey: attributes.dayKey,
                        prayer: attributes.prayer,
                        endsAt: attributes.endsAtDate,
                        environment: APNsEnvironment.current,
                        // Read here rather than cached, exactly as
                        // `writeDeviceRow` does: this is a moment the phone may
                        // have moved, and the server filters on it.
                        utcOffset: AppClock.utcOffsetSeconds))
            }
        }
    }

    /// The app-wide push-to-start token (§6).
    ///
    /// Registered, and — today — never spent: see the type comment and
    /// `backend/README.md`. It is stored because it is the one input a
    /// server-side start would need that a client cannot supply later, and
    /// because the registration path is the half only a real device proves.
    private func observePushToStartToken() {
        guard startTokenTask == nil else { return }
        startTokenTask = Task { [weak self] in
            for await tokenData in Activity<PrayerWindowAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                await self.registrar.registerLiveActivityToken(
                    LiveActivityRegistration(
                        token: PushRegistrar.hexToken(from: tokenData),
                        kind: .start,
                        activityID: nil,
                        dayKey: nil,
                        prayer: nil,
                        endsAt: nil,
                        environment: APNsEnvironment.current,
                        utcOffset: AppClock.utcOffsetSeconds))
            }
        }
    }
}
