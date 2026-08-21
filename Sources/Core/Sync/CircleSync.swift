import Foundation
import Supabase

// MARK: - Tunables

/// Every number the sync layer waits on, in one place.
///
/// A plain (nonisolated) enum rather than statics on `CircleSync`: these are
/// read from default arguments, and a default-value expression is a nonisolated
/// context in Swift 5 language mode, so a `@MainActor` static could not be
/// named from one (the trap `CircleService.sessionUserID()` documents).
enum CircleSyncTuning {

    /// The reconciling read's horizon. Long enough to cover the ~30-day photo
    /// retention and any week a screen can show, short enough that a full pull
    /// stays one small page per table.
    static let pullWindowDays: Int = 35

    /// Realtime is a SIGNAL, so a burst of five posts landing at maghrib should
    /// cost ONE pull, not five. Two seconds is longer than a burst and shorter
    /// than a person's patience.
    static let realtimeDebounce: TimeInterval = 2

    /// A delta asks for `updated_at > lastSyncedAt - overlap`. The overlap
    /// absorbs clock skew between the device and Postgres: without it, a row
    /// written in the second straddling our last sync is never seen again,
    /// because the next delta starts after it. One minute of re-reading a
    /// handful of rows is a cheap price for never losing one.
    static let deltaOverlap: TimeInterval = 60

    /// Backoff is `base * 2^(attempt-1)`, capped: 2s, 4s, 8s … 300s.
    static let retryBaseDelay: TimeInterval = 2
    static let retryMaxDelay: TimeInterval = 300

    /// After this many consecutive failures the head is reported as STUCK
    /// (`.waiting`) rather than merely pending — the honest "waiting to sync"
    /// affordance. It keeps retrying; the label is for the person.
    static let stallThreshold: Int = 3

    /// A single drain sends at most this many ops before yielding, so a drain
    /// can never become an unbounded loop holding the main actor.
    ///
    /// v4 Phase C FIX: an earlier note here claimed "a week offline collapses to
    /// well under this". It does not — collapsing only merges ops with the SAME
    /// signature, and a week offline is up to 35 distinct `upsertPost` ops plus
    /// up to 35 distinct `uploadPhoto` ops, which is comfortably over the cap.
    /// Hitting it is therefore normal rather than pathological, and `drain()`
    /// schedules its own continuation when it does (nothing else would: the
    /// backoff timers only exist for items that FAILED).
    static let maxOpsPerDrain: Int = 64

    /// How many failures may be charged to the OUTBOX's own attempt counter.
    /// One below its drop threshold, deliberately: `CircleOutbox.recordFailure`
    /// discards an item at `maxAttempts`, and this layer must be the thing that
    /// decides an item is beyond saving, loudly (`discardedCount`), rather than
    /// having the queue quietly forget a write while nobody is looking.
    static let recordedFailureCap: Int = CircleOutbox.maxAttempts - 1
}

// MARK: - Host

/// The slice of the app `CircleSync` is allowed to touch.
///
/// Five members, and not one of them can reach a `PrayerLog`, a streak or an XP
/// total: the sync layer mirrors the CIRCLE, and local history is none of its
/// business (the same fence `CircleServiceHost` puts around `CircleService`).
///
/// `syncIdentityGeneration` is the one that earns its place. It is bumped
/// whenever the local circle identity is replaced — joining, leaving, signing
/// out, adopting a different account — and those paths also clear `outbox.json`
/// underneath this object. Watching the generation is how the queue learns that
/// happened without a second wiring call somebody has to remember to make.
@MainActor
protocol CircleSyncHost: AnyObject {
    var syncUserID: UUID? { get }
    var syncCircleID: UUID? { get }
    var syncSnapshot: CircleSnapshot { get }
    var syncIdentityGeneration: Int { get }
    /// Commit a merged mirror: persist it and hand it to everything that draws.
    func applySyncedSnapshot(_ snapshot: CircleSnapshot)
}

// MARK: - Wire types

/// What a realtime event means to us. Note what it does NOT carry: any of the
/// row's data. LOCKED DECISION — the payload is never decoded (§6); an event
/// says only "something over there changed", and the pull is the one data path.
enum CircleRealtimeEvent: Equatable, Sendable {
    case changed
    /// A DELETE. Deltas key off `updated_at`, and a deleted row has none —
    /// only a full, reconciling pull can notice something is gone.
    case deleted
}

/// The oldest day/week a pull asks for.
struct CircleSyncWindow: Equatable, Sendable {
    let startDayKey: String
    let startWeekKey: String

    init(startDayKey: String, startWeekKey: String) {
        self.startDayKey = startDayKey
        self.startWeekKey = startWeekKey
    }

    /// `days` back from `now`, in the device's local calendar — the same
    /// calendar that produced every `day_key` on the wire.
    ///
    /// `week_key` is "yyyy-Www" with a zero-padded week, which sorts
    /// lexicographically in chronological order, so the server-side filter is a
    /// plain `>=` on text.
    static func window(endingAt now: Date, days: Int) -> CircleSyncWindow {
        let start: Date = now.addingTimeInterval(-Double(days) * 86_400)
        return CircleSyncWindow(startDayKey: AppClock.dayKey(for: start),
                                startWeekKey: BuddySimulator.weekKey(for: start))
    }
}

/// One read from the server. Every collection is optional and `nil` means
/// "this pass did not ask" — which is what lets a cheap delta leave the
/// mirror's roster alone instead of blanking it.
struct CircleSyncPage: Equatable, Sendable {
    var posts: [RemotePost]?
    var excusedDays: [RemoteExcusedDay]?
    var recoveryWeeks: [RemoteRecoveryWeek]?
    var challenges: [RemoteCustomChallenge]?
    var members: [RemoteMember]?
    var profiles: [RemoteProfile]?

    init(posts: [RemotePost]? = nil,
         excusedDays: [RemoteExcusedDay]? = nil,
         recoveryWeeks: [RemoteRecoveryWeek]? = nil,
         challenges: [RemoteCustomChallenge]? = nil,
         members: [RemoteMember]? = nil,
         profiles: [RemoteProfile]? = nil) {
        self.posts = posts
        self.excusedDays = excusedDays
        self.recoveryWeeks = recoveryWeeks
        self.challenges = challenges
        self.members = members
        self.profiles = profiles
    }
}

/// What the UI says about syncing. Four states, because there are exactly four
/// honest things to say.
enum CircleSyncStatus: Equatable {
    case idle
    case syncing
    /// Writes are queued and expected to go out shortly.
    case pending(count: Int)
    /// Queued writes that are NOT moving — offline, or the head keeps failing.
    /// This is the state that owes the user a visible "waiting to sync" row.
    case waiting(count: Int, reason: CircleError)

    var hasPendingWork: Bool {
        switch self {
        case .idle, .syncing: return false
        case .pending, .waiting: return true
        }
    }
}

// MARK: - Transport seam

/// Everything `CircleSync` needs from the network, and nothing else.
///
/// v4 DECISION: the queue, the backoff, the debounce and the merge are pure
/// enough to unit-test, and they only stay that way if the SDK sits behind a
/// seam. `SupabaseCircleTransport` (bottom of this file) is the only
/// implementation the app ships and the only code here that names Postgrest,
/// Storage or Realtime — so an SDK API that needs fixing is fixed in one place,
/// which matters when CI is the compiler and a round trip costs ten minutes.
@MainActor
protocol CircleSyncTransport: AnyObject {
    /// Execute one queued write. Throwing means "not done" — the caller keeps
    /// the item. Returning means the server has it, or already had it.
    func perform(_ op: CircleOp, circleID: UUID, userID: UUID) async throws
    /// `since == nil` is the reconciling window; otherwise the cheap delta.
    func fetch(circleID: UUID, since: Date?, window: CircleSyncWindow) async throws -> CircleSyncPage
    /// Returns whether the channel actually JOINED. False is not an error the
    /// caller shows anyone — realtime is only ever a signal to pull sooner —
    /// but it must be reported, or a dead channel is never retried.
    func startRealtime(circleID: UUID,
                       onEvent: @escaping @Sendable @MainActor (CircleRealtimeEvent) -> Void) async -> Bool
    func stopRealtime() async
}

