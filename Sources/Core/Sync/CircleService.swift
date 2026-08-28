import Foundation
import Supabase

/// The slice of the app that `CircleService` is allowed to touch.
///
/// v4 DECISION: **nothing here can reach a log, a streak or an XP total —
/// except one read that §2 requires by name.** §2 promises that leaving a
/// circle "returns to solo mode with all local history intact", and the
/// cheapest way to guarantee a promise is to make the alternative unreachable,
/// so the seam hands over a mirror to render and a mode to render it in.
///
/// Phase C added the third member because §2 also promises the opposite
/// direction — "joining mid-week shows your week-so-far posts to the circle" —
/// and that cannot be done without reading a week of logs. It is spelled as an
/// answer rather than as access, and it is the only opening: see
/// `circleBackfillLogs(forWeekOf:)`.
///
/// `AppState` already implements `applyCircleSnapshot(_:)`; `setCircleMode(_:)`
/// is a one-line wrapper around `settings.circleMode`, whose `didSet` persists
/// and re-applies the time-travel policy.
@MainActor
protocol CircleServiceHost: AnyObject {
    func applyCircleSnapshot(_ snapshot: CircleSnapshot)
    func setCircleMode(_ mode: CircleMode)

    /// The current Mon-start week's own logs, for the join backfill (§2:
    /// "joining mid-week shows your week-so-far posts to the circle").
    ///
    /// v4 DECISION: the fence above gets exactly ONE opening, and it is shaped
    /// as an ANSWER, not as access. It is read-only, it is a single week, the
    /// host decides what to include, and the name says what it is for — none of
    /// which is true of handing over `logs`. §2's promise is about what leaving
    /// a circle *keeps*, and nothing reachable through this could delete a log,
    /// a streak or an XP point.
    ///
    /// Defaulted to empty so a host that has no local history (every test
    /// double) conforms without writing it.
    func circleBackfillLogs(forWeekOf now: Date) -> [PrayerLog]

    /// The same week's EXCUSED day keys, for the same backfill.
    ///
    /// v4 Phase C FIX: the backfill used to hand over logs and nothing else, so
    /// someone who joined a circle mid-period had that week's rest days stay on
    /// their own device — and every empty cell rendered to their new circle as a
    /// plain `.missed`. §3 promises the gentle "resting" state, and
    /// `rpcs.sql` calls the alternative out by name as the shaming outcome to
    /// avoid. Bare day keys: there is no reason here either, and there is
    /// nowhere for one to go.
    func circleBackfillExcusedDayKeys(forWeekOf now: Date) -> [String]
}

extension CircleServiceHost {
    func circleBackfillLogs(forWeekOf now: Date) -> [PrayerLog] { [] }
    func circleBackfillExcusedDayKeys(forWeekOf now: Date) -> [String] { [] }
}

/// v4 Phase B3: real circles — create, join, leave, rename (SPEC-V4 §2).
///
/// Owns the offline mirror, the pending-write queue and every circle RPC. Two
/// rules shape all of it:
///
/// 1. **The mirror is the source of truth for rendering.** `RemoteCircleDataSource`
///    answers the Today grid, the week grid and the scoreboard from
///    `CircleSnapshot` alone, so a failed network call must leave the mirror
///    exactly as it was. Every method below either applies a change the server
///    has already confirmed, or changes nothing at all — a refresh that fails
///    surfaces a soft error and the circle keeps drawing.
/// 2. **Local history is not reachable from here.** See `CircleServiceHost`.
///
/// Networking lives in this one file (plus `AuthService`) so an SDK API that
/// needs fixing is fixed in one place — the sandbox that writes this code
/// cannot compile Swift, and CI is a ten-minute round trip.
@MainActor
final class CircleService: ObservableObject {

    /// What the circle screens are looking at right now. `working` is a
    /// transient overlay on the other three rather than a state of its own —
    /// `syncPhase()` re-derives the resting phase the moment an operation ends,
    /// including when it ends by failing.
    enum Phase: Equatable {
        case signedOut
        case noCircle
        case inCircle
        case working
    }

    /// How the user came to be in this circle. Phase C's backfill wants the
    /// difference: joining mid-week has a week of your posts the circle has
    /// never seen, whereas creating one starts a circle nobody else is in yet.
    enum CircleEntry: Equatable {
        case created
        case joined
    }

    // MARK: - Published state

    /// The offline mirror. Persisted on every change so a cold launch in
    /// airplane mode draws the same circle the last sync left.
    @Published private(set) var snapshot: CircleSnapshot

    /// Writes owed to the server. Phase B3 only ever CLEARS this (leaving a
    /// circle); Phase C fills and drains it.
    @Published private(set) var outbox: CircleOutbox

    @Published private(set) var phase: Phase = .signedOut

    /// The last failure, in the app's voice. Cleared when a new attempt starts,
    /// so a stale complaint never outlives the thing it was complaining about.
    @Published var lastError: CircleError?

    // MARK: - Injected collaborators

    /// Who is signed in. A closure rather than a stored `AuthService` so this
    /// type can be exercised without an auth stack, a session or a network —
    /// see the `init(auth:)` convenience at the bottom of the file, which is
    /// the only code here that names `AuthService` at all.
    var currentUserID: () -> UUID?

    /// Wired to `AppState` by the app; nil in tests.
    weak var host: (any CircleServiceHost)?

    /// **Phase C hooks the join-week backfill here** (SPEC-V4 §2: "joining
    /// mid-week shows your week-so-far posts to the circle"). It runs after the
    /// circle is applied locally — so `circleMode` is already `.real` and the
    /// snapshot already knows the circle id — and before the first pull, which
    /// is exactly the window in which this week's `PrayerLog`s should be turned
    /// into posts and queued on the outbox.
    ///
    /// Fired for `.created` as well as `.joined` on purpose: a circle founded
    /// on Thursday should show its founder's week to whoever joins on Friday,
    /// and that only works if the week went up when the circle did.
    var joinWeekBackfill: ((RemoteCircle, CircleEntry) async -> Void)?

    /// The session belongs to `AuthService`, so `signOutAndReset()` delegates
    /// the sign-out itself and only takes care of the circle state.
    var signOutHandler: (() async -> Void)?

    // MARK: - Internals

