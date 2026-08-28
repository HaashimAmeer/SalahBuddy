import Foundation
import Supabase
import UIKit
import UserNotifications

// MARK: - The APNs environment

/// Which APNs host the token this build produces belongs to.
///
/// It is baked into the `devices` row because `notify` has to choose a host per
/// token (`api.sandbox.push.apple.com` vs `api.push.apple.com`), and a token
/// minted by one is meaningless to the other.
///
/// **TestFlight is `production`.** Only a build signed with a *development*
/// profile — one Xcode put on the phone itself — talks to the sandbox;
/// TestFlight and the App Store are both the production environment. `#if DEBUG`
/// draws that line in exactly the right place: `make build`/Xcode runs are
/// DEBUG, every archive Xcode Cloud uploads is Release.
enum APNsEnvironment {
    /// The two values `devices.environment`'s CHECK constraint allows.
    static let sandbox: String = "sandbox"
    static let production: String = "production"

    /// Pure, so one build can test both answers. `current` is the only caller
    /// that gets to decide which side it is on.
    static func name(debugBuild: Bool) -> String {
        debugBuild ? APNsEnvironment.sandbox : APNsEnvironment.production
    }

    #if DEBUG
    static let current: String = APNsEnvironment.name(debugBuild: true)
    #else
    static let current: String = APNsEnvironment.name(debugBuild: false)
    #endif
}

// MARK: - The devices row

/// What this phone's `devices` row should say (SPEC-V4 §6) — and ONLY the
/// columns the grants name (`20260821000200_rls.sql`, plus `utc_offset` from
/// `20260822000500`): `insert (user_id, apns_token, environment,
/// notify_friend_activity, utc_offset)`.
///
/// `updated_at` is deliberately absent: it sits OUTSIDE that grant and is the
/// server's. This type is not `Encodable` at all — the row is written through
/// `register_device`, whose params are `RegisterDeviceParams` — so it is a
/// value the registrar reasons with rather than a wire format, and there is no
/// on-disk mirror and no `persistingMirror` branch anywhere near it. (That flag
/// exists because a DTO serving both the wire and the mirror silently dropped a
/// column on cold launch — twice. The rule it left behind: a column outside the
/// INSERT grant is encoded ONLY under `CodingUserInfoKey.persistingMirror`.)
struct RemoteDevice: Equatable, Sendable {
    var userID: UUID
    var apnsToken: String
    var environment: String
    var notifyFriendActivity: Bool

    /// v4: where this phone IS, in seconds east of UTC
    /// (`20260822000500_device_utc_offset.sql`).
    ///
    /// `notify` fans a post out to the whole circle, and until this column
    /// existed it did so with no idea what time it was where anyone was
    /// standing: a 5am Fajr in Mumbai buzzed a friend in Seattle at 4:30pm,
    /// half a day after their own Fajr. The function compares the post's
    /// `day_key` against each recipient's local day, and this is the only thing
    /// that tells it what that is.
    ///
    /// Non-optional HERE and nullable in the column, deliberately. A phone
    /// always knows its own offset; a `devices` row written by a build older
    /// than this genuinely does not, and 0 is a real answer (London in winter),
    /// so the server can never let a default stand in for "unknown" — it reads
    /// NULL as "cannot judge, send anyway".
    var utcOffset: Int

    /// The arguments `register_device` takes.
    ///
    /// `user_id` is deliberately absent: the function reads `auth.uid()`, so a
    /// caller cannot register a token in somebody else's name.
    var registerParams: RegisterDeviceParams {
        RegisterDeviceParams(token: apnsToken,
                             environment: environment,
                             friendActivity: notifyFriendActivity,
                             utcOffset: utcOffset)
    }

    /// Everything a write would put on the server, in one comparable line.
    ///
    /// Same durable-fingerprint decision as `LocalIdentity.syncFingerprint`:
    /// iOS hands the delegate the SAME token on every single launch, and a
    /// round trip per launch for a row that already says this is waste. A flag
    /// in memory could not tell the difference; this can, it survives
    /// relaunching, and it changes the moment the user, the environment, the
    /// friend-activity toggle OR THE ZONE does.
    ///
    /// The zone is in here for a concrete reason: it is the one field that
    /// changes while nothing the person did changed. Landing in Mumbai and
    /// foregrounding the app is the whole re-registration trigger — `refresh`
    /// runs on every foreground and this is what makes it not a no-op — and a
    /// traveller left holding their departure offset is filtered out of their
    /// own circle's pushes by the server that trusted it.
    var fingerprint: String {
        [userID.uuidString, apnsToken, environment,
         notifyFriendActivity ? "1" : "0", String(utcOffset)]
            .joined(separator: "\u{1}")
    }
}

/// The params
/// `public.register_device(p_token, p_environment, p_friend_activity, p_utc_offset)`
/// is called with (`20260821000900_register_device.sql`, widened by
/// `20260822000500_device_utc_offset.sql`).
///
/// v4 Phase D FIX: this replaces `upsert(onConflict: "apns_token")`, which could
/// not do the one job it was there for. `apns_token` is the primary key and one
/// install keeps the same token for life, so the row has to FOLLOW the token when
/// a second person signs in on the same phone — but ON CONFLICT DO UPDATE
/// evaluates the UPDATE policy's USING clause against the EXISTING row, and
/// `devices_all` is `user_id = auth.uid()`. The previous account's row is
/// therefore a 42501 the new account cannot update and cannot delete: it stays
/// live, and the old circle keeps pushing a friend's name and prayer to a phone
/// somebody else is now holding. The RPC reclaims the token instead. Test 26
/// pins both halves.
struct RegisterDeviceParams: Encodable, Equatable, Sendable {
    var token: String
    var environment: String
    var friendActivity: Bool
    /// Seconds east of UTC. Added in `20260822000500_device_utc_offset.sql`,
    /// which DROPPED the three-argument function rather than leaving it beside
    /// the four-argument one: two overloads differing only by a defaulted
    /// trailing parameter make every existing call ambiguous. Sending the
    /// parameter is therefore not optional for this build — and an out-of-range
    /// value is stored as NULL by the RPC rather than refused, so a bad clock
    /// costs push FILTERING and never push itself.
    var utcOffset: Int