// MARK: - CircleSync

/// v4 Phase C: the one door between `AppState` and the network.
///
/// `AppState` logs a prayer and calls `postLogged`. That is the entire contract
/// — it never learns whether the write went out now, in ten minutes, or after
/// the flight lands, and it holds no networking code of its own. Everything
/// underneath is this class's problem:
///
/// * **enqueue** — turn a local change into a `CircleOp` and put it on the
///   outbox, which persists immediately. A change that is queued is a change
///   that survives being force-quit.
/// * **drain** — FIFO, one item on the wire at a time, acknowledged through the
///   outbox's `checkout()` / `remove(id:)` / `recordFailure(id:)` protocol,
///   with per-item exponential backoff.
/// * **pull** — the mirror is refreshed by a reconciling full read or a cheap
///   delta, and NEVER blanked by a failure: a pull that throws commits nothing.
/// * **realtime** — a signal to pull sooner, debounced. Never a data path.
///
/// Two invariants run through all of it. Everything degrades to "stay offline,
/// keep the queue" — there is no path where a network failure loses a write or
/// empties a rendered circle. And the break REASON never appears in anything
/// this class can send: the only excused op there is carries a day key and a
/// bare flag, because that is the only shape `CircleOp` gives it.
@MainActor
final class CircleSync: ObservableObject {

    // MARK: Published state

    @Published private(set) var status: CircleSyncStatus = .idle

    /// Writes still owed to the server.
    @Published private(set) var pendingCount: Int = 0

    /// The last failure, in the app's voice. Cleared by the next success so a
    /// stale complaint never outlives the thing it was complaining about.
    @Published private(set) var lastError: CircleError?

    @Published private(set) var lastSyncedAt: Date?

    /// Writes this device gave up on, and why. NOT decoration: an op the server
    /// refuses over and over is dropped so the queue behind it can move, and
    /// the person deserves to know one of their posts never made it rather than
    /// discovering the gap in the grid a week later.
    @Published private(set) var discardedCount: Int = 0
    @Published private(set) var lastDiscarded: CircleError?

    // MARK: Collaborators

    private weak var host: (any CircleSyncHost)?
    private let transport: any CircleSyncTransport
    private var reachability: Reachability?

    /// See `CircleService.persists` — same flag, same reason: the queue has one
    /// home on disk, and a unit test must not scribble in Documents.
    private let persists: Bool

    // MARK: Internals

    /// The pending-write queue. Owned here, because the drain is the only thing
    /// that may take an item off it.
    private(set) var outbox: CircleOutbox

    /// Per-item failure bookkeeping. Kept HERE rather than in the outbox
    /// because it is retry policy, not queue state: it is rebuilt from nothing
    /// on relaunch (where a fresh attempt is exactly what we want) and it must
    /// not be persisted into the file format the outbox promises to keep.
    private struct Attempt: Equatable {
        /// Every failure. Drives the backoff curve and the "stuck" label.
        var count: Int = 0
        /// Only the failures the SERVER uttered. Drives the decision to give
        /// up — a fortnight of airplane mode must never spend this.
        var refusals: Int = 0
        var nextAttemptAt: Date = .distantPast
    }
    private var attempts: [UUID: Attempt] = [:]

    /// Posts this device logged LIVE and has not yet announced (§6).
    ///
    /// In memory rather than in the queue on disk, and that is the decision:
    /// `PushRegistrar` already says "a push whose moment has passed is not worth
    /// a queue", so a post whose acknowledgement arrives after a relaunch is
    /// posted silently. Persisting it would mean announcing yesterday's fajr
    /// because the app was force-quit on a train.
    private var announceablePostIDs: Set<UUID> = []

    /// Where an announcement goes. Nil is the app: `PushRegistrar.shared`, the
    /// same singleton the nudge chip and the join both use. A test supplies one
    /// and gets to observe §6 without APNs, a network or a signed-in user.
    var announcer: (@MainActor (UUID) -> Void)?

    private var isDraining: Bool = false
    private var isPulling: Bool = false
    private var isForeground: Bool = false
    private var subscribedCircleID: UUID?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// A DELETE arrived while the debounce was running: deltas cannot see a
    /// removal, so the coalesced pull has to be the full one.
    private var debouncedPullNeedsFullRead: Bool = false
    private var lastSeenGeneration: Int?

    // MARK: Init

    /// `transport` and `reachability` are optional-and-resolved-later rather
    /// than defaulted: both are `@MainActor` types, and a default argument is
    /// evaluated in a nonisolated context.
    init(host: (any CircleSyncHost)? = nil,
         transport: (any CircleSyncTransport)? = nil,
         reachability: Reachability? = nil,
         outbox: CircleOutbox? = nil,
         persists: Bool = true) {
        self.host = host
        self.transport = transport ?? SupabaseCircleTransport()
        self.reachability = reachability
        self.persists = persists
        if let outbox {
            self.outbox = outbox
        } else if persists {
            self.outbox = CircleOutbox.load()
        } else {
            self.outbox = CircleOutbox.empty
        }
        pendingCount = self.outbox.count
        refreshStatus()
    }

    /// Wired by the app after `AppState` exists.
    func bind(host: any CircleSyncHost) {
        self.host = host
        lastSeenGeneration = host.syncIdentityGeneration
        lastSyncedAt = host.syncSnapshot.lastSyncedAt
    }

    // MARK: - Enqueue (what AppState calls)

    /// A prayer was logged. `photoFilename` is the LOCAL `PhotoStore` file:
    /// the same bytes are uploaded as the circle's copy, and the post's
    /// `photo_path` is patched only once those bytes are really in Storage —
    /// a row advertising an object that 404s is worse than a row with no photo.
    ///
    /// `travelCombined` is passed by the caller because a `PrayerLog` alone
    /// cannot know it was half of a jam' pair; `logCombined` calls this twice,
    /// once per prayer, with `true` both times.
    ///
    /// `announce` is what tells §6's friend-activity push apart from paperwork.
    /// A prayer logged just now is worth waking a friend for; the join
    /// backfill's week of already-prayed prayers is not (see `backfillWeek`).
    func postLogged(_ log: PrayerLog, photoFilename: String? = nil,
                    travelCombined: Bool = false, announce: Bool = true) {
        guard let circleID: UUID = liveCircleID, let userID: UUID = liveUserID else { return }
        let label: String? = AppState.placeLabel(for: log)
        let post: RemotePost = RemotePost.from(log: log, userID: userID, circleID: circleID,
                                               placeLabel: label, photoPath: nil,
                                               travelCombined: travelCombined)
        enqueue(.upsertPost(post))
        // AFTER the enqueue, not before: `enqueue` re-anchors on an identity
        // change, and re-anchoring clears this set. The drain it kicks is a
        // `Task`, so nothing can read the set before this line runs.
        if announce { announceablePostIDs.insert(post.id) }
        guard let filename: String = photoFilename else { return }
        // The object is named after the POST, not a fresh uuid: the path is
        // then a pure function of the log, so a re-queue after a lost
        // acknowledgement targets the same object with the same bytes — which
        // is exactly the collision `PhotoSync.upload` treats as success.
        let path: String = PhotoSync.storagePath(circleID: circleID, userID: userID,
                                                 objectID: log.id)
        // The SLOT travels with the op, not just the row id — see
        // `CircleOp.uploadPhoto` for the orphaned-object bug that fixes.
        enqueue(.uploadPhoto(postID: log.id, dayKey: log.dayKey, prayer: log.prayer,
                             filename: filename, path: path))
    }

    /// A log was undone (SPEC-V4 §3: undo retracts the post).
    ///
    /// Only the row delete is queued. The server tombstones the photo path in
    /// the same transaction (`posts_tombstone_photo`), which stops the object
    /// being readable immediately; the outbox handles the one case the server
    /// cannot — an upload still on the wire — by queueing an explicit retract.
    func postRetracted(_ log: PrayerLog) {
        postRetracted(id: log.id)
    }