    /// v4 DECISION: persistence is a flag, not a protocol. The mirror and the
    /// queue have exactly one home on disk (`Store`), and the only other caller
    /// that will ever exist is a unit test that must not scribble in the app's
    /// Documents directory. A flag says that in one line; a storage protocol
    /// would be three new types saying the same sentence.
    private let persists: Bool

    /// Tracked separately from `phase` because `phase` forgets: once an
    /// operation sets `.working`, only the mirror can say what to fall back to.
    private var isWorking: Bool = false

    /// Bumped every time the local circle identity is deliberately replaced or
    /// torn down: entering a circle, leaving one, adopting a different account,
    /// signing out.
    ///
    /// v4 DECISION: an in-flight `pull()` must not be allowed to commit what it
    /// read BEFORE one of those. `pull()` suspends three times and
    /// `signOutAndReset()` suspends once, both on the main actor, so the two
    /// interleave: without this guard, signing out during a foreground refresh
    /// let the pull resume, write the old account's roster back over the
    /// emptied mirror and call `setCircleMode(.real)` — leaving the app signed
    /// out inside a phantom circle that survived relaunch, since `adoptSession()`
    /// returns early with no session to reconcile against.
    private(set) var identityGeneration: Int = 0

    /// v4 Phase C: the outbox + pull engine (`CircleSync`), or nil until the
    /// app asks for one.
    ///
    /// v4 DECISION: **created on demand, never in `init`.** The engine's
    /// default transport is a real Supabase socket, and this class is built by
    /// unit tests that must not open one — `CircleServiceTests` constructs a
    /// service, applies a join and asserts on the mirror, and every one of
    /// those transitions now tells the engine the identity moved. No caller,
    /// no engine, no request. `CircleStack.start(host:)` calls `ensureSync()`
    /// once at launch; a test injects a stubbed engine through `attachSync(_:)`.
    ///
    /// It lives HERE rather than beside `AppState` because this is where the
    /// mirror lives: `snapshot` is `private(set)`, so an engine hosted on
    /// `AppState` would write a merged snapshot that the next `pull()` — which
    /// rebuilds from this copy — would silently drop.
    ///
    /// `@Published` so the Circle tab's "waiting to sync" row can observe the
    /// engine from the moment the launch sequence builds it; a plain stored
    /// property left that view with nothing to redraw on.
    @Published private(set) var sync: CircleSync?

    // MARK: - Init

    init(snapshot: CircleSnapshot? = nil,
         outbox: CircleOutbox? = nil,
         persists: Bool = true,
         currentUserID: @escaping () -> UUID? = { CircleService.sessionUserID() }) {
        // Spelled out rather than folded into two ternaries: a test hands both
        // collections in explicitly, and the app hands in neither.
        if let snapshot {
            self.snapshot = snapshot
        } else if persists {
            self.snapshot = CircleSnapshot.load()
        } else {
            self.snapshot = CircleSnapshot.empty
        }
        if let outbox {
            self.outbox = outbox
        } else if persists {
            self.outbox = CircleOutbox.load()
        } else {
            self.outbox = CircleOutbox.empty
        }
        self.persists = persists
        self.currentUserID = currentUserID
        syncPhase()
    }

    /// The signed-in user according to the SDK's cached session. Used only as
    /// the default for `currentUserID`; `AuthService` is the real answer once
    /// the app has one.
    ///
    /// `nonisolated` because it is named from a DEFAULT ARGUMENT above, and a
    /// default-value expression is a nonisolated context in Swift 5 language
    /// mode (SE-0411's isolated defaults are Swift 6 only) — the closure formed
    /// there does not inherit this class's `@MainActor`. Safe to hand out:
    /// `AuthClient.currentUser` is itself declared `nonisolated`, and `Supa`
    /// is a plain enum.
    nonisolated static func sessionUserID() -> UUID? {
        Supa.client.auth.currentUser?.id
    }

    /// Whether an operation that started at `generation` as `me` is still
    /// describing the world it started in. Re-checked after every suspension
    /// in `pull()` — see `identityGeneration`.
    func isCurrent(_ generation: Int, _ me: UUID) -> Bool {
        identityGeneration == generation && currentUserID() == me
    }

    // MARK: - The sync engine (v4 Phase C)

    /// Adopt an engine and give it the one hook it needs from this side.
    ///
    /// The backfill closure is wired HERE rather than by the app for the same
    /// reason the engine is owned here: the two halves are useless apart, and a
    /// hook somebody has to remember to connect is a hook that ships
    /// disconnected.
    func attachSync(_ engine: CircleSync) {
        engine.bind(host: self)
        sync = engine
        // SPEC-V4 §2: "joining mid-week shows your week-so-far posts to the
        // circle". `joinWeekBackfill` documented exactly this seam; this fills
        // it. The logs come back through `CircleServiceHost` as an ANSWER — one
        // week, already filtered — rather than as access to local history, so
        // the fence §2 relies on stays a fence (see `circleBackfillLogs`).
        joinWeekBackfill = { [weak self] _, _ in
            guard let self else { return }
            let now: Date = AppClock.now
            let week: [PrayerLog] = self.host?.circleBackfillLogs(forWeekOf: now) ?? []
            let resting: [String] = self.host?.circleBackfillExcusedDayKeys(forWeekOf: now) ?? []
            guard !week.isEmpty || !resting.isEmpty else { return }
            self.sync?.backfillWeek(week, excusedDayKeys: resting, asOf: now)
        }
    }

    /// The engine, built on first use. Idempotent — `CircleStack.start(host:)`
    /// is the one caller, and it hands the result to `AppState` before the
    /// session is restored and asks it to `start()` after.
    @discardableResult
    func ensureSync() -> CircleSync {
        if let existing: CircleSync = sync { return existing }
        let engine: CircleSync = CircleSync(persists: persists)
        attachSync(engine)
        return engine
    }

    /// Tell the engine the circle identity moved — re-anchor the queue against
    /// the outbox this class just rewrote, re-point realtime, reconcile.
    ///
    /// Fire-and-forget because every caller is a LOCAL transition that has
    /// already succeeded: the mirror is correct whether or not the network
    /// answers, and making `applyLeftCircle()` wait on a pull would make
    /// leaving a circle feel like a network operation, which it is not.
    private func kickSync() {
        guard let engine: CircleSync = sync else { return }
        Task { await engine.circleChanged() }
    }