    enum CodingKeys: String, CodingKey {
        case token = "p_token"
        case environment = "p_environment"
        case friendActivity = "p_friend_activity"
        case utcOffset = "p_utc_offset"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(environment, forKey: .environment)
        try c.encode(friendActivity, forKey: .friendActivity)
        try c.encode(utcOffset, forKey: .utcOffset)
    }
}

// MARK: - The Live Activity's push tokens (v5 §6)

/// Which of ActivityKit's two token kinds this is.
///
/// They are different things with different lifetimes and the server treats
/// them differently (`live_activity_tokens.kind`, 20260828000100):
///
/// - `.start` is the app-wide **push-to-start** token. It exists before any
///   activity does, so it names no window.
/// - `.update` belongs to ONE running activity and dies with it — a few hours
///   at the outside, five a day if every prayer window gets one.
///
/// Neither can live on `devices`, which is keyed on a stable `apns_token` that
/// one install keeps for its whole life. §6 says exactly that, and the schema
/// comment says it again.
enum LiveActivityTokenKind: String, Equatable, Sendable {
    case start
    case update
}

/// What `register_live_activity_token` is called with, as a value the registrar
/// can reason about.
///
/// Same shape and the same discipline as `RemoteDevice`: only the columns the
/// grants name, `user_id` deliberately absent (the RPC reads `auth.uid()`, so a
/// caller cannot register a token in somebody else's name), and no `Encodable`
/// conformance at all — the wire format is `RegisterLiveActivityTokenParams`.
struct LiveActivityRegistration: Equatable, Sendable {
    var token: String
    var kind: LiveActivityTokenKind
    /// ActivityKit's `Activity.id`, so this device can delete precisely the row
    /// for an activity it just ended. Opaque to the server.
    var activityID: String?
    /// The window a running activity is about. nil for `.start`, and the RPC
    /// refuses the two mismatched combinations rather than storing a row the
    /// fan-out cannot use.
    var dayKey: String?
    var prayer: Prayer?
    /// When that window closes, as THIS device computed it.
    ///
    /// It is the one piece of schedule the server holds, and it is one already-
    /// running activity's own end rather than a schedule: it cannot go stale,
    /// and it is what lets the fan-out set a correct `stale-date` and retire an
    /// activity whose window closed while the phone was asleep.
    var endsAt: Date?
    var environment: String
    var utcOffset: Int

    var registerParams: RegisterLiveActivityTokenParams {
        RegisterLiveActivityTokenParams(
            token: token,
            kind: kind.rawValue,
            activityID: activityID,
            dayKey: dayKey,
            prayer: prayer,
            endsAt: endsAt,
            environment: environment,
            utcOffset: utcOffset)
    }

    /// Everything a write would put on the server, in one comparable line —
    /// same job as `RemoteDevice.fingerprint`.
    ///
    /// ActivityKit re-emits the SAME token from its update stream on every
    /// launch and after every state change, and a round trip per emission for a
    /// row that already says this is waste on a path that runs five times a day.
    var fingerprint: String {
        [token, kind.rawValue, activityID ?? "", dayKey ?? "", prayer?.rawValue ?? "",
         endsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
         environment, String(utcOffset)]
            .joined(separator: "\u{1}")
    }
}

/// The params
/// `public.register_live_activity_token(p_token, p_kind, p_activity_id,
/// p_day_key, p_prayer, p_ends_at, p_environment, p_utc_offset)` is called with.
struct RegisterLiveActivityTokenParams: Encodable, Equatable, Sendable {
    var token: String
    var kind: String
    var activityID: String?
    var dayKey: String?
    var prayer: Prayer?
    var endsAt: Date?
    var environment: String
    var utcOffset: Int

    enum CodingKeys: String, CodingKey {
        case token = "p_token"
        case kind = "p_kind"
        case activityID = "p_activity_id"
        case dayKey = "p_day_key"
        case prayer = "p_prayer"
        case endsAt = "p_ends_at"
        case environment = "p_environment"
        case utcOffset = "p_utc_offset"
    }

    /// `timestamptz` as PostgREST wants it. Spelled out rather than left to the
    /// encoder's date strategy, because this struct is handed to the SDK's own
    /// encoder and inheriting whatever that is configured for is how a column
    /// silently becomes NULL.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// A nil field is OMITTED rather than sent as null — the RPC's own defaults
    /// then apply, and PostgREST resolves an overload by the argument names in
    /// the body.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(activityID, forKey: .activityID)
        try c.encodeIfPresent(dayKey, forKey: .dayKey)
        // `Prayer`'s rawValues ARE the `prayer_kind` labels.
        try c.encodeIfPresent(prayer?.rawValue, forKey: .prayer)
        try c.encodeIfPresent(
            endsAt.map { RegisterLiveActivityTokenParams.timestampFormatter.string(from: $0) },
            forKey: .endsAt)
        try c.encode(environment, forKey: .environment)
        try c.encode(utcOffset, forKey: .utcOffset)
    }
}