    func postRetracted(id: UUID) {
        guard liveCircleID != nil, liveUserID != nil else { return }
        // Undo beats the drain often enough to matter: a post the user has
        // already taken back must not wake anybody, even if its create is still
        // on the wire.
        announceablePostIDs.remove(id)
        enqueue(.deletePost(postID: id))
    }

    /// A rest day was marked or un-marked. A BARE FLAG: `CircleOp.setExcused`
    /// has no field a reason could travel in, which is the point — period
    /// privacy is absolute (§3) and is enforced by the shape of the type, not
    /// by every call site remembering.
    func excusedChanged(dayKey: String, on: Bool) {
        guard liveCircleID != nil, liveUserID != nil else { return }
        enqueue(.setExcused(dayKey: dayKey, excused: on))
    }

    /// The week's dhikr + good-deeds total. One opaque integer per (user, week);
    /// the scoreboard sees the number and never what earned it.
    func recoveryWeekChanged(weekKey: String, xp: Int) {
        guard liveCircleID != nil, liveUserID != nil else { return }
        enqueue(.setRecoveryWeek(weekKey: weekKey, xp: max(0, xp)))
    }

    func challengeCreated(_ challenge: CustomChallenge) {
        guard let circleID: UUID = liveCircleID, let userID: UUID = liveUserID else { return }
        let weekKey: String = BuddySimulator.weekKey(for: challenge.createdAt)
        let row: RemoteCustomChallenge = RemoteCustomChallenge.from(challenge: challenge,
                                                                    circleID: circleID,
                                                                    createdBy: userID,
                                                                    weekKey: weekKey)
        enqueue(.upsertChallenge(row))
    }

    func challengeDeleted(id: String) {
        guard liveCircleID != nil, liveUserID != nil else { return }
        enqueue(.deleteChallenge(challengeID: id))
    }

    /// SPEC-V4 §2: joining mid-week shows the circle your week so far. Called
    /// from `CircleService.joinWeekBackfill`, which fires after the circle is
    /// applied locally and before the first pull.
    ///
    /// Photos are deliberately NOT backfilled. The backfill shares the FACT of
    /// a prayer, and a week of JPEGs uploaded the second someone joins — very
    /// possibly on cellular — is a bad trade for a grid that draws a perfectly
    /// good illustration without them.
    func backfillWeek(_ logs: [PrayerLog], excusedDayKeys: [String] = [],
                      asOf now: Date) {
        guard liveCircleID != nil, liveUserID != nil else { return }
        let weekKeys: Set<String> = Set(BuddySimulator.weekDayKeys(for: now))
        let todayKey: String = AppClock.dayKey(for: now)
        for log in logs where CircleSync.isBackfillable(log, weekKeys: weekKeys,
                                                        now: now, todayKey: todayKey) {
            // `announce: false` — the whole point of this call is to publish
            // prayers that already happened, some of them days ago. Announcing
            // them would fire "📸 X posted first for Fajr" up to 35 times the
            // moment somebody joins, for windows that closed on Monday.
            postLogged(log, photoFilename: nil, travelCombined: false, announce: false)
        }
        // v4 Phase C FIX: the rest days go too. Someone who joins mid-period
        // used to have that week's `excusedDayKeys` stay on their own device,
        // so the circle rendered every empty cell as a plain `.missed` — the
        // exact shaming outcome §3's gentle "resting" state exists to avoid.
        // A bare flag per day, and there is still no field a reason could
        // travel in.
        for key in excusedDayKeys where weekKeys.contains(key) && key <= todayKey {
            excusedChanged(dayKey: key, on: true)
        }
    }

    /// v4 Phase C FIX: the time-travel guard is enforced going FORWARD — while
    /// `circleMode == .real` the developer offset is pinned to zero — but the
    /// join backfill publishes logs written BEHIND it. `BuildEnv.showsDeveloperTools`
    /// is true in TestFlight, so a tester who time-travelled in demo mode and
    /// then joined a real circle would post fictional `logged_at` / `day_key`
    /// rows to real friends: precisely what §3's guard exists to prevent. A log
    /// stamped in the future is simply not shared.
    static func isBackfillable(_ log: PrayerLog, weekKeys: Set<String>,
                               now: Date, todayKey: String) -> Bool {
        guard weekKeys.contains(log.dayKey) else { return false }
        guard log.loggedAt <= now else { return false }
        return log.dayKey <= todayKey
    }

    // MARK: - Lifecycle

    /// Launch. Adopts the shared network monitor, reconciles, drains.
    func start() async {
        if reachability == nil {
            reachability = Reachability.shared
        }
        reachability?.start()
        reachability?.onRegainedConnection = { [weak self] in
            self?.connectionCameBack()
        }
        isForeground = true
        await refreshEverything(fullPull: true)
    }

    /// The app came back to the front: reconcile, drain, and re-open the
    /// realtime channel.
    func enteredForeground() async {
        isForeground = true
        await refreshEverything(fullPull: true)
    }

    /// Gone to the background: the channel closes. A socket held open behind
    /// the user's back buys nothing — the foreground pull will catch up in one
    /// request, and it is the same request either way.
    func enteredBackground() async {
        isForeground = false
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        await updateSubscription()
    }

    /// Midnight rolled over: yesterday's grid is finished and today's is empty.
    func dayChanged() async {
        await refreshEverything(fullPull: true)
    }

    /// A session appeared (sign-in, or a restored session at launch).
    func signedIn() async {
        await refreshEverything(fullPull: true)
    }

    /// The circle itself changed — created, joined, left. Re-anchors the queue
    /// and re-points the realtime channel.
    func circleChanged() async {
        reanchorIfIdentityChanged()
        await refreshEverything(fullPull: true)
    }

    /// The "waiting to sync" affordance's button: forget the backoff and try
    /// right now. Somebody tapping "retry" has information the timer does not.
    func retryNow() async {
        clearBackoff()
        await drain()
        _ = await pull(since: nil)
    }

    private func refreshEverything(fullPull: Bool) async {
        reanchorIfIdentityChanged()
        await drain()
        let cursor: Date? = fullPull ? nil : deltaCursor()
        _ = await pull(since: cursor)
        await updateSubscription()
    }

    private func connectionCameBack() {
        // The backoff exists to stop us hammering a network that isn't there.
        // It just came back, so every timer it set is stale.
        clearBackoff()
        Task { [weak self] in
            await self?.drain()
            _ = await self?.pull(since: nil)
            // A channel that failed to join, or that the socket dropped with
            // the connection, is worth another try the moment there is a
            // network again — `updateSubscription` is a no-op when the one we
            // want is already open.
            await self?.updateSubscription()
        }
    }

    // MARK: - Drain

    /// Send what we owe, oldest first, one at a time.
    ///
    /// Strictly head-of-line: `CircleOutbox` acknowledges only its head, and
    /// that is the right shape — the ops for one row are ordered (create →
    /// photo → delete) and skipping ahead could apply a delete before the
    /// create it was meant to cancel. So a failing head holds the queue, and
    /// this class's job is to make that visible rather than silent.
    func drain() async {
        guard !isDraining else { return }
        reanchorIfIdentityChanged()
        guard let circleID: UUID = liveCircleID, let userID: UUID = liveUserID else { return }
        guard isOnline else {
            // Nothing is wrong except the network. Keep the queue, say so.
            refreshStatus()
            return
        }
        guard !outbox.isEmpty else {
            refreshStatus()
            return
        }

        isDraining = true
        refreshStatus()
        let generation: Int = currentGeneration
        var steps: Int = 0
        // True only when the loop stopped because it ran out of STEPS, with
        // work still queued and nothing wrong.
        var hitTheCap: Bool = false

        while steps < CircleSyncTuning.maxOpsPerDrain {
            steps += 1
            guard let head: OutboxItem = outbox.peek else { break }
            guard isDue(head) else {
                scheduleRetry(for: head)
                break
            }
            _ = outbox.checkout()
            do {
                try await transport.perform(head.op, circleID: circleID, userID: userID)
                // The circle can be left, or a different account adopted, while
                // an op is on the wire. The queue that item belonged to is gone;
                // touching the new one would acknowledge a write nobody made.
                guard isCurrent(generation, circleID) else { break }
                outbox.remove(id: head.id)
                attempts.removeValue(forKey: head.id)
                persistOutbox()
                applyAcknowledged(head.op)
                lastError = nil
            } catch {
                guard isCurrent(generation, circleID) else { break }
                let gaveUp: Bool = recordFailure(head, error: error)
                persistOutbox()
                // Giving up moved the head, so there is a different write to
                // try and no reason to wait for a timer to say so.
                if gaveUp { continue }
                if let next: OutboxItem = outbox.peek {
                    scheduleRetry(for: next)
                }
                break
            }
            if steps == CircleSyncTuning.maxOpsPerDrain, outbox.peek != nil {
                hitTheCap = true
            }
        }

        isDraining = false
        refreshStatus()
        // v4 Phase C FIX: a drain that simply ran out of steps used to stop with
        // NOTHING scheduled to resume it — backoff timers are only ever set for
        // items that failed, and these did not fail. Reconnecting after a week
        // away therefore sent the first 64 writes and left the rest sitting
        // until the user happened to log another prayer or foreground the app.
        // Re-entered as a fresh task rather than looping so the main actor is
        // genuinely released between batches, which is what the cap is for.
        if hitTheCap {
            kickDrain()
        }
    }