    /// Drop every buddy photo this device has cached.
    ///
    /// SPEC-V4 §4: a buddy's picture is readable only by the circle, and the
    /// three callers are the moments this device stops being in one — leaving,
    /// signing out, and adopting a different account. Your OWN photos are not
    /// touched: they live in `PhotoStore`, they are yours forever, and Memories
    /// still finds every one of them (§2's promise that leaving keeps all local
    /// history).
    ///
    /// Detached because it can be several hundred small files and none of the
    /// callers has any reason to wait for it — the mirror is already gone, so
    /// nothing on screen refers to a single one of them.
    ///
    /// An instance method with the same `persists` guard every other write in
    /// this file has: `CircleServiceTests` builds with `persists: false`
    /// precisely so it never touches Documents, and a `static` version fired a
    /// detached delete at the test host's real `Documents/circlephotos`.
    private func forgetBuddyPhotos() {
        guard persists else { return }
        Task.detached(priority: .utility) {
            BuddyPhotoCache.deleteAll()
        }
    }

    /// Adopt a mirror `CircleSync` merged. Same three steps every other write
    /// in this file takes — store, persist, hand to the views — so the app
    /// keeps exactly ONE mirror, written in one place.
    ///
    /// The guard is not decoration: an engine that read a circle this device
    /// has since left must not put it back.
    func adoptSyncedSnapshot(_ merged: CircleSnapshot) {
        guard merged.circle?.id == snapshot.circle?.id else { return }
        snapshot = merged
        persistSnapshot()
        host?.applyCircleSnapshot(merged)
    }

    // MARK: - Lifecycle

    /// Call once at launch, AFTER `AuthService.restore()` — the session has to
    /// be back before "who is signed in" has an answer.
    ///
    /// Does no work at all for a signed-out user or a solo one: the whole point
    /// of v4 is that a solo install never touches the network.
    func bootstrap() async {
        adoptSession()
        syncPhase()
        guard currentUserID() != nil, snapshot.hasCircle else { return }
        await refresh()
    }

    /// Pull the circle, its members and their profiles.
    ///
    /// Never throws and never blanks the mirror: a failure here is a soft
    /// error over yesterday's perfectly good circle, which is the difference
    /// between "you're offline" and "your friends are gone".
    func refresh() async {
        guard let me: UUID = currentUserID() else {
            syncPhase()
            return
        }
        // v4 §4: launch and every foreground are also when a report filed on a
        // plane gets its second chance. Fire-and-forget — nothing on screen is
        // waiting for it, and the photo it names is already hidden locally.
        // Gated on `persists` for the same reason every other write here is: a
        // unit test must not reach the shared book (or the network through it).
        if persists { PhotoReports.shared.drain() }
        let generation: Int = identityGeneration
        beginWorking()
        do {
            try await pull()
        } catch {
            // A failure that lands after a sign-out or a leave is describing a
            // circle this device has already put down. Surfacing it would show
            // an error banner to somebody who is no longer looking at a circle.
            guard isCurrent(generation, me) else {
                finishWorking()
                return
            }
            record(error)
            return
        }
        finishWorking()
    }

    // MARK: - Circle membership

    /// Create a circle and become member #1. There is no admin role — §2 keeps
    /// the group flat — so this differs from joining only in where the code
    /// comes from.
    func createCircle(name: String, emoji: String) async throws {
        guard let me: UUID = currentUserID() else { throw failWith(CircleService.notSignedIn) }
        beginWorking()
        do {
            let params: [String: String] = ["p_name": name, "p_emoji": emoji]
            // `rpc` throws at CALL time (it encodes the params), so the `try`
            // covers the builder as well as the `execute()`. The response type
            // is spelled out because `execute()` is overloaded on its decoded
            // value, and nothing here decodes one — `decodeCircleRow` does.
            let response: PostgrestResponse<Void> =
                try await Supa.client.rpc("create_circle", params: params).execute()
            let circle: RemoteCircle = try CircleService.decodeCircleRow(from: response.data)
            applyEnteredCircle(circle, me: me)
            await joinWeekBackfill?(circle, .created)
            // A first pull that fails costs nothing: the mirror already knows
            // the circle and that you are in it.
            try? await pull()
            finishWorking()
        } catch {
            record(error)
            throw error
        }
    }

    /// Join by typed or pasted code. The code is normalised (and a malformed
    /// one rejected) before any network call — see `normalizedJoinCode`.
    func joinCircle(code rawCode: String) async throws {
        guard let code: String = CircleService.normalizedJoinCode(rawCode) else {
            throw failWith(CircleService.unknownCode)
        }
        guard let me: UUID = currentUserID() else { throw failWith(CircleService.notSignedIn) }
        beginWorking()
        do {
            let params: [String: String] = ["p_code": code]
            let response: PostgrestResponse<Void> =
                try await Supa.client.rpc("join_circle", params: params).execute()
            let circle: RemoteCircle = try CircleService.decodeCircleRow(from: response.data)
            applyEnteredCircle(circle, me: me)
            await joinWeekBackfill?(circle, .joined)
            try? await pull()
            finishWorking()
        } catch {
            record(error)
            throw error
        }
    }

    /// Leave, and return to solo mode with every local log, photo, streak and
    /// XP point untouched (§2).
    ///
    /// v4 DECISION: this is the ONE method that will not degrade to "do it
    /// locally and sync later". Leaving locally while the server still has you
    /// in the circle would keep showing your friends a member who is gone, and
    /// would make your next join fail with "already in a circle" — an offline
    /// leave is a lie in both directions. So a network failure keeps the
    /// circle and says so, and the user leaves when they have signal.
    func leaveCircle() async throws {
        // Nothing to tell the server: there is no circle to leave, so clearing
        // whatever the mirror is still holding IS the whole operation.
        guard snapshot.hasCircle else {
            applyLeftCircle()
            return
        }
        // A mirrored circle with no session used to clear locally and call it
        // done. It is the same lie as an offline leave, and it is reachable:
        // `AuthService.restore()` drops the id on an expired refresh token while
        // `circle.json` keeps the circle, and the gear that opens this flow is
        // gated on the mirror, not on the session. The `circle_members` row
        // would still be there — the circle would keep showing a member who has
        // gone, and the next sign-in's `pull()` would put them straight back in
        // it. So it gets the same answer an offline leave gets.
        guard currentUserID() != nil else { throw failWith(CircleService.notSignedIn) }
        beginWorking()
        do {
            let _: PostgrestResponse<Void> = try await Supa.client.rpc("leave_circle").execute()
            applyLeftCircle()
            finishWorking()
        } catch {
            record(error)
            throw error
        }
    }