// MARK: - The notify request

/// The body `functions/v1/notify` parses (`_shared/validate.ts`). Three kinds,
/// one struct, because the three share a wire and differ only in which optional
/// fields are present — and a nil field is OMITTED, never sent as null, which
/// the validator would read as a malformed body.
///
/// Keys are camelCase here and ONLY here: this is a JSON body a Deno function
/// reads, not a PostgREST row, so the snake_case rule that governs every DTO in
/// `RemoteModels.swift` does not apply. They are still spelled out explicitly
/// so the two sides can be diffed by eye.
struct NotifyBody: Encodable, Equatable, Sendable {
    var kind: String
    var postID: UUID?
    var recipientID: UUID?
    var dayKey: String?
    var prayer: Prayer?

    enum CodingKeys: String, CodingKey {
        case kind
        case postID = "postId"
        case recipientID = "recipientId"
        case dayKey
        case prayer
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(postID, forKey: .postID)
        try c.encodeIfPresent(recipientID, forKey: .recipientID)
        try c.encodeIfPresent(dayKey, forKey: .dayKey)
        // `Prayer`'s rawValues ARE the `prayer_kind` labels and the strings
        // `validate.ts` accepts, so the enum crosses as its rawValue.
        try c.encodeIfPresent(prayer?.rawValue, forKey: .prayer)
    }

    static func post(_ postID: UUID) -> NotifyBody {
        NotifyBody(kind: "post", postID: postID)
    }

    static let join: NotifyBody = NotifyBody(kind: "join")

    static func nudge(recipientID: UUID, dayKey: String, prayer: Prayer) -> NotifyBody {
        NotifyBody(kind: "nudge", recipientID: recipientID, dayKey: dayKey, prayer: prayer)
    }
}

/// What `notify` answers with. It always replies 200 with a body describing
/// what happened, so `sent: false` is an OUTCOME, not a failure — see
/// `PushRegistrar.outcome(from:)`.
struct NotifyReply: Decodable, Equatable, Sendable {
    var ok: Bool
    var kind: String?
    var sent: Bool
    var reason: String?

    /// `notify` refused the nudge because this sender already nudged this
    /// person for this prayer window (§6's one-per-window limit, enforced by
    /// the `nudges` primary key).
    static let rateLimited: String = "rate_limited"

    init(ok: Bool = true, kind: String? = nil, sent: Bool = false, reason: String? = nil) {
        self.ok = ok
        self.kind = kind
        self.sent = sent
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case ok, kind, sent, reason
    }

    /// Tolerant on purpose: the function grew `devices`/`delivered`/`skipped`
    /// counters after this shipped, and a reply carrying a field this build has
    /// never heard of must not read as a failure.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOK: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        let decodedSent: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .sent)
        ok = decodedOK ?? true
        sent = decodedSent ?? false
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// What a notify call MEANT, in the four shapes a call site can care about.
///
/// None of them is an error a person should ever see: §6's pushes are garnish
/// on an action that has already succeeded (the prayer is logged, the circle is
/// joined, the friend is marked nudged in the optimistic UI).
enum NotifyOutcome: Equatable, Sendable {
    /// At least one device was handed the alert.
    case sent
    /// `rate_limited` — you already nudged them for this window. The button
    /// says "Nudged ✓", which is what it already said: this is the SAME
    /// outcome as `.sent` as far as the UI is concerned, and emphatically not
    /// an error.
    case alreadyNudged
    /// The server did the right thing and there was simply nobody to wake —
    /// "not_first", "no_circle", a friend with no registered device.
    case skipped(reason: String)
    /// The call never landed. Logged, never shown, never retried: a push whose
    /// moment has passed is not worth a queue.
    case failed

    /// True only for `.failed`. Nothing above it is worth telling anyone about.
    var isFailure: Bool { self == .failed }
}

// MARK: - The incoming push

/// What an ARRIVING §6 push is about.
///
/// The rawValues are the three `kind` strings `notify` writes into the payload's
/// `data` block, and `buildAPNsPayload` spreads that block BESIDE `aps` — so
/// each one arrives as a plain top-level key in the notification's `userInfo`.
///
/// **This is the only field read off a remote payload, and that is a rule
/// rather than an oversight.** `data` also carries `postId`, `userId`, `dayKey`
/// and `prayer`, and every one of them is ignored. A push means exactly what a
/// realtime event means (`CircleSyncSignal`): something over there changed, ask
/// — never here is the change. The pull is the one data path, because it is the
/// only thing that asks the server, through RLS, what actually happened.
enum PushKind: String, Equatable, Sendable, CaseIterable {
    case post
    case join
    case nudge

    /// The key `notify`'s `data` block spells it under.
    static let payloadKey: String = "kind"

    /// Pure, and on a type with no actor of its own — for the reason
    /// `PushRegistrar.hexToken` is `nonisolated`: the notification-centre
    /// callbacks are not guaranteed to arrive on the main actor, and a
    /// `[AnyHashable: Any]` is not `Sendable`, so the crossing has to carry
    /// this value, decoded on the near side.
    ///
    /// An absent or unrecognised kind is nil rather than a default: a later
    /// build's push — or a notification that is not ours at all — must not be
    /// read as one of these three.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw: String = userInfo[PushKind.payloadKey] as? String,
              let kind: PushKind = PushKind(rawValue: raw) else { return nil }
        self = kind
    }
}

// MARK: - Seams