    /// Book one failure. Returns true when the item was given up on — i.e. the
    /// head of the queue has moved.
    @discardableResult
    private func recordFailure(_ item: OutboxItem, error: any Error) -> Bool {
        let mapped: CircleError = CircleError.from(error)
        lastError = mapped

        // A failure that cannot come good is given up on at once. The only one
        // that exists is a photo whose local JPEG is gone — undo deletes it,
        // and undo can beat the drain to it — so no later attempt will find
        // anything to upload, and spending eight tries on it only delays every
        // write queued behind it.
        if PhotoSync.isPermanent(error) {
            discard(item, reason: mapped)
            return true
        }

        var state: Attempt = attempts[item.id] ?? Attempt()
        state.count += 1
        state.nextAttemptAt = AppClock.now.addingTimeInterval(CircleSync.backoffDelay(forAttempt: state.count))
        if !mapped.isOffline {
            state.refusals += 1
        }
        attempts[item.id] = state

        // v4 DECISION: **"you're offline" never spends an attempt.**
        // `CircleOutbox` drops an item after `maxAttempts` failures so a poison
        // write cannot wedge the queue forever — a sound rule about writes the
        // SERVER refuses. A week in airplane mode is not that: charging those
        // failures to the same counter would quietly delete a real prayer post
        // for the crime of having been logged on a plane. So a transport
        // failure gets backoff and nothing else, and only a refusal the server
        // actually uttered walks the item toward being discarded.
        //
        // v4 Phase C FIX: the marker still has to be released. This early
        // return skipped `outbox.recordFailure(id:)`, which is the only call
        // that clears `inFlightID` — so from the first offline attempt until
        // the app relaunched the head stayed flagged in flight, and collapsing
        // never touches an in-flight item. Undo tapped after a failed create
        // then appended a delete BEHIND the create instead of cancelling it,
        // and on reconnect the circle was shown a prayer the user had already
        // retracted. Releasing costs nothing: the attempt counter is what must
        // stay unspent, not the exclusivity flag.
        guard !mapped.isOffline else {
            outbox.releaseInFlight()
            return false
        }
        guard state.refusals <= CircleSyncTuning.recordedFailureCap else {
            // The cap is one below the outbox's own, so an item is discarded
            // HERE, on purpose and countably, rather than vanishing inside the
            // queue while nobody is looking. Everything behind it can now move.
            discard(item, reason: mapped)
            return true
        }
        outbox.recordFailure(id: item.id)
        return false
    }

    /// What an acknowledgement means to the rest of the app.
    ///
    /// v4 Phase D FIX: `.upsertPost` used to fall through the guard below and
    /// tell nobody, so `PushRegistrar.announcePost` — the whole client half of
    /// §6's headline push — had no call site anywhere in `Sources/`. Two phones
    /// in a real circle with "Friend activity" on: A logs Fajr, the post uploads
    /// and is acked, B's phone never buzzes, and the server's `kind: "post"`
    /// path was never once exercised in the shipping app. This is the one place
    /// a post is known to be on the server, which is what `announcePost`
    /// requires (the function answers `post_not_found` for a row that isn't
    /// there yet).
    private func applyAcknowledged(_ op: CircleOp) {
        switch op {
        case .upsertPost(let post):
            announceIfLive(post)
        case .deleteChallenge(let challengeID):
            removeAcknowledgedChallenge(challengeID)
        default:
            return
        }
    }

    /// Fire-and-forget, exactly like the nudge chip: a push is garnish on an
    /// action that has already succeeded, nothing waits for it, and no failure
    /// is ever shown. Deliberately NOT gated on this device's friend-activity
    /// toggle — that is a RECEIVING preference the server applies per recipient,
    /// and muting your own would otherwise silence every friend who asked for it.
    private func announceIfLive(_ post: RemotePost) {
        guard announceablePostIDs.remove(post.id) != nil else { return }
        let postID: UUID = post.id
        if let hook = announcer {
            hook(postID)
            return
        }
        Task { await PushRegistrar.shared.announcePost(postID: postID) }
    }

    /// The one op whose acknowledgement the MIRROR has to hear about.
    ///
    /// v4 Phase C FIX: a custom challenge is the only mirror-backed thing a
    /// person can delete, and `activeCustomChallenges` reads the mirror. Until
    /// the next pull re-read the (complete) challenge list, the row the user
    /// had just removed was still in `circle.json` — so the card came straight
    /// back the moment the delete drained, and `ChallengeEngine` kept scoring
    /// it. `pendingChallengeDeletions` covers the window BEFORE the delete
    /// lands; this covers the window after it lands and before the next pull.
    ///
    /// Nothing else needs this: posts and excused days render your own row from
    /// local state, so the mirror disagreeing about them is invisible.
    private func removeAcknowledgedChallenge(_ challengeID: String) {
        guard let host: any CircleSyncHost = self.host else { return }
        var next: CircleSnapshot = host.syncSnapshot
        let before: Int = next.challenges.count
        // The closure reads only its captured `challengeID`; it never reaches
        // back into `self` while `next.challenges` is being mutated (the
        // exclusivity violation this file has already been bitten by once).
        next.challenges.removeAll { $0.id == challengeID }
        guard next.challenges.count != before else { return }
        host.applySyncedSnapshot(next)
    }

    /// Which of this device's rest days the circle has not been told about.
    ///
    /// Pure, and separated from `AppState` so the rule can be tested without a
    /// Documents directory: local flags minus mirrored flags, clipped to the
    /// pull window (older days are outside every read, so sending them would
    /// write rows nothing will ever fetch) and to today (a break's future days
    /// are not facts yet).
    static func unmirroredExcusedDayKeys(local: Set<String>, mirrored: Set<String>,
                                         startDayKey: String, todayKey: String) -> [String] {
        var result: [String] = []
        for key in local.sorted() {
            guard key >= startDayKey, key <= todayKey else { continue }
            guard !mirrored.contains(key) else { continue }
            result.append(key)
        }
        return result
    }

    /// Challenge ids with a delete still owed to the server.
    ///
    /// `AppState.activeCustomChallenges` subtracts these from the mirror: the
    /// row is still up there until the queue drains, and re-rendering a card
    /// the user removed — offline, where the queue may sit for a day — is the
    /// mirror overruling a local decision that has already been made.
    var pendingChallengeDeletions: Set<String> {
        var ids: Set<String> = []
        for item in outbox.items {
            guard case .deleteChallenge(let challengeID) = item.op else { continue }
            ids.insert(challengeID)
        }
        return ids
    }

    private func discard(_ item: OutboxItem, reason: CircleError) {
        outbox.remove(id: item.id)
        attempts.removeValue(forKey: item.id)
        discardedCount += 1
        lastDiscarded = reason
    }