    /// Rename / re-emoji the circle. Any member may — §2 keeps the group flat —
    /// and the server's column grant is what limits an edit to those two fields.
    func renameCircle(name: String, emoji: String) async throws {
        guard currentUserID() != nil else { throw failWith(CircleService.notSignedIn) }
        guard snapshot.hasCircle else { throw failWith(CircleService.notInACircle) }
        beginWorking()
        do {
            let params: [String: String] = ["p_name": name, "p_emoji": emoji]
            let response: PostgrestResponse<Void> =
                try await Supa.client.rpc("rename_circle", params: params).execute()
            let circle: RemoteCircle = try CircleService.decodeCircleRow(from: response.data)
            var next: CircleSnapshot = snapshot
            next.circle = circle
            snapshot = next
            persistSnapshot()
            host?.applyCircleSnapshot(next)
            finishWorking()
        } catch {
            record(error)
            throw error
        }
    }

    /// Sign out and forget the circle on this device. Local history is not
    /// touched — signing out is not a reset, it is the social half going away.
    func signOutAndReset() async {
        // Bumped BEFORE the suspension, not after: signing out is one `await`
        // long, and a `pull()` that resumes inside that window would otherwise
        // still believe it is current and commit the departing account's roster.
        identityGeneration &+= 1
        await signOutHandler?()
        // Not `applyLeftCircle()`: nobody is signed in any more, so the
        // identity goes with the circle. `me` is what makes `isYou` decidable,
        // and a stale one would be inherited by the next account to sign in.
        outbox.removeAll()
        snapshot = .empty
        if persists {
            CircleSnapshot.clear()
            CircleOutbox.clear()
        }
        host?.applyCircleSnapshot(snapshot)
        host?.setCircleMode(.demo)
        lastError = nil
        isWorking = false
        syncPhase()
        kickSync()
        forgetBuddyPhotos()
    }

    /// SPEC-V4 §1: "Delete account". Removes the server's copy of you —
    /// profile, membership, posts, photos, excused days, recovery totals,
    /// custom challenges, nudges and this device's push token — and then puts
    /// the app back exactly where a solo install starts.
    ///
    /// v4 DECISION: **the server first, the local half second, and never the
    /// other way round.** A local wipe followed by a failed RPC would leave a
    /// circle full of posts by somebody the app has forgotten how to sign in
    /// as. So the RPC either commits (it is one plpgsql function, so it is one
    /// transaction) or nothing happened at all and the throw says so.
    ///
    /// The local half is `signOutAndReset()` verbatim, deliberately: everything
    /// deleting an account has to do on this phone — end the session, drop the
    /// mirror and the queue, take down the `devices` row, forget the cached
    /// buddy photos, return to solo mode — is what signing out already does,
    /// and duplicating it is how the two drift. **Nothing here touches local
    /// history**: `CircleServiceHost` has no door to a log, a photo, a streak
    /// or an XP total, so the journey survives the account by construction.
    ///
    /// NOTE: `delete_account()` cannot delete the `auth.users` row itself —
    /// that needs the service-role admin API, which no client may hold. The
    /// sign-out below is what makes the orphaned shell unreachable from this
    /// phone; a scheduled admin sweep removes it server-side (see
    /// `backend/README.md`). Signing back in with the same Apple/Google
    /// identity therefore yields the same uid with nothing attached to it —
    /// a fresh account, which is what deletion promised.
    func deleteAccount() async throws {
        guard currentUserID() != nil else { throw failWith(CircleService.notSignedIn) }
        beginWorking()
        do {
            let _: PostgrestResponse<Void> = try await Supa.client.rpc("delete_account").execute()
        } catch {
            record(error)
            throw error
        }
        await signOutAndReset()
    }

    // MARK: - Local transitions (no network — which is also what makes them testable)

    /// Applied once the server has confirmed the circle. Everything here is
    /// local: mirror, mode, phase.
    func applyEnteredCircle(_ circle: RemoteCircle, me: UUID) {
        identityGeneration &+= 1
        // The mode flips FIRST, and the reason is the very next line: flipping
        // to `.real` is what pins the developer clock to real time (SPEC-V4 §3),
        // and `mirror(entering:)` stamps your own `joinedAt` from `AppClock.now`.
        // In the other order, a developer who time-travelled in demo mode and
        // then joined a real circle wrote a fictional join time into
        // `circle.json` — and both call sites finish with `try? await pull()`,
        // so a failed first pull left it there to mis-order the roster.
        host?.setCircleMode(.real)
        snapshot = CircleService.mirror(entering: circle, me: me, now: AppClock.now)
        persistSnapshot()
        host?.applyCircleSnapshot(snapshot)
        syncPhase()
        // The engine re-anchors, subscribes to the new circle's channel and
        // runs the first reconciling read. Scheduled, so the backfill this
        // method's caller runs next is already queued when the drain starts.
        kickSync()
    }

    /// Applied once the server has confirmed the departure — or when there was
    /// nothing to confirm.
    ///
    /// The outbox goes with the mirror: a queued post, excused day or challenge
    /// is addressed to a circle this device is no longer in, so replaying it
    /// would either be rejected or, worse, land in whatever circle came next.
    func applyLeftCircle() {
        identityGeneration &+= 1
        snapshot = CircleService.mirror(leaving: snapshot)
        outbox.removeAll()
        persistSnapshot()
        persistOutbox()
        host?.applyCircleSnapshot(snapshot)
        host?.setCircleMode(.demo)
        syncPhase()
        // Drops the in-memory queue this method just cleared on disk, and
        // closes the realtime channel — there is no circle to listen to.
        kickSync()
        forgetBuddyPhotos()
    }

