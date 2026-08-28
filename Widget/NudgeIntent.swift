import AppIntents
import Foundation
import WidgetKit

/// v5 §4 (P4) — the one thing you can DO from a home screen.
///
/// §4 sets the boundary and it is narrow: the vocabulary is `Button(intent:)`,
/// `Toggle(isOn:intent:)`, a tap that deep-links, and a `ControlWidget`. No
/// scrolling, no gestures, no timers. Logging your own prayer can NOT be a
/// widget button — v2 made the photo mandatory — so the tap that would is a
/// deep link into the camera flow, and the one action that genuinely fits is
/// the nudge, which §6's `notify` has taken since v4.
///
/// **Three rules this file exists to keep.**
///
/// 1. **It never refreshes the session** (§2 tooth #3). Two processes rotating
///    one refresh token invalidate each other, and the person is signed out by
///    a button they tapped on a home screen. There is no refresh path in
///    `SharedSession` and none here: an expired token means the widget renders
///    a deep link instead of a button (`CircleWidgetView`), and `perform()`
///    re-checks in case the token died between the render and the tap.
/// 2. **The optimistic state is written into the container BEFORE returning**,
///    which is §4's own instruction: the intent runs headless, WidgetKit
///    reloads after it returns, and a tile that reloaded before the write would
///    render the state the button was tapped to change.
/// 3. **It spends `waiting[]` verbatim.** That list is already the NUDGE list
///    rather than "everyone who has not posted" — it carries the Today screen's
///    gate (`WidgetSnapshotBuilder.nudgesAllowed`: window open, thirty minutes
///    in, never the carry-over isha). Re-deciding who is late on this side is
///    two surfaces that can disagree about the same window.
struct NudgeFriendIntent: AppIntent {

    static var title: LocalizedStringResource = "Nudge a friend"
    static var description = IntentDescription(
        "Send a gentle reminder to someone in your circle who hasn't prayed yet.")

    /// Never true. The whole point of the button is that the app stays closed —
    /// §4's "the intent runs headless". The one case that DOES open the app is
    /// an expired session, and that is a `Link`, not this.
    static var openAppWhenRun: Bool = false

    /// The circle member id — `CircleMember.id`, straight out of
    /// `widget.json`'s `waiting[]`. A parameter and not a lookup, because the
    /// person tapped a specific name and the file may have been rewritten
    /// between the render and the tap.
    @Parameter(title: "Member") var memberID: String
    @Parameter(title: "Day") var dayKey: String
    @Parameter(title: "Prayer") var prayer: String

    init() {}

    init(memberID: String, dayKey: String, prayer: String) {
        self.memberID = memberID
        self.dayKey = dayKey
        self.prayer = prayer
    }

    func perform() async throws -> some IntentResult {
        await NudgeSender.send(memberID: memberID, dayKey: dayKey, prayer: prayer)
        return .result()
    }
}

/// The Control Center button (§3's table: "Nudge the circle").
///
/// One tap, everybody outstanding — which is the right verb for a control,
/// where there is no room to pick a name and no list to pick it from. It reads
/// the same `waiting[]` the medium tile does, so it can only ever reach people
/// the app itself would offer to nudge.
///
/// **§2 tooth #3, in the only vocabulary a control actually has.** Three doors
/// were shut in turn, and the comment is worth more than the code here because
/// the next person will try them in the same order:
///
/// 1. Render a `Link` when the session has expired, as the medium tile does.
///    `ControlWidgetTemplateBuilder` takes no branches — an `if`/`else` around
///    two `ControlWidgetButton`s does not compile.
/// 2. `ForegroundContinuableIntent`, whose whole job is "open the app to
///    finish this". **Unavailable in application extensions.**
/// 3. A computed `openAppWhenRun`, true exactly when the token cannot be
///    spent. Legal Swift; rejected by `appintentsmetadataprocessor`, which
///    requires a compile-time literal.
///
/// What is left is to fail LOUDLY rather than silently: the intent stays
/// headless (`openAppWhenRun = false` — a control that nudges without opening
/// anything is the point), and when it cannot authenticate it throws an error
/// carrying copy the system shows. The person is told to open the app instead
/// of tapping a button that does nothing, and the control's own label
/// (`NudgeControlProvider`) has already said as much before they touched it.
struct NudgeCircleIntent: AppIntent {