/// Everything `PushRegistrar` needs from the network, and nothing else.
///
/// Same decision as `CircleSyncTransport`: the policy (when to ask, when to
/// write, what a reply means) is pure enough to unit-test, and it only stays
/// that way if the SDK sits behind a seam. `SupabasePushTransport` is the only
/// implementation the app ships and the only code in this file that names
/// Postgrest or Functions — so an SDK API that needs fixing is fixed in one
/// place, which matters when CI is the compiler.
@MainActor
protocol PushTransport: AnyObject {
    /// Claim this phone's row for `device.userID`, whoever held it before.
    func registerDevice(_ device: RemoteDevice) async throws
    func deleteDevice(token: String) async throws
    func notify(_ body: NotifyBody) async throws -> NotifyReply

    /// v5 §6: the same claim, for an ActivityKit token. A SEPARATE call rather
    /// than a widened `registerDevice`, because it writes a different table
    /// with a different lifetime — see `LiveActivityTokenKind`.
    func registerLiveActivityToken(_ registration: LiveActivityRegistration) async throws
    /// The activity ended. Scoped by token alone; the row-level policy narrows
    /// it to this account's rows anyway.
    func deleteLiveActivityToken(token: String) async throws
}

/// The phone half: the permission prompt, the APNs registration call, the two
/// notification settings, and the one string of bookkeeping that remembers what
/// the server was last told.
///
/// Separate from the transport because it is a different kind of thing (UIKit
/// and `Store`, not the network) and because it is what lets a test drive a
/// denied user, a first-run user and an already-authorised one without a
/// device.
@MainActor
protocol PushSystem: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    func preferences() -> PushPreferences
    func lastRegistration() -> String?
    func rememberRegistration(_ fingerprint: String?)
    /// A row this device has decided should not exist but has not yet managed
    /// to delete. Persisted, because the whole point is that it survives the
    /// launch that could not reach the network — see `removeDeviceRow`.
    func pendingDelete() -> String?
    func rememberPendingDelete(_ token: String?)
}

/// The two Settings switches this file is allowed to read.
///
/// `notificationsEnabled` is the master switch the Settings screen nests
/// "Friend activity" underneath, so friend-activity push means BOTH — one
/// screen, one meaning. See `wantsFriendActivity`.
struct PushPreferences: Equatable, Sendable {
    var notificationsEnabled: Bool
    var friendActivity: Bool

    init(notificationsEnabled: Bool = false, friendActivity: Bool = false) {
        self.notificationsEnabled = notificationsEnabled
        self.friendActivity = friendActivity
    }

    /// What `devices.notify_friend_activity` should say. The server applies it
    /// on the RECEIVING side (`devicesFor(..., friendActivityOnly: true)` in
    /// `_shared/db.ts`), which is exactly what the toggle's copy promises:
    /// "When someone in your circle posts first".
    var wantsFriendActivity: Bool { notificationsEnabled && friendActivity }
}

// MARK: - PushRegistrar

/// v4 §6: this device's APNs registration, and the three calls to `notify`.
///
/// **The one rule that shapes everything here: a solo user is never asked.**
/// §1 promises the app works fully offline with no account, so a permission
/// prompt for *friend activity* must not appear until there are friends. The
/// prompt is therefore hung off `refresh(userID:hasCircle:)` — which only ever
/// says yes once a real circle exists — and not off launch.
///
/// **It does not own notifications; `NotificationManager` does.** That class
/// keeps every LOCAL notification (prayer windows, last call, the break
/// reminder) and, crucially, keeps the permission flow: when this file needs
/// authorization it calls `NotificationManager.requestPermission()` rather than
/// asking `UNUserNotificationCenter` itself, so there is exactly one prompt,
/// one option set, and no way for the two to ask twice or ask for different
/// things. If permission already exists — which it usually does, because
/// onboarding asked for prayer reminders — this file asks for nothing at all
/// and goes straight to registering the token.
///
/// **Every path is best-effort.** Nothing here throws to a call site. A prayer
/// is logged, a circle is joined and a friend is nudged whether or not any of
/// this works; the outbox is for facts, and a push is not one.
@MainActor
final class PushRegistrar {

    /// The app-wide registrar. A singleton for the same reason
    /// `NotificationManager` is one: the call sites are scattered (a post that
    /// finished uploading, a join, a nudge chip) and none of them should have
    /// to be handed a dependency to fire a notification nobody waits for.
    static let shared: PushRegistrar = PushRegistrar()

    // MARK: Collaborators

    private let transport: any PushTransport
    private let system: any PushSystem
    private let reachability: Reachability?

    /// `transport`, `system` and `reachability` are optional-and-resolved-later
    /// rather than defaulted for the reason `CircleSync.init` documents: a
    /// default argument is evaluated in a nonisolated context, and these are
    /// all `@MainActor` types.
    init(transport: (any PushTransport)? = nil,
         system: (any PushSystem)? = nil,
         reachability: Reachability? = nil) {
        self.transport = transport ?? SupabasePushTransport()
        self.system = system ?? LivePushSystem()
        self.reachability = reachability
    }

    // MARK: State

    /// The token iOS last handed the app delegate. Kept across a sign-out:
    /// APNs hands back the same one for the life of the install, and the next
    /// account to sign in on this phone needs it.
    private(set) var deviceToken: String?

    /// Who the token is being registered FOR, and whether there is a real
    /// circle to register it for at all. Both are set by `refresh` and are what
    /// make "never in demo mode" checkable at every call below.
    private(set) var owner: UUID?
    private(set) var hasCircle: Bool = false

    /// The server has a row matching what this device would write.
    private(set) var isRegistered: Bool = false