    // MARK: - Pure snapshot transitions

    /// The mirror the moment you enter a circle: you, in it, and nothing else.
    ///
    /// Built from `.empty` rather than edited onto the previous one on purpose —
    /// posts, profiles and excused days belonging to a circle you are no longer
    /// in have no business surviving into a new one.
    ///
    /// `now` seeds your own `joinedAt` so the roster has a stable order before
    /// the first pull replaces it with the server's value; it is passed in
    /// rather than read here so this stays a pure function.
    static func mirror(entering circle: RemoteCircle, me: UUID, now: Date) -> CircleSnapshot {
        let mine: RemoteMember = RemoteMember(circleID: circle.id, userID: me, joinedAt: now)
        return CircleSnapshot(circle: circle, me: me, members: [mine])
    }

    /// The mirror after leaving: signed in, in no circle, holding nothing.
    ///
    /// `me` survives deliberately — you are still signed in, and it is what
    /// makes `isYou` decidable the instant you join something else.
    static func mirror(leaving previous: CircleSnapshot) -> CircleSnapshot {
        CircleSnapshot(me: previous.me)
    }

    // MARK: - Invite codes

    /// The migration's alphabet: I/O/0/1 are dropped because a code is read
    /// aloud and typed by hand (`generate_invite_code()` draws from this exact
    /// string, and `join_circle` re-checks the shape server-side).
    static let codeAlphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    static let codeLength: Int = 6

    /// A typed or pasted code, ready for the wire — or nil if it cannot be one.
    ///
    /// Case and the separators people put in a code they read off a message
    /// ("abc-d23", "ABC D23") are noise and are removed. A character outside
    /// the alphabet is NOT: `I`, `O`, `0` and `1` are absent from that alphabet
    /// precisely because they are the ones that get misread, so silently
    /// "correcting" an I to a 1 would send someone confidently into the wrong
    /// circle. It is a rejection, and the sheet says so.
    static func normalizedJoinCode(_ raw: String) -> String? {
        let allowed = Set(codeAlphabet)
        var cleaned: String = ""
        cleaned.reserveCapacity(codeLength)
        for character in raw.uppercased() {
            if character.isWhitespace { continue }
            if CircleService.codeSeparators.contains(character) { continue }
            guard allowed.contains(character) else { return nil }
            cleaned.append(character)
        }
        guard cleaned.count == codeLength else { return nil }
        return cleaned
    }

    /// What the join field should show as the user types: the same cleanup as
    /// `normalizedJoinCode`, but a bad character is dropped instead of failing
    /// the whole string — a text field that refuses to render a keystroke is
    /// a text field that feels broken. Validation is still the normaliser's.
    static func sanitizedCodeInput(_ raw: String) -> String {
        let allowed = Set(codeAlphabet)
        var cleaned: String = ""
        cleaned.reserveCapacity(codeLength)
        for character in raw.uppercased() {
            guard allowed.contains(character) else { continue }
            cleaned.append(character)
            if cleaned.count == codeLength { break }
        }
        return cleaned
    }

    /// Hyphens as typed, as autocorrected, and as underscored.
    private static let codeSeparators: Set<Character> = ["-", "\u{2013}", "\u{2014}", "_"]

    // MARK: - Network

    /// Pull circle + members + profiles into the mirror.
    ///
    /// RLS scopes all three selects to the caller's own circle, so none of them
    /// needs a filter — `current_circle_id()` is the filter.
    private func pull() async throws {
        guard let me: UUID = currentUserID() else { return }
        // Captured before the first suspension; re-checked after each one. See
        // `identityGeneration` for what goes wrong without it.
        let generation: Int = identityGeneration
        // Phase C: a cold install with a restored session has no mirror, so
        // "which circle am I in" is answered for the first time DOWN THERE,
        // by the server, without any local transition to notice it. Without
        // this the engine would never learn there was a circle to sync until
        // the next foreground.
        let previousCircleID: UUID? = snapshot.circle?.id

        let memberResponse: PostgrestResponse<Void> =
            try await Supa.client.from("circle_members").select().execute()
        let allMembers: [RemoteMember] =
            try CircleService.decode([RemoteMember].self, from: memberResponse.data)
        guard isCurrent(generation, me) else { return }

        guard let mine: RemoteMember = allMembers.first(where: { $0.userID == me }) else {
            // A SUCCESSFUL read saying we are in no circle is real news, not a
            // failure: someone left on another device, or the circle was
            // deleted. Reflecting it is the only way out of a phantom circle.
            // (A failed read throws instead, and never reaches here.)
            if snapshot.hasCircle {
                applyLeftCircle()
            } else {
                adoptIdentity(me)
            }
            return
        }

        let circleID: UUID = mine.circleID
        let circleResponse: PostgrestResponse<Void> =
            try await Supa.client.from("circles").select().execute()
        let circles: [RemoteCircle] =
            try CircleService.decode([RemoteCircle].self, from: circleResponse.data)
        let profileResponse: PostgrestResponse<Void> =
            try await Supa.client.from("profiles").select().execute()
        let profiles: [RemoteProfile] =
            try CircleService.decode([RemoteProfile].self, from: profileResponse.data)
        guard isCurrent(generation, me) else { return }

        var next: CircleSnapshot = snapshot
        next.me = me
        // Keep the mirrored circle if the row somehow isn't in the response —
        // losing the name and the invite code over one odd read helps nobody.
        next.circle = circles.first(where: { $0.id == circleID }) ?? next.circle
        next.members = allMembers.filter { $0.circleID == circleID }
        next.profiles = profiles
        // v4 Phase C FIX: `lastSyncedAt` is NOT stamped here. It is
        // `CircleSync.commit`'s cursor — "how far the POSTS are synced" — and
        // this method reads circle_members, circles and profiles and not a
        // single post. `RootView.foregroundCircleSync` runs this first: a
        // roster pull that succeeded followed by a post pull that failed used
        // to leave the cursor advanced anyway, so the next delta asked for
        // `updated_at > <after the outage>` and every post written while the
        // app was backgrounded was skipped until some later full pull.
        snapshot = next
        persistSnapshot()
        host?.applyCircleSnapshot(next)
        // Repairs a mirror/mode disagreement (a restore onto a fresh install,
        // say): if the server says you are in a circle, you are in `.real`.
        host?.setCircleMode(.real)
        if next.circle?.id != previousCircleID { kickSync() }
    }