    static var title: LocalizedStringResource = "Nudge the circle"
    static var description = IntentDescription(
        "Remind everyone in your circle who hasn't prayed this window yet.")

    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        // Checked BEFORE the work, unlike `NudgeFriendIntent`'s (which has a
        // rendered `Link` to fall back on): the alternative here is a control
        // that marks four people nudged and sends nothing. NEVER refreshed,
        // only read — an expired token is the app's business, not ours.
        guard SharedSession.load()?.isFresh(at: Date()) == true else {
            throw NudgeUnavailable.signedOut
        }
        guard let snapshot: WidgetSnapshot = WidgetFile.read(),
              let window = snapshot.window else { return .result() }
        // Newest state first, and one at a time: `NudgeSender` re-reads the
        // file for each write, and the server's rate limit is per recipient
        // anyway. A whole circle is at most seven people (SPEC-V4's cap is
        // twelve members), which is a handful of small POSTs.
        for person in snapshot.circle.waiting where !person.nudgedThisWindow {
            await NudgeSender.send(memberID: person.userID,
                                   dayKey: window.dayKey,
                                   prayer: window.prayer.rawValue,
                                   reload: false)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Why a nudge could not go out, in words the system will show.
///
/// The only error either intent throws, and it exists because a control has no
/// other way to say anything. `CustomLocalizedStringResourceConvertible` is what
/// makes the string surface instead of a generic "the operation could not be
/// completed".
enum NudgeUnavailable: Error, CustomLocalizedStringResourceConvertible {
    /// No usable session in the shared keychain group — signed out, or a token
    /// this process is not allowed to refresh (§2 tooth #3).
    case signedOut

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            return "Open SalahBuddy to sign in, then try again."
        }
    }
}

// MARK: - The send

/// The nudge itself, shared by both intents.
///
/// Everything it needs is either on disk or in the shared keychain: there is no
/// Supabase SDK in this process, no `PushRegistrar`, and no `AppState` — see
/// `Sources/Shared/WidgetNudge.swift`, which holds the session read, the
/// request and the optimistic write, on the side of the fence the app's tests
/// compile.
enum NudgeSender {

    /// - Parameter reload: whether to ask WidgetKit to redraw afterwards. False
    ///   for the Control's loop, which reloads once at the end rather than once
    ///   per person.
    static func send(memberID: String, dayKey: String, prayer: String,
                     reload: Bool = true) async {
        guard !memberID.isEmpty else { return }

        // §4: the new state goes into the container BEFORE anything
        // asynchronous, exactly as `AppState.sendNudge` inserts into
        // `nudgesSent` before awaiting. The chip has to settle the instant it
        // is tapped, whatever the network does next — and the server's
        // one-per-window rate limit means a second tap is `rate_limited`, which
        // is not an error and is not a reason to un-tick anything.
        WidgetFile.markNudged(memberID: memberID)
        if reload { WidgetCenter.shared.reloadAllTimelines() }

        // Re-checked here as well as at render time, because the token can die
        // in between. NEVER refreshed (§2 tooth #3): a dead session simply
        // means no request, and the next render offers the deep link instead.
        guard let token = SharedSession.load(), token.isFresh(at: Date()),
              let request = NudgeRequest.build(memberID: memberID,
                                               dayKey: dayKey,
                                               prayer: prayer,
                                               accessToken: token.accessToken)
        else { return }

        // Best-effort, and silent either way — the same contract
        // `PushRegistrar.send` has. A push whose moment has passed is not worth
        // a queue, and there is nowhere in a widget to show an error anyway.
        _ = try? await URLSession.shared.data(for: request)
    }
}
