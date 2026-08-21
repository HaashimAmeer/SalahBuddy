import Foundation
import Supabase

/// The slice of the app that `CircleService` is allowed to touch.
///
/// v4 DECISION: **two methods, and neither can reach a log, a streak or an XP
/// total.** §2 promises that leaving a circle "returns to solo mode with all
/// local history intact", and the cheapest way to guarantee a promise is to
/// make the alternative unreachable — so the seam through which the service
/// talks to `AppState` simply has no door onto local history. It hands over a
/// mirror to render and a mode to render it in, and that is the whole surface.
///
/// `AppState` already implements `applyCircleSnapshot(_:)`; `setCircleMode(_:)`
/// is a one-line wrapper around `settings.circleMode`, whose `didSet` persists
/// and re-applies the time-travel policy.
@MainActor
protocol CircleServiceHost: AnyObject {
    func applyCircleSnapshot(_ snapshot: CircleSnapshot)
    func setCircleMode(_ mode: CircleMode)
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
        next.lastSyncedAt = AppClock.now
        snapshot = next
        persistSnapshot()
        host?.applyCircleSnapshot(next)
        // Repairs a mirror/mode disagreement (a restore onto a fresh install,
        // say): if the server says you are in a circle, you are in `.real`.
        host?.setCircleMode(.real)
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