    // MARK: - Decoding

    /// One decoder for everything that comes off the wire, so a timestamp
    /// cannot decode one way in an RPC result and another in a table read.
    ///
    /// The formatters are built inside the closure rather than captured: the
    /// strategy closure is handed to `JSONDecoder` and may be called from
    /// anywhere, and `ISO8601DateFormatter` is not `Sendable`. A circle carries
    /// a handful of timestamps, so this costs nothing worth measuring.
    static func wireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // PostgREST hands back `timestamptz` as ISO8601 with an offset, and
        // WITH fractional seconds only sometimes. Both parse.
        decoder.dateDecodingStrategy = .custom { innerDecoder in
            let container = try innerDecoder.singleValueContainer()
            let text: String = try container.decode(String.self)

            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date: Date = withFraction.date(from: text) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date: Date = plain.date(from: text) { return date }

            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Not an ISO8601 timestamp: \(text)")
        }
        return decoder
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try CircleService.wireDecoder().decode(type, from: data)
    }

    /// The circle RPCs `return public.circles`, which PostgREST renders as a
    /// bare JSON object. A set-returning function would wrap it in an array —
    /// a server-side detail the client should not be able to get wrong, so
    /// both shapes decode.
    static func decodeCircleRow(from data: Data) throws -> RemoteCircle {
        let decoder: JSONDecoder = CircleService.wireDecoder()
        if let circle: RemoteCircle = try? decoder.decode(RemoteCircle.self, from: data) {
            return circle
        }
        let rows: [RemoteCircle] = try decoder.decode([RemoteCircle].self, from: data)
        guard let first: RemoteCircle = rows.first else { throw CircleService.notInACircle }
        return first
    }

    // MARK: - Errors

    // v4 DECISION: the client's own refusals are spelled as the SAME SQLSTATEs
    // the RPCs raise, and go through `CircleError.from` like everything else.
    // A code rejected here and a code rejected by `join_circle` are the same
    // event to the person typing it, so there is one place in the app that
    // decides what it sounds like.

    static var notSignedIn: PostgrestError {
        PostgrestError(hint: "sign_in_required", code: "SB401", message: "sign in required")
    }

    static var unknownCode: PostgrestError {
        PostgrestError(hint: "unknown_code", code: "SB404", message: "no circle with that code")
    }

    static var notInACircle: PostgrestError {
        PostgrestError(hint: "no_circle", code: "SB404", message: "not in a circle")
    }

    /// Record a failure and hand it back so the caller can `throw` it. Returns
    /// the ORIGINAL error rather than the mapped one so nothing here depends on
    /// `CircleError` being throwable — `lastError` is what the UI reads.
    private func failWith(_ error: Error) -> Error {
        record(error)
        return error
    }

    private func record(_ error: Error) {
        lastError = CircleError.from(error)
        finishWorking()
    }

    // MARK: - Phase

    private func beginWorking() {
        isWorking = true
        lastError = nil
        phase = .working
    }

    private func finishWorking() {
        isWorking = false
        syncPhase()
    }

    /// The resting phase, derived from the two facts that decide it.
    private func syncPhase() {
        if isWorking {
            phase = .working
            return
        }
        guard currentUserID() != nil else {
            phase = .signedOut
            return
        }
        if snapshot.hasCircle {
            phase = .inCircle
        } else {
            phase = .noCircle
        }
    }

    // MARK: - Session

    /// Reconcile the mirror with whoever is actually signed in.
    ///
    /// A mirror belonging to a DIFFERENT account is not stale, it is somebody
    /// else's circle: rendering it would show the new user a roster they are
    /// not part of, and draining its outbox would post their prayers into it.
    private func adoptSession() {
        guard let live: UUID = currentUserID() else { return }
        guard let mirrored: UUID = snapshot.me else {
            adoptIdentity(live)
            return
        }
        guard mirrored != live else { return }
        identityGeneration &+= 1
        snapshot = CircleSnapshot(me: live)
        outbox.removeAll()
        persistSnapshot()
        persistOutbox()
        host?.applyCircleSnapshot(snapshot)
        host?.setCircleMode(.demo)
        kickSync()
        forgetBuddyPhotos()
    }

    /// Stamp the signed-in identity onto a mirror that doesn't have one yet.
    /// Until it lands, `CircleSnapshot.buddyMembers` deliberately answers
    /// nobody — an identity-less mirror cannot tell you from a friend.
    private func adoptIdentity(_ me: UUID) {
        guard snapshot.me != me else { return }
        var next: CircleSnapshot = snapshot
        next.me = me
        snapshot = next
        persistSnapshot()
        host?.applyCircleSnapshot(next)
    }

    // MARK: - Persistence

    private func persistSnapshot() {
        guard persists else { return }
        snapshot.save()
    }

    private func persistOutbox() {
        guard persists else { return }
        outbox.save()
    }
}

// MARK: - CircleSync's host

/// v4 Phase C: what the sync engine synchronises.
///
/// Five members and no more — the same fence `CircleServiceHost` puts around
/// this class, pointed the other way. The engine can read who we are, which
/// circle we are in, the mirror it must merge into, and the generation counter
/// that tells it the answer to the first two just changed. It cannot reach a
/// log, a streak or an XP total, and `applySyncedSnapshot` is the only way it
/// can write anything at all.
extension CircleService: CircleSyncHost {

    /// The MIRROR's identity first, the session's second, and the order is
    /// load-bearing: `circle.json` is on disk before `AuthService.restore()`
    /// has finished, so a prayer logged in the first second of a cold launch
    /// is still queued against the right user instead of being silently
    /// dropped for want of an id. The two can never disagree — `adoptSession()`
    /// wipes a mirror belonging to somebody else rather than reusing it.
    var syncUserID: UUID? { snapshot.me ?? currentUserID() }

    var syncCircleID: UUID? { snapshot.circle?.id }

    var syncSnapshot: CircleSnapshot { snapshot }

    var syncIdentityGeneration: Int { identityGeneration }

    func applySyncedSnapshot(_ snapshot: CircleSnapshot) {
        adoptSyncedSnapshot(snapshot)
    }
}