    /// 2s, 4s, 8s … capped at 5 minutes. No jitter on purpose: one phone's
    /// queue is not a thundering herd, and a deterministic delay is one a test
    /// can assert on.
    static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent: Int = min(attempt - 1, 16)
        let raw: TimeInterval = CircleSyncTuning.retryBaseDelay * pow(2, Double(exponent))
        return min(raw, CircleSyncTuning.retryMaxDelay)
    }

    private func isDue(_ item: OutboxItem) -> Bool {
        guard let state: Attempt = attempts[item.id] else { return true }
        return state.nextAttemptAt <= AppClock.now
    }

    private func scheduleRetry(for item: OutboxItem) {
        guard let state: Attempt = attempts[item.id] else { return }
        let delay: TimeInterval = max(1, state.nextAttemptAt.timeIntervalSince(AppClock.now))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            let nanoseconds: UInt64 = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    /// Forget the WAIT, not the history. The backoff exists to stop us
    /// hammering a network that isn't there; when the network comes back (or a
    /// person taps retry) the delay is stale, but how many times the server has
    /// already refused this write is still true.
    ///
    /// The ids are copied into an array first: mutating `attempts` while
    /// iterating its own `keys` view is overlapping access to the same storage,
    /// which the exclusivity checker rejects outright.
    private func clearBackoff() {
        let ids: [UUID] = Array(attempts.keys)
        for id in ids {
            guard var state: Attempt = attempts[id] else { continue }
            state.nextAttemptAt = .distantPast
            attempts[id] = state
        }
        retryTask?.cancel()
        retryTask = nil
    }

    /// The queued write that is stuck, if there is one. What a "waiting to
    /// sync" row should name.
    var stalledItem: OutboxItem? {
        guard let head: OutboxItem = outbox.peek else { return nil }
        guard let state: Attempt = attempts[head.id] else { return nil }
        guard state.count >= CircleSyncTuning.stallThreshold else { return nil }
        return head
    }

    /// How many times the head has failed. Exposed for the tests and for a
    /// developer card; the UI reads `status`.
    func failureCount(for id: UUID) -> Int {
        attempts[id]?.count ?? 0
    }

    func nextAttemptDate(for id: UUID) -> Date? {
        attempts[id]?.nextAttemptAt
    }

    // MARK: - Pull

    /// Refresh the mirror.
    ///
    /// `since == nil` is the reconciling read: the whole 35-day window, which
    /// also REMOVES rows that vanished server-side. `since != nil` is the cheap
    /// delta realtime uses, which only adds and updates — it cannot see a
    /// deletion, so it must never be trusted to imply one.
    ///
    /// Never throws and never blanks the mirror: a failure commits nothing, so
    /// the circle keeps drawing exactly what the last good sync left.
    @discardableResult
    func pull(since: Date?) async -> Bool {
        guard !isPulling else { return false }
        guard let circleID: UUID = liveCircleID else { return false }
        guard isOnline else {
            refreshStatus()
            return false
        }
        let generation: Int = currentGeneration
        let window: CircleSyncWindow = CircleSyncWindow.window(endingAt: AppClock.now,
                                                               days: CircleSyncTuning.pullWindowDays)
        isPulling = true
        refreshStatus()
        do {
            let page: CircleSyncPage = try await transport.fetch(circleID: circleID,
                                                                 since: since,
                                                                 window: window)
            guard isCurrent(generation, circleID) else {
                isPulling = false
                refreshStatus()
                return true
            }
            commit(page, circleID: circleID, isFullRead: since == nil)
            lastError = nil
        } catch {
            // The mirror is untouched. This is the difference between "you're
            // offline" and "your friends are gone".
            lastError = CircleError.from(error)
        }
        isPulling = false
        refreshStatus()
        // The read HAPPENED — whether it succeeded is `lastError`'s business.
        // What the caller needs to know is only whether its request was
        // swallowed by a guard, so it can put back what it consumed.
        return true
    }

    private func commit(_ page: CircleSyncPage, circleID: UUID, isFullRead: Bool) {
        guard let host: any CircleSyncHost = host else { return }
        let base: CircleSnapshot = host.syncSnapshot
        // A snapshot that has moved on to a different circle is not ours to
        // merge into.
        guard base.circle?.id == circleID else { return }
        var next: CircleSnapshot
        if isFullRead {
            next = CircleSync.merged(base, full: page, circleID: circleID)
        } else {
            next = CircleSync.merged(base, delta: page)
        }
        next.lastSyncedAt = CircleSync.cursor(after: page, previous: base.lastSyncedAt)
        lastSyncedAt = next.lastSyncedAt
        host.applySyncedSnapshot(next)
    }

    /// Where the NEXT delta should start, given the page just read.
    ///
    /// v4 Phase C FIX: this used to be `AppClock.now`, i.e. the device's clock,
    /// and it is handed straight back to PostgREST as `updated_at > <cursor>` —
    /// a column stamped by `now()` inside Postgres. `deltaOverlap` absorbs a
    /// minute of skew and no more, so a phone running further ahead than that
    /// asked for rows from the server's future and got an empty page every
    /// time, forever, with nothing to show for it (an empty read is a success,
    /// so `lastError` was cleared each round). Taking the newest `updated_at`
    /// the server itself sent removes the comparison between two clocks.
    ///
    /// An empty page keeps the previous cursor rather than inventing one: a
    /// quiet minute must not move the window past rows nobody has read yet. A
    /// mirror that has never seen a post therefore stays on `nil`, which makes
    /// the next pull a full read — more expensive, and correct.
    static func cursor(after page: CircleSyncPage, previous: Date?) -> Date? {
        var newest: Date? = previous
        let incoming: [RemotePost] = page.posts ?? []
        for post in incoming {
            guard let stamp: Date = post.updatedAt else { continue }
            if let current: Date = newest {
                if stamp > current { newest = stamp }
            } else {
                newest = stamp
            }
        }
        return newest
    }

    /// Where a delta starts. Deliberately backdated (see `deltaOverlap`).
    private func deltaCursor() -> Date? {
        guard let last: Date = host?.syncSnapshot.lastSyncedAt else { return nil }
        return last.addingTimeInterval(-CircleSyncTuning.deltaOverlap)
    }

    // MARK: - Merge (pure)

    /// A delta.
    ///
    /// **`posts` is the only genuinely incremental collection**, and it is the
    /// only one merged additively: `updated_at > since` can report rows that
    /// still exist and nothing else, so a delta has no opinion about a post it
    /// did not mention, and acting on that silence would delete half the circle
    /// every time one person prays.
    ///
    /// v4 Phase C FIX: the other three are NOT incremental and must not be
    /// folded in as if they were. `excused_days` has no `updated_at` at all,
    /// `recovery_weeks` keeps its behind a column grant, and `custom_challenges`
    /// is a handful of rows — so `SupabaseCircleTransport.fetch` reads all three
    /// as COMPLETE WINDOW LISTS on every pass, delta or not (see its comment).
    /// Folding a complete list through an add-only merge threw away exactly the
    /// removals it had just been handed: a buddy tapping "Resume prayers"
    /// deletes their `excused_days` row, that table is deliberately not in the
    /// realtime publication so nothing forces a full read, and the next delta —
    /// triggered by anyone posting — carried the authoritative list WITHOUT
    /// that day while the mirror kept the stale rest day. `excusedDayKeys`
    /// feeds `GameEngine.xp(forDay:)`, which zeroes the perfect-day bonus, so
    /// that device's leaderboard disagreed with the buddy's own until the next
    /// foreground. Assigning is what the page actually means.
    ///
    /// A collection the page did not fetch (`nil`) still keeps whatever the
    /// mirror had — that is what `nil` is for.
    static func merged(_ base: CircleSnapshot, delta page: CircleSyncPage) -> CircleSnapshot {
        var next: CircleSnapshot = base
        if let posts: [RemotePost] = page.posts, !posts.isEmpty {
            next.posts = CircleSync.upserted(posts: base.posts, with: posts)
        }
        if let days: [RemoteExcusedDay] = page.excusedDays {
            next.excusedDays = days
        }
        if let weeks: [RemoteRecoveryWeek] = page.recoveryWeeks {
            next.recoveryWeeks = weeks
        }
        if let challenges: [RemoteCustomChallenge] = page.challenges {
            next.challenges = challenges
        }
        return next
    }

    /// A full read: the window IS the mirror.
    ///
    /// Rows the server no longer has are dropped — that is what makes this the
    /// reconciling read, and it is the only way a post someone deleted on
    /// another device ever leaves this grid. Rows older than the window go too,
    /// which is also what keeps `circle.json` from growing forever; nothing in
    /// the app draws a circle further back than a few weeks.
    ///
    /// A collection the page did not fetch keeps whatever the mirror had.
    static func merged(_ base: CircleSnapshot, full page: CircleSyncPage,
                       circleID: UUID) -> CircleSnapshot {
        var next: CircleSnapshot = base
        if let posts: [RemotePost] = page.posts {
            next.posts = posts
        }
        if let days: [RemoteExcusedDay] = page.excusedDays {
            next.excusedDays = days
        }
        if let weeks: [RemoteRecoveryWeek] = page.recoveryWeeks {
            next.recoveryWeeks = weeks
        }
        if let challenges: [RemoteCustomChallenge] = page.challenges {
            next.challenges = challenges
        }
        if let members: [RemoteMember] = page.members {
            next.members = members.filter { $0.circleID == circleID }
        }
        if let profiles: [RemoteProfile] = page.profiles {
            next.profiles = profiles
        }
        return next
    }

    /// `(user, day, prayer)` — the server's uniqueness key for a post, minus
    /// the circle, which is fixed for everything in one mirror.
    static func slotKey(_ post: RemotePost) -> String {
        "\(post.userID.uuidString)|\(post.dayKey)|\(post.prayer.rawValue)"
    }

    static func upserted(posts base: [RemotePost], with incoming: [RemotePost]) -> [RemotePost] {
        guard !incoming.isEmpty else { return base }
        var incomingIDs: Set<UUID> = []
        var incomingSlots: Set<String> = []
        for post in incoming {
            incomingIDs.insert(post.id)
            incomingSlots.insert(CircleSync.slotKey(post))
        }
        var result: [RemotePost] = []
        result.reserveCapacity(base.count + incoming.count)
        for post in base {
            if incomingIDs.contains(post.id) { continue }
            // Same slot, different row id: someone undid and re-logged that
            // prayer, so the mirrored row is the stale one. Keeping both would
            // put two posts in a cell that can only hold one.
            if incomingSlots.contains(CircleSync.slotKey(post)) { continue }
            result.append(post)
        }
        result.append(contentsOf: incoming)
        return result
    }

    // MARK: - Realtime

    /// One channel per circle, open only while the app is in front AND a real
    /// circle is active.
    ///
    /// v4 Phase C FIX: a failed join is now noticed. `subscribedCircleID` used
    /// to be set BEFORE the join and never cleared while the app stayed in
    /// front, so a channel that failed to open — and it can, because
    /// `sync.start()` and `AuthService.restore()` are two independent launch
    /// tasks with no ordering between them, and a channel joined before the
    /// session is back receives nothing — left this method returning early
    /// forever after. Realtime was simply dead until the app was backgrounded
    /// and re-foregrounded, invisibly. The transport now reports whether it
    /// joined, and a failure puts the id back so the next lifecycle event
    /// (foreground, day change, reconnect, the next drain) tries again.
    private func updateSubscription() async {
        let wanted: UUID? = isForeground ? liveCircleID : nil
        if let wanted: UUID = wanted {
            guard subscribedCircleID != wanted else { return }
            subscribedCircleID = wanted
            let joined: Bool = await transport.startRealtime(circleID: wanted) { [weak self] event in
                self?.realtimeEventArrived(event)
            }
            guard !joined else { return }
            // Only surrender the id if it is still the one we claimed: the
            // circle can change while a join is in flight.
            if subscribedCircleID == wanted { subscribedCircleID = nil }
        } else {
            guard subscribedCircleID != nil else { return }
            subscribedCircleID = nil
            await transport.stopRealtime()
        }
    }

    /// An event arrived. The payload is NOT read — this only decides how soon,
    /// and how thoroughly, to ask the server what actually happened.
    func realtimeEventArrived(_ event: CircleRealtimeEvent) {
        if event == .deleted {
            debouncedPullNeedsFullRead = true
        }
        armDebounce()
    }

    /// Internal rather than private: the interesting part of the debounce is
    /// its DECISION — delta or full read — not its two-second nap, and a test
    /// should be able to assert the decision without sleeping through it.
    func runDebouncedPull() async {
        let needsFull: Bool = debouncedPullNeedsFullRead
        debouncedPullNeedsFullRead = false
        let cursor: Date? = needsFull ? nil : deltaCursor()
        let ran: Bool = await pull(since: cursor)
        guard !ran else { return }
        // v4 Phase C FIX: the flag was consumed BEFORE the pull, and `pull`
        // bails outright when one is already running (the launch full read is
        // six round trips, which on a slow link comfortably outlives a
        // two-second debounce). A friend's undo landing in that gap raised a
        // DELETE, set the flag, watched the debounce fire into a guard, and the
        // "this needs a full read" bit went with it — so the retraction stayed
        // on screen until the next lifecycle full pull. Nothing was asked, so
        // nothing is consumed: put the bit back and try again after the
        // debounce.
        debouncedPullNeedsFullRead = debouncedPullNeedsFullRead || needsFull
        // Re-armed only when the block was TEMPORARY — a pull already in
        // flight. Offline is not: `connectionCameBack` runs a full pull the
        // moment the network returns, which subsumes anything a delete needed,
        // and a 2-second timer ticking through a flight would be a loop that
        // achieves nothing. Having no circle is not temporary either. The flag
        // is restored in every case, so the next event still does the right
        // thing.
        guard isOnline, liveCircleID != nil else { return }
        armDebounce()
    }

    private func armDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            let nanoseconds: UInt64 = UInt64(CircleSyncTuning.realtimeDebounce * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.runDebouncedPull()
        }
    }

    // MARK: - Identity

    private var liveCircleID: UUID? { host?.syncCircleID }
    private var liveUserID: UUID? { host?.syncUserID }
    private var currentGeneration: Int { host?.syncIdentityGeneration ?? 0 }
    private var isOnline: Bool { reachability?.isOnline ?? true }

    private func isCurrent(_ generation: Int, _ circleID: UUID) -> Bool {
        currentGeneration == generation && liveCircleID == circleID
    }

    /// Notice that the circle identity was replaced and re-anchor to it.
    ///
    /// Joining, leaving and signing out all clear `outbox.json` (and the
    /// mirror) through `CircleService`, so anything still in memory here is
    /// addressed to a circle this device is no longer in. Re-reading from disk
    /// is how the queue finds that out — the generation counter is a fact the
    /// host already keeps, which beats a hand-wired "and don't forget to tell
    /// the sync layer" call somebody eventually forgets.
    private func reanchorIfIdentityChanged() {
        let generation: Int = currentGeneration
        guard let seen: Int = lastSeenGeneration else {
            lastSeenGeneration = generation
            return
        }
        guard seen != generation else { return }
        lastSeenGeneration = generation
        attempts.removeAll()
        // Whatever was owed belonged to the circle (or the account) that just
        // went away — including a push that would have named it.
        announceablePostIDs.removeAll()
        retryTask?.cancel()
        retryTask = nil
        outbox = persists ? CircleOutbox.load() : .empty
        lastError = nil
        refreshStatus()
    }

    // MARK: - Bookkeeping

    private func enqueue(_ op: CircleOp) {
        reanchorIfIdentityChanged()
        outbox.enqueue(op, at: AppClock.now)
        persistOutbox()
        refreshStatus()
        kickDrain()
    }

    private func kickDrain() {
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func persistOutbox() {
        guard persists else { return }
        outbox.save()
    }

    private func refreshStatus() {
        pendingCount = outbox.count
        if isDraining || isPulling {
            status = .syncing
            return
        }
        guard pendingCount > 0 else {
            status = .idle
            return
        }
        guard let head: OutboxItem = outbox.peek,
              let state: Attempt = attempts[head.id],
              state.count >= CircleSyncTuning.stallThreshold else {
            status = .pending(count: pendingCount)
            return
        }
        status = .waiting(count: pendingCount, reason: lastError ?? .offline)
    }
}