    /// The last thing that went wrong, in the app's voice. Nothing shows it
    /// today — it exists so a developer card can, and so a failure is not
    /// swallowed silently.
    private(set) var lastFailure: CircleError?

    /// The last push this device was HANDED. Same reason as `lastFailure`: a
    /// developer card can show it, and a test can see a receipt land without
    /// having to wire the hook below.
    private(set) var lastReceived: PushKind?

    /// Where an arriving push goes.
    ///
    /// Nil is "nobody is listening" — the honest state before `CircleStack` has
    /// built the sync engine, and in every test that does not care. The app
    /// wires it to `CircleSync.signalArrived`, which is the SAME door realtime
    /// knocks on, deliberately: a push and a `postgres_changes` event mean the
    /// identical thing to this app, and two doors would be two places for the
    /// debounce, the offline guard and the delta/full decision to drift apart.
    var onRemoteNotification: (@MainActor (PushKind) -> Void)?

    /// There is somewhere for a push to come from. Sending is not receiving, so
    /// this deliberately does NOT ask whether notifications are authorised: a
    /// person who declined the prompt can still nudge a friend.
    var isInRealCircle: Bool { hasCircle && owner != nil }

    private var isOnline: Bool {
        (reachability ?? Reachability.shared).isOnline
    }

    // MARK: - Registration

    /// Launch, foreground, and the moment a circle comes into existence.
    ///
    /// Idempotent and cheap: the common case (already authorised, same token,
    /// same user, same toggles) costs one `notificationSettings()` read, one
    /// `registerForRemoteNotifications()` — which iOS answers from its cache —
    /// and no network at all.
    func refresh(userID: UUID?, hasCircle: Bool) async {
        owner = userID
        self.hasCircle = hasCircle

        // FIRST, and outside every guard below: a delete this device owes the
        // server is owed whether or not there is a circle now. It is also the
        // one thing that must not run AFTER `writeDeviceRow`, which would
        // delete the row we had just written.
        await flushPendingDelete()

        // §1: solo needs no account, and an account-less user has nothing to be
        // notified ABOUT. No prompt, no token, no row.
        guard let userID: UUID = userID, hasCircle else { return }

        // The master switch owns the remote half too. Leaving a device row
        // behind while the Settings screen says notifications are off would let
        // a nudge buzz a phone the app has been told to keep quiet.
        guard system.preferences().notificationsEnabled else {
            await removeDeviceRow()
            return
        }

        guard await ensureAuthorized() else { return }
        system.registerForRemoteNotifications()
        await writeDeviceRow(userID: userID)
    }

    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// iOS delivers this on every launch (and again whenever the token rotates,
    /// which it does after a restore or an app reinstall), so this is the other
    /// half of `refresh` and not a one-off.
    ///
    /// v4 Phase D FIX: this is the THIRD door into `writeDeviceRow`, and it was
    /// the only one that walked straight past the two gates the other two
    /// apply. `refresh` sets `owner`/`hasCircle` BEFORE its guards — it has to,
    /// so the owed delete at the top is attempted for the right device — so a
    /// DENIED user's refresh, which correctly asks for nothing and writes no
    /// row, still left this method holding a real owner: a token arriving
    /// afterwards wrote the row anyway. The master switch has the same hole
    /// with worse consequences: iOS answers with the token asynchronously, so
    /// one landing after `preferencesChanged` took the row down would put it
    /// straight back — and clear the delete this device still owed for it,
    /// which is the "buzzing a phone the app was told to keep quiet" bug that
    /// `removeDeviceRow` exists to prevent. Both gates are re-checked here.
    ///
    /// It never PROMPTS — `isAlreadyAuthorized`, not `ensureAuthorized`. A
    /// token callback is not somewhere to put a permission sheet, and by the
    /// time one arrives the asking has already happened in `refresh`.
    func adoptDeviceToken(_ token: String) async {
        deviceToken = token
        guard let userID: UUID = owner, hasCircle else { return }
        guard system.preferences().notificationsEnabled else { return }
        guard await isAlreadyAuthorized() else { return }
        await writeDeviceRow(userID: userID)
    }

    /// `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Happens on the Simulator without a paired Mac push service, and in the
    /// air. Not fatal to anything: the circle, the grid and the log are all
    /// still exactly as they were.
    ///
    /// The description arrives as a `String` rather than as the error itself:
    /// the app delegate's callback is not guaranteed to run on this actor, and
    /// `any Error` is not `Sendable` — so the crossing carries a value that is.
    func registrationFailed(_ description: String) {
        isRegistered = false
        lastFailure = .unknown(description)
    }

    /// Signing out. Called BEFORE the session goes away — see the wiring in
    /// `CircleStack` — and that ordering is the entire point.
    ///
    /// `devices.apns_token` is the PRIMARY KEY, and this install keeps the same
    /// token when the next person signs in on this phone. If our row were left
    /// behind, `devices_all` (`using user_id = auth.uid()`) would hide it from
    /// the new account, whose upsert would then hit a conflicting row it is not
    /// allowed to update — and our circle's pushes would keep arriving on a
    /// phone somebody else is now holding. The only moment this device can
    /// clean up after itself is while it still holds the session that owns the
    /// row, which is here.
    func unregister() async {
        await removeDeviceRow()
        owner = nil
        hasCircle = false
    }

