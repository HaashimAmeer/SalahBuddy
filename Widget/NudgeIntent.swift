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
///    asks again — BEFORE it writes anything — in case the token died between
///    the render and the tap, which for a widget is the ordinary case rather
///    than the unlucky one. A timeline entry can be archived hours before it is
///    looked at (`WidgetSnapshot.reloadDate`) and an access token lives about
///    one, so the Button on screen is regularly older than the session behind
///    it. `NudgeRoute` is that decision, spent by both call sites.
/// 2. **The optimistic state is written into the container BEFORE returning**,
///    which is §4's own instruction: the intent runs headless, WidgetKit
///    reloads after it returns, and a tile that reloaded before the write would
///    render the state the button was tapped to change. Before RETURNING, not
///    before deciding — the tick goes in once there is something to tick it
///    for, and comes back out if the reply says it should not have
///    (`NudgeRequest.landed`).
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
        // Checked BEFORE the work — as `NudgeFriendIntent` now is too: the
        // alternative is a control that marks four people nudged and sends
        // nothing. NEVER refreshed, only read — an expired token is the app's
        // business, not ours. A demo circle routes `.local` and is not signed
        // out; it has no account to be signed out OF (§9-03).
        let snapshot: WidgetSnapshot? = WidgetFile.read()
        guard NudgeRoute.decide(mode: snapshot?.mode ?? NudgeRoute.modeWithoutAFile,
                                token: SharedSession.load(), at: Date()).canSend else {
            throw NudgeUnavailable.signedOut
        }
        guard let snapshot, let window = snapshot.window else { return .result() }
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

        // DECIDED BEFORE ANYTHING IS WRITTEN, and that order is the whole fix.
        //
        // The freshness that draws a Button rather than a `Link` is baked at
        // TIMELINE-GENERATION time — WidgetKit renders and archives entry views
        // when the timeline is produced, and `WidgetSnapshot.reloadDate` parks
        // the next one at the window's end, up to eight hours out. A Supabase
        // access token lives about one. So a Button drawn at 09:00 is still on
        // screen at 10:30 with a dead token behind it, and marking first would
        // tick the chip, skip the person in `nextNudgeTarget`, and send nothing
        // — permanently, until the app published a CHANGED snapshot. Reading
        // the keychain is synchronous, so there is no cost to asking first, and
        // it is exactly what `NudgeCircleIntent.perform()` already does.
        let token: SharedSession.Token? = SharedSession.load()
        let outbound: URLRequest?
        switch NudgeRoute.decide(mode: WidgetFile.read()?.mode ?? NudgeRoute.modeWithoutAFile,
                                 token: token, at: Date()) {
        case .unavailable:
            // NEVER refreshed (§2 tooth #3): a dead session means no request and
            // no tick, and the next render offers the deep link instead.
            return
        case .local:
            outbound = nil
        case .remote:
            guard let token,
                  let request = NudgeRequest.build(memberID: memberID,
                                                   dayKey: dayKey,
                                                   prayer: prayer,
                                                   accessToken: token.accessToken)
            else { return }
            outbound = request
        }

        // §4: the new state goes into the container BEFORE anything
        // asynchronous, exactly as `AppState.sendNudge` inserts into
        // `nudgesSent` before awaiting. The chip has to settle the instant it
        // is tapped, whatever the network does next.
        WidgetFile.markNudged(memberID: memberID)
        if reload { WidgetCenter.shared.reloadAllTimelines() }

        // Demo and solo stop here — `AppState.sendNudge` does the same thing in
        // demo mode (bump the local record, republish, never the wire), and
        // §9-03 wants the widget working for a first-run user with no account.
        guard let outbound else { return }

        // Best-effort, but no longer blind. `landed` is what separates "the
        // server has it" from a 401 on a rotated session or a 500 — the two
        // replies that would otherwise leave a chip reading "Nudged" for
        // somebody who received nothing. The server's one-per-window rate limit
        // answers `rate_limited`, which `landed` counts as YES, so a second tap
        // still cannot un-tick a nudge that really went.
        var status: Int = 0
        var payload: Data?
        // A transport failure leaves status 0, which `landed` reads as NOT
        // landed — correct, and the honest answer: nothing reached the server,
        // so nothing was nudged.
        if let (data, response) = try? await URLSession.shared.data(for: outbound) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            payload = data
        }
        guard !NudgeRequest.landed(status: status, body: payload) else { return }
        if WidgetFile.retractNudge(memberID: memberID, dayKey: dayKey, prayer: prayer),
           reload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