// MARK: - The post-slot repair patch

/// Exactly the columns `authenticated` may UPDATE on `posts`, minus the two
/// that identify the slot and minus `photo_path`, which the photo op owns.
struct PostSlotPatch: Encodable {
    var tier: LogTier
    var loggedAt: Date
    var jamaat: Bool
    var placeLabel: String?
    var travelCombined: Bool

    enum CodingKeys: String, CodingKey {
        case tier
        case loggedAt = "logged_at"
        case jamaat
        case placeLabel = "place_label"
        case travelCombined = "travel_combined"
    }

    /// Hand-written for ONE key. Synthesised `Encodable` emits
    /// `encodeIfPresent` for an Optional, so a correction that DROPS the
    /// place tag omitted `place_label` entirely and the PATCH left the
    /// previous device's stale pill sitting on the row. A repair has to say
    /// what the field is now, and "nothing" is an answer: nil goes out as
    /// JSON `null`. `photo_path` is deliberately still absent — it belongs
    /// to the photo op, which runs after this one, and nulling it here
    /// would let a replayed upsert tombstone a photo that had already
    /// landed.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tier, forKey: .tier)
        try c.encode(loggedAt, forKey: .loggedAt)
        try c.encode(jamaat, forKey: .jamaat)
        if let placeLabel: String = placeLabel {
            try c.encode(placeLabel, forKey: .placeLabel)
        } else {
            try c.encodeNil(forKey: .placeLabel)
        }
        try c.encode(travelCombined, forKey: .travelCombined)
    }
}