    /// A notification setting changed. Called from `AppState.settings.didSet`,
    /// which is every path that can flip one — Settings, onboarding, a future
    /// screen nobody has written yet.
    ///
    /// v4 Phase D FIX: `refresh` was the only thing that ever wrote the device
    /// row, and its only callers are launch and foreground. So turning "Friend
    /// activity" OFF left `devices.notify_friend_activity = true`, and the very
    /// next push the person received — after backgrounding, which is the only
    /// way they see one — was the one they had just opted out of. The master
    /// switch was worse: the row survived, so nudges and join pushes kept
    /// arriving on a phone the app had been told to keep quiet, which is the
    /// exact invariant `refresh` claims to enforce.
    ///
    /// **It never prompts.** Somebody flipping a preference has not asked to be
    /// asked for permission, and this runs on every settings change — including
    /// a calc-method edit. `registerForRemoteNotifications()` is not the
    /// permission sheet (`ensureAuthorized` is), so registering an already
    /// authorised device here is free and silent.
    func preferencesChanged() async {
        guard let userID: UUID = owner, hasCircle else { return }
        guard system.preferences().notificationsEnabled else {
            await removeDeviceRow()
            return
        }
        guard await isAlreadyAuthorized() else { return }
        system.registerForRemoteNotifications()
        await writeDeviceRow(userID: userID)
    }

    /// Ask only if nobody has asked yet, and never ask twice.
    ///
    /// `NotificationManager` owns the prompt itself (same options, same one
    /// call) so the two halves of the app cannot ask for different things.
    private func ensureAuthorized() async -> Bool {
        let status: UNAuthorizationStatus = await system.authorizationStatus()
        if PushRegistrar.isAuthorized(status) { return true }
        if status == .notDetermined { return await system.requestAuthorization() }
        // Denied. Re-prompting is impossible anyway (iOS shows the sheet once),
        // and the Settings screen already offers the deep link.
        return false
    }

    /// Authorised ALREADY — the question `preferencesChanged` asks, because it
    /// is the one that cannot end in a permission sheet.
    private func isAlreadyAuthorized() async -> Bool {
        let status: UNAuthorizationStatus = await system.authorizationStatus()
        return PushRegistrar.isAuthorized(status)
    }

    /// Pure, and the only place the three yes-shaped statuses are listed.
    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// The registration, skipped when the server already knows all of this.
    ///
    /// `register_device` is a security-definer RPC rather than an upsert — see
    /// `RegisterDeviceParams` for the refusal that made the upsert impossible.
    /// It reclaims the token, so this is also what repairs a row the PREVIOUS
    /// account on this phone left behind.
    private func writeDeviceRow(userID: UUID) async {
        guard let token: String = deviceToken else { return }
        let device = RemoteDevice(userID: userID,
                                  apnsToken: token,
                                  environment: APNsEnvironment.current,
                                  notifyFriendActivity: system.preferences().wantsFriendActivity,
                                  // Read here rather than cached: this method is
                                  // the ONE place a `devices` row is written, and
                                  // every door into it (launch, foreground, a
                                  // settings flip, a token callback) is also a
                                  // moment the phone may have moved. `AppClock`
                                  // rather than `TimeZone.current` directly, per
                                  // the house rule — and time travel is pinned to
                                  // zero in a real circle, so this is the true
                                  // offset wherever it is read from.
                                  utcOffset: AppClock.utcOffsetSeconds)
        let fingerprint: String = device.fingerprint
        if fingerprint == system.lastRegistration() {
            isRegistered = true
            return
        }
        do {
            try await transport.registerDevice(device)
            system.rememberRegistration(fingerprint)
            // The row this device owed a delete for is the row it just wrote,
            // deliberately. Leaving the debt on the books would delete our own
            // registration on the next refresh.
            if system.pendingDelete() == token {
                system.rememberPendingDelete(nil)
            }
            isRegistered = true
            lastFailure = nil
        } catch {
            // Forget rather than keep the old fingerprint, so the next
            // foreground tries again — the same retry shape `syncProfile` uses.
            system.rememberRegistration(nil)
            isRegistered = false
            lastFailure = CircleError.from(error)
        }
    }

    /// Take this device's row down. Idempotent, and free when there was never
    /// a row to take down.
    ///
    /// v4 Phase D FIX: the owed delete is WRITTEN DOWN before it is attempted.
    /// This used to forget the registration locally and then bail out if the
    /// device was offline — so an offline sign-out (or any swallowed failure)
    /// left the row on the server with the local record already erased, and the
    /// next `refresh` computed `hadRow == false` and never tried again. Nothing
    /// else collects it either: the token is still live, so Apple never answers
    /// 410, and retention only touches rows by `user_id`. The row simply stayed,
    /// buzzing a phone the app had been told to keep quiet.
    private func removeDeviceRow() async {
        let hadRow: Bool = isRegistered || system.lastRegistration() != nil
        system.rememberRegistration(nil)
        isRegistered = false
        guard hadRow, let token: String = deviceToken else { return }
        system.rememberPendingDelete(token)
        await flushPendingDelete()
    }

    /// Pay off an owed delete, if there is one and there is a network.
    ///
    /// Retried from the top of `refresh`, which is launch, foreground and the
    /// moment a circle appears — so the debt is settled the first time this
    /// device is online again while it still holds the session that owns the
    /// row. Best-effort, like everything else here: a failure keeps the debt.
    private func flushPendingDelete() async {
        guard let token: String = system.pendingDelete(), isOnline else { return }
        do {
            try await transport.deleteDevice(token: token)
            system.rememberPendingDelete(nil)
        } catch {
            lastFailure = CircleError.from(error)
        }
    }

    // MARK: - Live Activity tokens (v5 §6)

