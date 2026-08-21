import SwiftUI

@main
struct SalahBuddyApp: App {
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

    /// SwiftUI may run the launch task more than once across a scene's life;
    /// signing in and pulling a circle twice is harmless but pointless.
    private var started: Bool = false

    init() {
        let auth = AuthService()
        self.auth = auth
        self.circle = CircleService(auth: auth)
    }

    /// Called once, from the root view's `.task`.
    ///
    /// Order matters: the session has to be restored before "who is signed in"
    /// has an answer, and `CircleService.bootstrap()` is documented to run
    /// after it.
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

        await auth.restore()
        await circle.bootstrap()
        // A cold install signing back into an existing circle has no mirror to
        // bootstrap from, so the membership only exists server-side until
        // something asks. This is that something.
        if circle.phase == .noCircle {
            await circle.refresh()
        }
        await syncProfileIfNeeded()
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