// MARK: - The Supabase transport

/// The only code in the sync layer that names the SDK.
///
/// Two backend facts shape almost everything here, and both come from
/// `backend/supabase/migrations/`:
///
/// 1. **Column-scoped grants.** `excused_days` and `recovery_weeks` grant
///    SELECT on named columns only (their timestamps are private — an excused
///    row's `created_at` pins the minute a break started). `select("*")` would
///    ask for a column we hold no privilege on and be refused outright, so
///    every read of those two tables names its columns. For the same reason
///    every write asks for `returning: .minimal`: `return=representation`
///    replies with the whole row.
/// 2. **No UPDATE grant on identity columns.** `posts` grants UPDATE on the
///    mutable columns only — not `id`, `user_id` or `circle_id`. A merging
///    upsert compiles to `ON CONFLICT DO UPDATE SET` over *every* key in the
///    payload, so Postgres refuses it at planning time whether or not a row
///    actually conflicts. Hence insert-with-`ignoreDuplicates` plus an explicit,
///    grant-shaped UPDATE for the one case that needs it.
@MainActor
final class SupabaseCircleTransport: CircleSyncTransport {

    private var channel: RealtimeChannelV2?
    private var listeners: [Task<Void, Never>] = []

    init() {}

    // MARK: Writes

    func perform(_ op: CircleOp, circleID: UUID, userID: UUID) async throws {
        switch op {
        case .upsertPost(let post):
            try await upsertPost(post, circleID: circleID, userID: userID)
        case .deletePost(let postID):
            try await deletePost(postID)
        case .setExcused(let dayKey, let excused):
            try await setExcused(dayKey: dayKey, excused: excused,
                                 circleID: circleID, userID: userID)
        case .setRecoveryWeek(let weekKey, let xp):
            try await setRecoveryWeek(weekKey: weekKey, xp: xp,
                                      circleID: circleID, userID: userID)
        case .upsertChallenge(let challenge):
            try await upsertChallenge(challenge, circleID: circleID, userID: userID)
        case .deleteChallenge(let challengeID):
            try await deleteChallenge(challengeID)
        case .uploadPhoto(_, let dayKey, let prayer, let filename, let path):
            try await uploadPhoto(dayKey: dayKey, prayer: prayer, filename: filename,
                                  path: path, circleID: circleID, userID: userID)
        case .deletePhoto(let path):
            try await deletePhoto(path)
        }
    }

    /// The queued post is re-stamped with the LIVE circle and user before it
    /// goes out: an op can outlive the moment it was made, and the row must
    /// belong to whoever is signed in now, in the circle they are in now.
    private func upsertPost(_ post: RemotePost, circleID: UUID, userID: UUID) async throws {
        var row: RemotePost = post
        row.circleID = circleID
        row.userID = userID
        do {
            let _: PostgrestResponse<Void> = try await Supa.client
                .from("posts")
                .upsert(row, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()
        } catch {
            guard SupabaseCircleTransport.isUniqueViolation(error) else { throw error }
            // Not our row id, but our SLOT: `(user_id, circle_id, day_key,
            // prayer)` is unique, so this prayer is already posted — from
            // another device, or from a create whose acknowledgement we lost.
            // Correcting it in place is both idempotent and grant-shaped.
            try await updatePostSlot(row)
        }
    }

    private func updatePostSlot(_ row: RemotePost) async throws {
        let patch = PostSlotPatch(tier: row.tier, loggedAt: row.loggedAt, jamaat: row.jamaat,
                                  placeLabel: row.placeLabel, travelCombined: row.travelCombined)
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("posts")
            .update(patch, returning: .minimal)
            .eq("user_id", value: row.userID)
            .eq("circle_id", value: row.circleID)
            .eq("day_key", value: row.dayKey)
            .eq("prayer", value: row.prayer.rawValue)
            .execute()
    }

    private func deletePost(_ postID: UUID) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("posts")
            .delete(returning: .minimal)
            .eq("id", value: postID)
            .execute()
    }

    private func setExcused(dayKey: String, excused: Bool,
                            circleID: UUID, userID: UUID) async throws {
        guard excused else {
            let _: PostgrestResponse<Void> = try await Supa.client
                .from("excused_days")
                .delete(returning: .minimal)
                .eq("user_id", value: userID)
                .eq("circle_id", value: circleID)
                .eq("day_key", value: dayKey)
                .execute()
            return
        }
        // Three columns, and there is no fourth for a reason to hide in.
        let row = RemoteExcusedDay(userID: userID, circleID: circleID, dayKey: dayKey)
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("excused_days")
            .upsert(row, onConflict: "user_id,circle_id,day_key",
                    returning: .minimal, ignoreDuplicates: true)
            .execute()
    }

    private func setRecoveryWeek(weekKey: String, xp: Int,
                                 circleID: UUID, userID: UUID) async throws {
        let row = RemoteRecoveryWeek(userID: userID, circleID: circleID,
                                     weekKey: weekKey, xp: max(0, xp))
        // A merging upsert IS allowed here: the UPDATE grant on this table
        // covers all four columns, which it does not on `posts`.
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("recovery_weeks")
            .upsert(row, onConflict: "user_id,circle_id,week_key", returning: .minimal)
            .execute()
    }