    /// Fingerprints of the registrations this process has already written.
    ///
    /// IN MEMORY, unlike `devices`' — which is deliberate and is the difference
    /// between the two tables. A `devices` fingerprint has to survive relaunch
    /// because iOS hands back the SAME apns token on every single launch and a
    /// round trip per launch is waste. An ActivityKit token is ephemeral: the
    /// update token dies with its activity, and a relaunch that re-registers
    /// one is re-registering something the server may well have swept.
    private var liveActivityRegistrations: Set<String> = []

    /// Register an ActivityKit token (§6).
    ///
    /// Best-effort like everything else here, and gated exactly as `send` is:
    /// demo mode and a solo install never reach the network, so a simulated
    /// circle's Live Activity is purely local — which is what §9-03 asks for
    /// (the surface works for every user; only the push half needs friends).
    @discardableResult
    func registerLiveActivityToken(_ registration: LiveActivityRegistration) async -> Bool {
        guard isInRealCircle, isOnline else { return false }
        let fingerprint: String = registration.fingerprint
        guard !liveActivityRegistrations.contains(fingerprint) else { return true }
        do {
            try await transport.registerLiveActivityToken(registration)
            liveActivityRegistrations.insert(fingerprint)
            return true
        } catch {
            lastFailure = CircleError.from(error)
            return false
        }
    }

    /// The activity ended — take its address off the books.
    ///
    /// Not owed and not retried, unlike a `devices` row's delete: the sweep
    /// (`purge_expired_live_activity_tokens`) collects a missed one within
    /// twelve hours, and the fan-out's own 410 handling drops it sooner than
    /// that. A pending-delete ledger for a token that expires by itself would be
    /// machinery for nothing.
    func forgetLiveActivityToken(_ token: String) async {
        liveActivityRegistrations = liveActivityRegistrations.filter {
            !$0.hasPrefix("\(token)\u{1}")
        }
        guard isInRealCircle, isOnline else { return }
        do {
            try await transport.deleteLiveActivityToken(token: token)
        } catch {
            lastFailure = CircleError.from(error)
        }
    }

    // MARK: - Receiving (SPEC-V4 §6)

    /// A remote notification was DELIVERED to this device — presented while the
    /// app was open, or tapped from the lock screen. Both arrive through
    /// `AppDelegate`, which is the only place iOS hands either one over.
    ///
    /// v4 Phase D FIX: until this existed the `kind` in every push's payload was
    /// read by nobody. `AppDelegate` implemented `willPresent` — how to draw the
    /// banner — and threw the payload away, so a push was a banner and nothing
    /// else: the phone was told a friend had joined and did not go and look.
    ///
    /// Deliberately NOT gated on `isInRealCircle`. A push for a circle this
    /// device has just left costs exactly one signal, and `CircleSync.pull`
    /// already refuses to do anything without a live circle — whereas gating
    /// here would put a race between the registrar learning about a circle and
    /// the first push about it.
    func remoteNotificationArrived(_ kind: PushKind) {
        lastReceived = kind
        onRemoteNotification?(kind)
    }

    // MARK: - notify (SPEC-V4 §6)

    /// "📸 X posted first for Fajr" — call it once a post upload has been
    /// ACKNOWLEDGED by the server, since the function looks the post up by id
    /// and answers `post_not_found` for a row that isn't there yet.
    ///
    /// v4 DECISION: this is NOT gated on the sender's own friend-activity
    /// toggle. That toggle is a RECEIVING preference — "When someone in your
    /// circle posts first" — and the server applies it per recipient
    /// (`devicesFor(..., friendActivityOnly: true)`). Gating the announcement
    /// on the poster's copy of it would mean someone who muted friend activity
    /// also silenced every friend who asked for it. What this device's toggle
    /// governs is its own `devices.notify_friend_activity`, which
    /// `writeDeviceRow` keeps up to date.
    @discardableResult
    func announcePost(postID: UUID) async -> NotifyOutcome {
        await send(.post(postID))
    }

    /// "X joined your circle" — right after `join_circle` returns.
    @discardableResult
    func announceJoin() async -> NotifyOutcome {
        await send(NotifyBody.join)
    }

    /// The nudge button, now a real push. Rate-limited server-side to one per
    /// sender per recipient per prayer window; `rate_limited` comes back as
    /// `.alreadyNudged`, which is not an error and not a reason to un-tick the
    /// chip.
    @discardableResult
    func nudge(recipientID: UUID, dayKey: String, prayer: Prayer) async -> NotifyOutcome {
        await send(.nudge(recipientID: recipientID, dayKey: dayKey, prayer: prayer))
    }

    /// The call-site-shaped overload: the grid holds `CircleMember`s, whose
    /// `id` is the user's uuid string in a real circle and a simulator name (or
    /// "you") in demo. Parsing it is what keeps a demo nudge purely local
    /// without the caller having to know which mode it is in.
    @discardableResult
    func nudge(member: CircleMember, dayKey: String, prayer: Prayer) async -> NotifyOutcome {
        guard !member.isYou, let recipientID: UUID = UUID(uuidString: member.id) else {
            return .skipped(reason: PushRegistrar.simulatedMemberReason)
        }
        return await nudge(recipientID: recipientID, dayKey: dayKey, prayer: prayer)
    }

    /// A member who only exists in `BuddySimulator`.
    static let simulatedMemberReason: String = "simulated_member"
    /// There is no real circle on this device — demo mode, or solo.
    static let noCircleReason: String = "no_circle"
    /// Nothing to send it over. Not queued: see `NotifyOutcome.failed`.
    static let offlineReason: String = "offline"