// MARK: - AuthService binding

/// The only two lines in this file that name `AuthService`, kept together so a
/// change in its shape is a change in one place.
extension CircleService {
    convenience init(auth: AuthService) {
        self.init()
        self.currentUserID = { [weak auth] in
            guard let auth else { return nil }
            return auth.userID
        }
        self.signOutHandler = { [weak auth] in
            guard let auth else { return }
            await auth.signOut()
        }
    }
}

// MARK: - Reported photos (v4 Phase D, §4)

/// What this device has on disk about reports: the photos it hides, and the
/// reports it still owes the server.
///
/// A tolerant decoder like every other persisted model — a file written by an
/// older or newer build must still load, because the alternative is a reported
/// photo quietly coming back.
struct ReportBook: Codable, Equatable {
    /// Storage paths, not post ids. The path is already unique
    /// (`<circle>/<user>/<uuid>.jpg`), it is the exact thing a tile draws, and
    /// keying on it means the hide costs one set lookup at render time instead
    /// of a post lookup per square.
    var hiddenPaths: [String]
    /// Reports written down but not yet accepted by the server.
    var pending: [RemoteReport]

    init(hiddenPaths: [String] = [], pending: [RemoteReport] = []) {
        self.hiddenPaths = hiddenPaths
        self.pending = pending
    }

    static let empty = ReportBook()

    private enum CodingKeys: String, CodingKey {
        case hiddenPaths, pending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenPaths = (try? c.decodeIfPresent([String].self, forKey: .hiddenPaths)) ?? []
        pending = (try? c.decodeIfPresent([RemoteReport].self, forKey: .pending)) ?? []
    }
}

/// The report action behind a buddy's photo (SPEC-V4 §4, App Store guideline
/// 1.2), and the local hide that goes with it.
///
/// Two halves, and the ORDER between them is the whole design:
///
/// 1. **Hide, immediately and locally.** The reporter never sees that photo
///    again — not after a round trip, not after a moderator looks, not after a
///    relaunch. It is a set of Storage paths on disk, consulted by `PhotoSquare`
///    when it resolves a tile's picture, so it costs one lookup and survives
///    every sync (the mirror is REPLACED wholesale by each pull; this is not).
/// 2. **File, best-effort but durable.** The insert is queued in the same file
///    and retried at launch and on every foreground, because a report lost to
///    a tunnel is a report nobody ever reads. It is deliberately NOT a
///    `CircleOp`: the outbox carries writes that change what the CIRCLE sees,
///    in order, and a report changes nothing anybody in the circle can observe.
///
/// Nothing here tells the circle anything. Reporting is private to the reporter
/// and whoever triages the table with the service-role key; blocking someone
/// remains "leave the circle" (§4).
@MainActor
final class PhotoReports: ObservableObject {

    /// The app-wide book. A singleton for the same reason `PushRegistrar` is
    /// one: the call site is a tile buried three views deep in a grid, and
    /// threading a dependency through `PrayerPhotoGrid` to reach it would put
    /// a report parameter on every square that will never file one.
    ///
    /// Deliberately NOT used as a default argument anywhere — a default-value
    /// expression is a nonisolated context in Swift 5 language mode (the trap
    /// `Reachability.shared` documents).
    static let shared: PhotoReports = PhotoReports()

    private static let file = "reports.json"

    /// Published so a future observer redraws; `PhotoSquare` deliberately does
    /// NOT observe it (it flips its own `@State` on the tile it just reported,
    /// which is the only tile that has to change this instant — every other
    /// square catches up on its next render, and after a relaunch they all
    /// read this set).
    @Published private(set) var hiddenPaths: Set<String>

    private var pending: [RemoteReport]
    private let persists: Bool

    /// Who is filing. A closure rather than a reach into the SDK's session, for
    /// the same reason `CircleService.currentUserID` is one: it keeps the
    /// Supabase client — and the session store behind it — out of a unit test.
    /// `sessionUserID()` is `nonisolated` precisely so it can be named from a
    /// default-value expression like this one.
    var currentUserID: () -> UUID? = { CircleService.sessionUserID() }
    /// One drain at a time. `refresh()` fires on launch and on every
    /// foreground, and two overlapping drains would send the same report twice.
    private var isDraining: Bool = false

    /// Transient failures charged against each queued report — see `settles`.
    /// Never persisted: it is retry policy, not the user's data, and the same
    /// separation `CircleSync.attempts` keeps.
    private var attempts: [UUID: Int] = [:]

    /// `persists: false` is the unit-test shape — same flag, same reason as
    /// `CircleService.persists`: there is one book on disk and a test must not
    /// scribble in the app's Documents directory.
    init(persists: Bool = true) {
        self.persists = persists
        let stored: ReportBook = persists ? Store.load(PhotoReports.file, default: .empty) : .empty
        self.hiddenPaths = Set(stored.hiddenPaths)
        self.pending = stored.pending
    }

    // MARK: - Reading