    private func upsertChallenge(_ challenge: RemoteCustomChallenge,
                                 circleID: UUID, userID: UUID) async throws {
        var row: RemoteCustomChallenge = challenge
        row.circleID = circleID
        row.createdBy = userID
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("custom_challenges")
            .upsert(row, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
            .execute()
    }

    private func deleteChallenge(_ challengeID: String) async throws {
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("custom_challenges")
            .delete(returning: .minimal)
            .eq("id", value: challengeID)
            .execute()
    }

    /// Storage is `PhotoSync`'s department — it owns the bucket, the multipart
    /// details and the two failures that mean success (409 "already there",
    /// 404 "already gone"). What belongs HERE is the second half: the row only
    /// starts pointing at the object once the object exists, because a
    /// `photo_path` advertised before the bytes land is a 404 for every friend
    /// who opens the grid.
    ///
    /// v4 Phase C FIX: the patch is keyed on the SLOT, not on the post's row
    /// id. See `CircleOp.uploadPhoto` — an `id`-keyed patch silently matched
    /// zero rows whenever `upsertPost` had repaired a slot collision in place,
    /// stranding the JPEG in Storage with nothing pointing at it and nothing
    /// able to collect it. `(user_id, circle_id, day_key, prayer)` is the same
    /// key `updatePostSlot` uses, so it lands on whichever row won the slot;
    /// `posts_tombstone_photo` records whatever path it displaces.
    private func uploadPhoto(dayKey: String, prayer: Prayer, filename: String,
                             path: String, circleID: UUID, userID: UUID) async throws {
        try await PhotoSync.upload(filename: filename, to: path)
        let patch: [String: String] = ["photo_path": path]
        let _: PostgrestResponse<Void> = try await Supa.client
            .from("posts")
            .update(patch, returning: .minimal)
            .eq("user_id", value: userID)
            .eq("circle_id", value: circleID)
            .eq("day_key", value: dayKey)
            .eq("prayer", value: prayer.rawValue)
            .execute()
    }

    private func deletePhoto(_ path: String) async throws {
        try await PhotoSync.delete(path: path)
    }

    /// 23505 — a unique index said no.
    static func isUniqueViolation(_ error: any Error) -> Bool {
        guard let postgrest = error as? PostgrestError else { return false }
        return postgrest.code == "23505"
    }

    // MARK: Reads

    func fetch(circleID: UUID, since: Date?, window: CircleSyncWindow) async throws -> CircleSyncPage {
        var page = CircleSyncPage()
        page.posts = try await fetchPosts(circleID: circleID, since: since, window: window)
        // `excused_days` has no `updated_at` at all and `recovery_weeks` keeps
        // its behind a column grant, so neither can be asked for a delta. Both
        // are tiny — eight members' worth of flags and one integer per week —
        // so the window read IS the cheap read, and `merged(_:delta:)` folds it
        // in additively.
        page.excusedDays = try await fetchExcusedDays(circleID: circleID, window: window)
        page.recoveryWeeks = try await fetchRecoveryWeeks(circleID: circleID, window: window)
        page.challenges = try await fetchChallenges(circleID: circleID)
        // The roster is reconciled by the full read only: it changes rarely, and
        // a delta that returned an empty roster would be read as "everybody
        // left" by a merge that trusted it.
        guard since == nil else { return page }
        page.members = try await fetchMembers()
        page.profiles = try await fetchProfiles()
        return page
    }

    private func fetchPosts(circleID: UUID, since: Date?,
                            window: CircleSyncWindow) async throws -> [RemotePost] {
        var query: PostgrestFilterBuilder = Supa.client
            .from("posts")
            .select()
            .eq("circle_id", value: circleID)
        if let since: Date = since {
            query = query.gt("updated_at", value: SupabaseCircleTransport.timestamp(since))
        } else {
            query = query.gte("day_key", value: window.startDayKey)
        }
        let response: PostgrestResponse<Void> = try await query.execute()
        return try CircleService.decode([RemotePost].self, from: response.data)
    }

    private func fetchExcusedDays(circleID: UUID,
                                  window: CircleSyncWindow) async throws -> [RemoteExcusedDay] {
        let response: PostgrestResponse<Void> = try await Supa.client
            .from("excused_days")
            .select("user_id,circle_id,day_key")
            .eq("circle_id", value: circleID)
            .gte("day_key", value: window.startDayKey)
            .execute()
        return try CircleService.decode([RemoteExcusedDay].self, from: response.data)
    }

    private func fetchRecoveryWeeks(circleID: UUID,
                                    window: CircleSyncWindow) async throws -> [RemoteRecoveryWeek] {
        let response: PostgrestResponse<Void> = try await Supa.client
            .from("recovery_weeks")
            .select("user_id,circle_id,week_key,xp")
            .eq("circle_id", value: circleID)
            .gte("week_key", value: window.startWeekKey)
            .execute()
        return try CircleService.decode([RemoteRecoveryWeek].self, from: response.data)
    }

    private func fetchChallenges(circleID: UUID) async throws -> [RemoteCustomChallenge] {
        let response: PostgrestResponse<Void> = try await Supa.client
            .from("custom_challenges")
            .select()
            .eq("circle_id", value: circleID)
            .execute()
        return try CircleService.decode([RemoteCustomChallenge].self, from: response.data)
    }

    /// RLS scopes both of these to the caller's own circle, so neither needs a
    /// filter — `current_circle_id()` is the filter.
    private func fetchMembers() async throws -> [RemoteMember] {
        let response: PostgrestResponse<Void> = try await Supa.client
            .from("circle_members")
            .select()
            .execute()
        return try CircleService.decode([RemoteMember].self, from: response.data)
    }

    private func fetchProfiles() async throws -> [RemoteProfile] {
        let response: PostgrestResponse<Void> = try await Supa.client
            .from("profiles")
            .select()
            .execute()
        return try CircleService.decode([RemoteProfile].self, from: response.data)
    }

    /// ISO8601 with fractional seconds — what `timestamptz` compares cleanly
    /// against, and what `CircleService.wireDecoder()` reads back.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Realtime

    /// One channel, filtered `circle_id=eq.<id>`, over the tables the backend
    /// actually publishes.
    ///
    /// v4 DECISION (and a deviation worth stating): the brief asks for four
    /// tables; `20260821000600_realtime.sql` publishes TWO. `circle_members`
    /// and `excused_days` are deliberately absent because Realtime cannot apply
    /// RLS to a DELETE — there is no row left to test a policy against — so a
    /// delete is broadcast project-wide reduced to its primary key, and for
    /// those two tables the primary key IS the private fact ("user X was
    /// resting on day Y"). Subscribing to an unpublished table would at best
    /// receive nothing and at worst fail the whole channel. Nothing is lost:
    /// an event here is only a signal to pull, and the pull re-reads the roster
    /// and the rest days anyway.
    @discardableResult
    func startRealtime(circleID: UUID,
                       onEvent: @escaping @Sendable @MainActor (CircleRealtimeEvent) -> Void) async -> Bool {
        await stopRealtime()
        let topic: String = "circle:\(circleID.uuidString.lowercased())"
        let channel: RealtimeChannelV2 = Supa.client.channel(topic)
        let filter: RealtimePostgresFilter = .eq("circle_id", value: circleID)
        // Streams are registered BEFORE subscribing — the SDK requires it.
        let postEvents: AsyncStream<AnyAction> = channel.postgresChange(AnyAction.self,
                                                                       table: "posts",
                                                                       filter: filter)
        let challengeEvents: AsyncStream<AnyAction> = channel.postgresChange(AnyAction.self,
                                                                            table: "custom_challenges",
                                                                            filter: filter)
        // Stored before the await so a `stopRealtime()` that lands while the
        // join is still in flight has something to tear down.
        self.channel = channel
        // `subscribeWithError()` rather than the deprecated `subscribe()`: the
        // latter is literally `try? await subscribeWithError()`, and a join
        // that fails silently is a channel that never delivers an event and
        // never gets retried.
        do {
            try await channel.subscribeWithError()
        } catch {
            if self.channel === channel { self.channel = nil }
            await Supa.client.removeChannel(channel)
            return false
        }
        guard self.channel === channel else { return false }
        listeners.append(Task {
            for await action in postEvents {
                onEvent(SupabaseCircleTransport.signal(for: action))
            }
        })
        listeners.append(Task {
            for await action in challengeEvents {
                onEvent(SupabaseCircleTransport.signal(for: action))
            }
        })
        return true
    }

    func stopRealtime() async {
        for task in listeners {
            task.cancel()
        }
        listeners.removeAll()
        guard let live: RealtimeChannelV2 = channel else { return }
        channel = nil
        await Supa.client.removeChannel(live)
    }

    /// The ONLY thing read off an event. Not `.record`, not `.oldRecord` —
    /// which is why a payload the client cannot decode (or must not trust) can
    /// never become data in this app.
    static func signal(for action: AnyAction) -> CircleRealtimeEvent {
        if case .delete = action {
            return .deleted
        }
        return .changed
    }
}