    private func send(_ body: NotifyBody) async -> NotifyOutcome {
        // Demo mode never touches the network. This is the guard that keeps
        // that true for pushes.
        guard isInRealCircle else { return .skipped(reason: PushRegistrar.noCircleReason) }
        guard isOnline else { return .skipped(reason: PushRegistrar.offlineReason) }
        do {
            let reply: NotifyReply = try await transport.notify(body)
            return PushRegistrar.outcome(from: reply)
        } catch {
            lastFailure = CircleError.from(error)
            return .failed
        }
    }

    /// Pure: what the function's 200 actually meant.
    ///
    /// `sent: false` with no reason is the nudge path — it answers only whether
    /// the push went, deliberately (telling one member how many devices another
    /// has is a fact about a named person). It means "recorded, but they have
    /// no phone listening", which is still not an error.
    static func outcome(from reply: NotifyReply) -> NotifyOutcome {
        if reply.sent { return .sent }
        guard let reason: String = reply.reason else { return .skipped(reason: "not_sent") }
        if reason == NotifyReply.rateLimited { return .alreadyNudged }
        return .skipped(reason: reason)
    }

    /// Apple's token as the lowercase hex string every APNs provider expects.
    ///
    /// `nonisolated` because the app delegate's callback is not guaranteed to
    /// inherit this class's isolation — the same reason
    /// `AuthService.isGoogleCancellation` is.
    nonisolated static func hexToken(from data: Data) -> String {
        data.map { byte in String(format: "%02x", byte) }.joined()
    }
}

// MARK: - The live phone

/// `PushSystem` against the real device. Deliberately thin: every line is a
/// call into UIKit, `UserNotifications`, `Store` or `UserDefaults`, and there
/// is no policy here at all — policy lives in `PushRegistrar`, where it can be
/// tested.
@MainActor
final class LivePushSystem: PushSystem {

    init() {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        await NotificationManager.shared.authorizationStatus()
    }

    /// Through `NotificationManager` on purpose — it owns the prompt and its
    /// option set, and one owner is how the app avoids asking twice.
    func requestAuthorization() async -> Bool {
        await NotificationManager.shared.requestPermission()
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Read from `Store` the way `NotificationManager` reads it, so a push
    /// decision never needs an `AppState` to exist first.
    func preferences() -> PushPreferences {
        let settings: AppSettings = Store.load(Store.settingsFile, default: AppSettings())
        return PushPreferences(notificationsEnabled: settings.notificationsEnabled,
                               friendActivity: settings.notifyFriendActivity)
    }

    /// `UserDefaults` rather than `Store`, for the reason
    /// `AuthService.profileSyncKey` gives: it is one short string of
    /// bookkeeping ABOUT the server, not a piece of the user's data.
    private static let registrationKey: String = "v4.pushDeviceRegistration"
    /// The owed delete. Same store, same reason — and it has to OUTLIVE the
    /// launch that could not reach the network, which is the whole point.
    private static let pendingDeleteKey: String = "v4.pushDeviceDeleteOwed"

    func lastRegistration() -> String? {
        UserDefaults.standard.string(forKey: LivePushSystem.registrationKey)
    }

    func rememberRegistration(_ fingerprint: String?) {
        LivePushSystem.write(fingerprint, forKey: LivePushSystem.registrationKey)
    }

    func pendingDelete() -> String? {
        UserDefaults.standard.string(forKey: LivePushSystem.pendingDeleteKey)
    }

    func rememberPendingDelete(_ token: String?) {
        LivePushSystem.write(token, forKey: LivePushSystem.pendingDeleteKey)
    }

    private static func write(_ value: String?, forKey key: String) {
        if let value: String = value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - The live network

/// The only code in this file that names the SDK.
@MainActor
final class SupabasePushTransport: PushTransport {

    init() {}

    /// One RPC, because a token that changed hands cannot be claimed with an
    /// upsert under `devices_all` — see `RegisterDeviceParams`. `rpc` throws at
    /// CALL time (it encodes the params), so the `try` covers the builder as
    /// well as the `execute()`, and the response type is spelled out because
    /// `execute()` is overloaded on its decoded value and nothing here decodes
    /// one.
    func registerDevice(_ device: RemoteDevice) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .rpc("register_device", params: device.registerParams)
            .execute()
    }

    /// Scoped by token alone: `devices_all` narrows it to our own rows anyway,
    /// so this can only ever delete this phone's registration.
    func deleteDevice(token: String) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("devices")
            .delete(returning: .minimal)
            .eq("apns_token", value: token)
            .execute()
    }

    /// v5 §6. Same shape as `registerDevice` and for the same reason: the token
    /// is the primary key, and a row that changed hands cannot be claimed with
    /// an upsert under a `user_id = auth.uid()` policy.
    func registerLiveActivityToken(_ registration: LiveActivityRegistration) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .rpc("register_live_activity_token", params: registration.registerParams)
            .execute()
    }

    func deleteLiveActivityToken(token: String) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("live_activity_tokens")
            .delete(returning: .minimal)
            .eq("token", value: token)
            .execute()
    }

    /// `notify` is `verify_jwt = true` and re-derives every claim from the
    /// database, so the body says only what we are claiming to have done. The
    /// client attaches the caller's own session token automatically
    /// (`SupabaseClient` calls `functions.setAuth` on every auth change).
    func notify(_ body: NotifyBody) async throws -> NotifyReply {
        let options = FunctionInvokeOptions(body: body)
        let reply: NotifyReply = try await Supa.client.functions.invoke("notify", options: options)
        return reply
    }
}
