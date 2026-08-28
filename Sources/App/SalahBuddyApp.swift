import SwiftUI

@main
struct SalahBuddyApp: App {
    /// v4 §6: APNs hands its device token to a `UIApplicationDelegate` and
    /// nowhere else, and foreground presentation is a delegate decision too.
    /// `AppDelegate` does those two things and nothing more — local
    /// notifications stay `NotificationManager`'s.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// v5 §2: move Documents into the App Group container BEFORE anything reads
    /// a file.
    ///
    /// This is the earliest hook there is, and it has to be. `AppState()` loads
    /// the profile and the logs in its own initialiser, and `CircleStack.start`
    /// — which is otherwise THE launch sequence — runs long after both objects
    /// exist. The two `@StateObject` initialisers below are `@autoclosure`, so
    /// neither has run yet when this does.
    ///
    /// Idempotent and marker-guarded, so this is one `UserDefaults` read on
    /// every launch after the first, and the whole move exactly once. A build
    /// with no container (see `Store.directory`) does nothing at all here.
    init() {
        SharedContainer.prepareOnLaunch()
    }

    @StateObject private var state = AppState()
    /// v4: the session and the circle it belongs to. They are created together
    /// because the service binds to the session (`CircleService(auth:)`), and
    /// owning both in one `@StateObject` keeps that binding a single line —
    /// see `CircleStack`.
    @StateObject private var circles = CircleStack()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(circles)
                .environmentObject(circles.auth)
                .environmentObject(circles.circle)
                .task { await circles.start(host: state) }
                .onOpenURL { url in
                    // Google's OAuth callback returns through the app's
                    // reversed-client-id scheme (Info.plist CFBundleURLTypes).
                    circles.auth.handleOpenURL(url)
                }
        }
    }
}

// MARK: - The v4 service stack

/// Owns `AuthService` and `CircleService` as one unit.
///
/// Two objects, one owner, for a boring reason: `CircleService(auth:)` needs
/// the `AuthService` instance at init time, and two sibling `@StateObject`s
/// can't refer to each other in their property initializers. Doing it in the
/// App's own `init` would work, but this keeps the App declaration as plain as
/// it was in v3.9 — and it gives launch sequencing (`restore()` before
/// `bootstrap()`, which is not optional) one honest home.
@MainActor
final class CircleStack: ObservableObject {
    let auth: AuthService
    let circle: CircleService
    /// v4 §6. The shared instance, because the other call sites that fire a
    /// push (a post that finished uploading, the nudge chip) reach it as
    /// `PushRegistrar.shared` — one registrar, one device row, one token.
    let push: PushRegistrar

    /// SwiftUI may run the launch task more than once across a scene's life;
    /// signing in and pulling a circle twice is harmless but pointless.
    private var started: Bool = false

    init() {
        let auth = AuthService()
        self.auth = auth
        self.circle = CircleService(auth: auth)
        self.push = PushRegistrar.shared
    }

    /// Called once, from the root view's `.task`. THE launch sequence.
    ///
    /// Order matters at every step: the session has to be restored before "who
    /// is signed in" has an answer, `CircleService.bootstrap()` is documented
    /// to run after it, and the sync engine's channel must not be opened before
    /// either (see the note inside).
    func start(host: AppState) async {
        guard !started else { return }
        started = true

        circle.host = host
        // Apple hands over `fullName` on the FIRST authorization and never
        // again. `AuthService` only offers it when the local profile has no
        // name, and this is what makes the offer stick.
        auth.onDisplayName = { [weak host] name in
            host?.setName(name)
        }

        // v4 Phase C FIX: the sync engine's launch belongs in THIS sequence.
        // It used to be started from a second, independent `.task` on
        // `RootView`, and two `.task`s have no order between them — so on some
        // launches the engine opened its realtime channel before
        // `auth.restore()` had put the session back, joined a channel that
        // received nothing, and (because a failed join was never noticed) left
        // realtime dead for the rest of the session. One sequence, one order.
        //
        // BUILT and handed over before the first await, though: `AppState`
        // mirrors every log through this object, and a prayer logged in the
        // first second of launch should be queued rather than dropped.
        let sync: CircleSync = circle.ensureSync()
        host.attachCircleSync(sync)
        // AFTER `ensureSync()`, which is where `joinWeekBackfill` is wired —
        // and it takes the engine, because a push ARRIVING is news for the sync
        // layer and nothing else.
        adoptPushHooks(sync: sync)

        await auth.restore()
        await circle.bootstrap()
        // A cold install signing back into an existing circle has no mirror to
        // bootstrap from, so the membership only exists server-side until
        // something asks. This is that something.
        if circle.phase == .noCircle {
            await circle.refresh()
        }
        await syncProfileIfNeeded()
        // Now that "who is signed in" has an answer: adopt the network monitor,
        // drain whatever last session's flight left queued, reconcile, and open
        // the channel.
        await sync.start()
        // LAST, deliberately. `PushRegistrar.refresh` can put a system
        // permission sheet on screen, and nothing above should wait behind a
        // person deciding. It is also the step that needs everything above to
        // have happened: whether to ask at all is "is there a real circle",
        // which only the restored session and the bootstrapped mirror know.
        await refreshPush()
    }