    /// The path a tile should actually draw, or nil when this device has
    /// reported it. Also folds in "no path at all", so callers have one
    /// question to ask instead of two.
    func visiblePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard !hiddenPaths.contains(path) else { return nil }
        return path
    }

    func isHidden(_ path: String) -> Bool { hiddenPaths.contains(path) }

    #if DEBUG
    /// Tests only: forget one hide again.
    ///
    /// The app has no unhide and must not grow one — a report is meant to
    /// stick, and §7 is explicit that a hidden photo coming back is the worst
    /// outcome here. But `shared` is process-wide, so a test that files a
    /// report leaves it in place for every test that runs after it. Same
    /// reasoning, and the same DEBUG fence, as `LocationProvider`'s
    /// `simulateDeviceFix`.
    func forgetHideForTesting(_ path: String) {
        hiddenPaths.remove(path)
    }
    #endif

    /// Reports still owed to the server — for tests, and for anything that
    /// wants to know the queue is empty.
    var pendingCount: Int { pending.count }

    /// The queue itself, read-only. Only `hide` and the drain may change it.
    var pendingReports: [RemoteReport] { pending }

    // MARK: - Writing

    /// Report a buddy's photo: hide it here, then tell the server.
    ///
    /// Returns immediately. The hide is synchronous and already persisted by
    /// the time this returns, which is what lets the tile redraw in the same
    /// frame as the tap.
    func report(_ post: RemotePost, reason: String? = nil) {
        hide(post, reason: reason)
        drain()
    }

    /// The local half on its own — hide the photo and write down what we owe.
    /// Separate from `report` so it is exercisable without a network in sight.
    func hide(_ post: RemotePost, reason: String? = nil) {
        if let path: String = post.photoPath, !path.isEmpty {
            hiddenPaths.insert(path)
            // The bytes go too. They are a disposable cache entry (§4), and
            // leaving them on disk would mean a reported photo still sitting in
            // the cache until retention swept the path that no longer renders.
            // Everywhere, not just the live directory: while the v5 migration
            // is owed there is a second copy in Documents, and SPEC-V5 §7 is
            // explicit that a hidden photo coming back is worse than it never
            // having been hideable.
            if persists { BuddyPhotoCache.removeEverywhere(forRemotePath: path) }
        }
        guard let reporter: UUID = currentUserID() else {
            // No session, no report: `reporter_id = auth.uid()` is the insert
            // policy, so there is nothing to queue. The hide still stands —
            // it is the half the person can actually feel.
            persist()
            return
        }
        // One report per (reporter, post) — the same rule the unique index
        // enforces, applied here so a double-tap never queues twice.
        guard !pending.contains(where: { $0.postID == post.id }) else {
            persist()
            return
        }
        // The subject travels WITH the complaint (§4). `reported_user_id` and
        // `photo_path` are both pinned server-side against the post itself, so
        // this is a copy of the truth rather than a claim — and it is what
        // survives the author tapping undo.
        pending.append(RemoteReport(reporterID: reporter, postID: post.id,
                                    circleID: post.circleID,
                                    reportedUserID: post.userID,
                                    photoPath: post.photoPath,
                                    reason: reason))
        persist()
    }

    /// Try to hand every pending report to the server.
    ///
    /// Fire-and-forget: no caller waits, and nothing on screen depends on the
    /// answer — the photo is already gone from this device either way.
    func drain() {
        guard !pending.isEmpty, !isDraining else { return }
        isDraining = true
        Task { await drainPending() }
    }

    private func drainPending() async {
        defer { isDraining = false }
        // A snapshot of the queue, so a report filed WHILE this runs is left
        // for the next drain rather than being dropped by the rewrite below.
        let queue: [RemoteReport] = pending
        var settled: Set<UUID> = []
        for report in queue {
            let outcome: ReportOutcome = await PhotoReports.send(report)
            if settles(report, outcome: outcome) { settled.insert(report.id) }
        }
        guard !settled.isEmpty else { return }
        pending.removeAll { settled.contains($0.id) }
        for id in settled { attempts.removeValue(forKey: id) }
        persist()
    }

    /// Whether that outcome takes the report OFF the queue.
    ///
    /// v4 Phase D FIX: this used to be `!CircleError.from(error).isOffline` —
    /// i.e. anything that was not a `URLError` settled the report. A 500 from
    /// PostgREST, a paused free-tier project or a reply that failed to decode
    /// all map to `.unknown`, so one transient server hiccup silently threw the
    /// complaint away, after the UI had told the person "we'll… send it to us
    /// to look at". The distinction that matters is the one
    /// `CircleSync.recordFailure` draws: a refusal the server actually uttered
    /// is final, offline costs nothing, and everything else gets a bounded
    /// number of tries.
    private func settles(_ report: RemoteReport, outcome: ReportOutcome) -> Bool {
        switch outcome {
        case .filed, .refused:
            return true
        case .offline:
            // A fortnight in airplane mode must never spend an attempt.
            return false
        case .failed:
            let spent: Int = (attempts[report.id] ?? 0) + 1
            attempts[report.id] = spent
            return spent >= PhotoReports.maxAttempts
        }
    }

    /// What one insert MEANT for the queue.
    enum ReportOutcome: Equatable, Sendable {
        /// The server has it — or already had it (`23505`, the double tap).
        case filed
        /// A refusal it will utter again forever: not in that circle any more,
        /// no session, a post that no longer exists. Nothing to retry.
        case refused
        /// No usable network. Keep it, charge nothing.
        case offline
        /// Something transient — a 5xx, a body we could not read. Keep it, and
        /// charge one of a bounded number of attempts.
        case failed
    }

    /// The same shape of bound `CircleOutbox` puts on a poison write, for the
    /// same reason: a report that cannot be filed must not be retried forever,
    /// and one that CAN must not be lost to a bad afternoon. In memory rather
    /// than on disk — a relaunch is a fresh budget, which is the right bias for
    /// a complaint.
    private static let maxAttempts: Int = CircleOutbox.maxAttempts

    /// Send one report.
    ///
    /// Spelled `send` rather than `file` because this type already has a
    /// `file` constant; `CircleSnapshot` proves the overload is legal, and
    /// proving it twice is not worth a ten-minute CI round trip.
    static func send(_ report: RemoteReport) async -> ReportOutcome {
        do {
            // `returning: .minimal` is NOT optional here: the grant carries no
            // SELECT, RETURNING needs one, and a default `return=representation`
            // insert is refused as a whole statement. No `onConflict` either —
            // see `RemoteReport`.
            let _: PostgrestResponse<Void> = try await Supa.client
                .from("reports")
                .insert(report, returning: .minimal)
                .execute()
            return .filed
        } catch {
            return PhotoReports.outcome(for: error)
        }
    }

    /// Pure, so every branch above is testable without a network.
    static func outcome(for error: any Error) -> ReportOutcome {
        // "You already reported this photo" is the unique index doing its job.
        if SupabaseCircleTransport.isUniqueViolation(error) { return .filed }
        switch CircleError.from(error) {
        case .offline:
            return .offline
        case .notSignedIn, .notInACircle, .notAllowed, .badRequest,
             .unknownCode, .circleFull, .alreadyInACircle:
            return .refused
        case .tooManyAttempts, .unknown:
            return .failed
        }
    }

    private func persist() {
        guard persists else { return }
        let book = ReportBook(hiddenPaths: hiddenPaths.sorted(), pending: pending)
        Store.save(book, to: PhotoReports.file)
    }
}