    /// The app came back to the foreground. Called from `RootView`'s
    /// `scenePhase` handler — which used to reach past this and pull the circle
    /// itself, leaving the profile half of the job with no caller at all.
    ///
    /// Both halves are offline-safe: a pull that fails leaves the mirror
    /// exactly as it was, and a profile write that fails is retried next time.
    func handleForeground() async {
        if circle.snapshot.hasCircle {
            await circle.refresh()
        }
        // NOT inside the `hasCircle` guard: someone who signed in on a train
        // and then fixed their name in Settings has a `profiles` row to repair
        // whether or not they have joined anything yet.
        await syncProfileIfNeeded()
        // Also outside it, and for a similar reason: this is the moment a
        // circle joined on another phone, a permission granted in system
        // Settings, or a toggle flipped since launch reaches the `devices` row.
        // It costs nothing when nothing has changed (see `RemoteDevice`'s
        // fingerprint) and nothing at all for a solo user.
        await refreshPush()
    }

    // MARK: - Push (SPEC-V4 §6)

    /// Tell the registrar who we are and whether there is a real circle. It
    /// decides everything else — including asking for permission, which it will
    /// not do for a solo user (§1).
    private func refreshPush() async {
        await push.refresh(userID: auth.userID, hasCircle: circle.snapshot.hasCircle)
    }

    /// The two moments `CircleService` already has a hook for, which are also
    /// the two moments push cares about — plus the third direction, which is
    /// push telling the app something rather than the other way round.
    ///
    /// Wrapping rather than replacing: both hooks are already wired to
    /// something that matters (the week backfill, the sign-out itself), and a
    /// hook that some later reader assumes is free is a hook that quietly
    /// unwires a feature.
    private func adoptPushHooks(sync: CircleSync) {
        let push: PushRegistrar = self.push

        // v4 §6, the RECEIVING side. `AppDelegate` reads the `kind` off an
        // arriving payload and nothing else; this is where that becomes an
        // action, and the action is the one realtime already takes — pull
        // sooner. It matters most for a JOIN: `circle_members` is deliberately
        // outside the realtime publication and outside the cheap delta, so this
        // push is the only thing that can tell a phone already sitting open
        // that somebody walked in.
        //
        // `weak`, because `PushRegistrar.shared` lives as long as the process
        // and the engine belongs to `CircleService`. A strong capture would
        // make a global a second owner of it — harmless today, and exactly the
        // retain that outlives whoever changes that ownership later.
        push.onRemoteNotification = { [weak sync] kind in
            sync?.signalArrived(CircleSyncSignal.forPush(kind))
        }

        // Sign-out has to take this device's `devices` row with it, and it can
        // only do that while the session that owns the row still exists —
        // hence BEFORE the handler that ends it. See `PushRegistrar.unregister`
        // for what a row left behind would do to the next person to sign in on
        // this phone.
        let signOut: (() async -> Void)? = circle.signOutHandler
        circle.signOutHandler = {
            await push.unregister()
            await signOut?()
        }

        // Entering a circle is the FIRST moment §1 allows a friend-activity
        // permission prompt, and joining is the moment §6's "member joined"
        // push has something to say.
        let backfill: ((RemoteCircle, CircleService.CircleEntry) async -> Void)? = circle.joinWeekBackfill
        circle.joinWeekBackfill = { [weak self] circleRow, entry in
            await backfill?(circleRow, entry)
            guard let self else { return }
            // NOT awaited: this closure runs inside `createCircle`/`joinCircle`,
            // whose spinner is on screen, and a permission sheet plus a notify
            // round trip do not belong in front of the moment someone's circle
            // appears.
            Task { await self.circleEntered(entry) }
        }
    }

    private func circleEntered(_ entry: CircleService.CircleEntry) async {
        // FIRST, and not only because a new circle is the first moment §1 lets
        // us ask for permission: this is also what tells the registrar who it
        // is and that it is somewhere real, and `announceJoin` refuses to send
        // without that.
        await refreshPush()
        // Only `.joined`: a circle you just created has nobody in it to tell,
        // and `notify`'s join lease is one-per-member-per-circle — spending it
        // on an empty room would be spending it for nothing.
        guard entry == .joined else { return }
        await push.announceJoin()
    }

    /// The profile mirror is deliberately non-fatal at sign-in (§1: it must not
    /// strand someone halfway), and it is also the only thing that carries a
    /// name edited AFTER signing in. `AuthService` decides whether there is
    /// anything to send, so this costs no request when nothing has changed.
    private func syncProfileIfNeeded() async {
        guard let userID: UUID = auth.userID else { return }
        await auth.syncProfileIfNeeded(userID: userID)
    }
}

// MARK: - AppState as the circle's host

/// The whole surface `CircleService` is allowed to touch (see
/// `CircleServiceHost`): a mirror to render, and the mode to render it in.
/// `applyCircleSnapshot` already lives on `AppState`; this adds the other half.
///
/// Note what is NOT here — logs, XP, streaks, photos. §2 promises that leaving
/// a circle keeps all local history, and the cheapest way to keep a promise is
/// to leave no door through which it could be broken.
extension AppState: CircleServiceHost {
    func setCircleMode(_ mode: CircleMode) {
        // `settings`' didSet persists, refreshes and re-applies the
        // time-travel policy, so an unchanged write is a wasted full refresh.
        guard settings.circleMode != mode else { return }
        settings.circleMode = mode
    }
}
