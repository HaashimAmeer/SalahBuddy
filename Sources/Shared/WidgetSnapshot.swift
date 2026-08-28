import Foundation

/// v5 §3 — the whole contract between the app and the home screen.
///
/// **This file is compiled into BOTH targets**, and it is the only Swift the
/// widget shares with the app besides `Models.swift` and `Theme.swift`. That is
/// the point: the widget re-derives nothing. No `GameEngine`, no `Adhan`, no
/// `BuddySimulator`, no network, no `Store` — the app decides what this window
/// looks like and writes it here, and the extension is a dumb renderer over the
/// result. Demo and real circles arrive through the identical path (§9-03), so
/// the widget cannot tell them apart and never has to.
///
/// Written by `AppState.publishWidgetSnapshot()` on every state change; read by
/// the widget's timeline provider and nobody else.
///
/// **Tolerant on the way in, like every other persisted model in this repo.**
/// The two processes are versioned SEPARATELY — iOS keeps running the installed
/// widget binary while the app updates underneath it, and the app can be rolled
/// back under a newer widget — so a file with a missing field, an extra field
/// or a `tier` this build has never heard of has to render, not throw. Every
/// field below decodes with a default; the only thing a malformed file costs is
/// the field that was malformed.
struct WidgetSnapshot: Codable, Equatable, Sendable {

    /// The app's clock (`AppClock.now`) when this was written — so a stale file
    /// is legible as stale rather than merely wrong.
    var writtenAt: Date
    /// Which circle wrote it. Rendering does not branch on it (§9-03: demo
    /// renders exactly as real does); it is here so a bug report can say which
    /// world the screenshot came from.
    var mode: CircleMode
    /// The window the home screen is about — open now, or the next one to open.
    /// nil only when the schedule is not computable (Adhan at extreme latitude,
    /// or a first launch before any location is known).
    var window: Window?
    var you: You
    var circle: Circle

    struct Window: Codable, Equatable, Sendable {
        var prayer: Prayer
        var dayKey: String
        var opensAt: Date
        var endsAt: Date
    }

    struct You: Codable, Equatable, Sendable {
        /// Logged this window — in-window or made up, both mean "prayed".
        var logged: Bool
        var streak: Int
    }

    struct Circle: Codable, Equatable, Sendable {
        /// How many of `memberCount` have prayed this window, YOU INCLUDED —
        /// the "3 of 5 prayed" the small and lock-screen families quote.
        var prayedCount: Int
        /// The whole circle, you included. 1 for a solo user.
        var memberCount: Int
        /// Newest first, capped at `WidgetSnapshot.postCap`.
        var posts: [Post]
        /// The §4 nudge targets, which is why this one carries an id and the
        /// posts do not — and why it is NOT simply "everybody who has not
        /// posted". It is empty until the window has been open for half an
        /// hour, and it stays empty for the carry-over isha; the app applies
        /// exactly those gates on the Today screen and this file is where they
        /// reach the home screen (`WidgetSnapshotBuilder.nudgesAllowed`).
        /// Never you (you cannot nudge yourself) and never somebody resting
        /// (§7: a rest day syncs as a bare flag, and nudging a person who has
        /// told you they cannot pray is the exact wrong thing to do with it).
        ///
        /// A window with nobody nudgeable is not a window with nobody left to
        /// pray: `prayedCount`/`memberCount` are the honest count from the
        /// first second.
        var waiting: [Waiting]
    }

    struct Post: Codable, Equatable, Sendable {
        var name: String
        var emoji: String
        var tier: LogTier
        var loggedAt: Date
        /// The `BuddyPhotoCache` key of this post's photo — a filename, never a
        /// path, never bytes. nil when the post has no photo, when the photo is
        /// yours (P3 decides how your own `PhotoStore` file reaches the widget),
        /// and — §7 — whenever this device has REPORTED it. The hide is applied
        /// as the file is written, so a photo hidden in the app can never come
        /// back on the home screen.
        ///
        /// P2 writes it and renders none of it; P3 is what puts a picture on
        /// the other end of this name.
        var thumb: String?
    }

    struct Waiting: Codable, Equatable, Sendable {
        /// The circle member id — `CircleMember.id`, so P4's nudge intent can
        /// name a person without re-deriving the roster.
        var userID: String
        var name: String
        var emoji: String
        /// Session-scoped in demo, server-rate-limited in a real circle. Either
        /// way it is what stops the button offering a nudge that would be
        /// swallowed.
        var nudgedThisWindow: Bool
    }

    // MARK: - Policy

    /// §3: the medium family shows a 4-up row, so four is what gets written.
    /// The cap is applied at WRITE time rather than at render time — a widget
    /// process should never hold more of somebody else's circle than it draws.
    static let postCap: Int = 4

    // MARK: - Timeline arithmetic (pure, shared so the app's tests cover it)

    /// Nothing to wait for (no window, or a file whose window has already
    /// closed and which no foreground has rewritten). An hour, not a minute:
    /// §5-A's budget is ~40–70 reloads a day, and a widget nobody is feeding
    /// must not spend all of it discovering that nothing changed.
    static let stalePeriod: TimeInterval = 60 * 60
    /// Never park longer than this, whatever the file says. Isha's window can
    /// legitimately run nine hours, and a DEBUG clock that has time-travelled
    /// forward can put a boundary days away — this is the guard that keeps such
    /// a file from freezing the home screen until the next launch.
    static let maxWait: TimeInterval = 8 * 60 * 60
    /// And never spin: a boundary one second away is still a whole reload.
    static let minWait: TimeInterval = 60

    /// The dates this snapshot should be RE-RENDERED at, `now` first.
    ///
    /// A window boundary changes what the widget says ("opens 5:12" → "until
    /// 6:42" → "closed") without changing a byte of the file, so those renders
    /// are timeline ENTRIES rather than reloads: WidgetKit draws them from the
    /// snapshot it already has, and the reload budget stays for the reloads
    /// that need fresh data.
    /// The horizon drop is what actually handles a time-travelled file: a
    /// boundary four days out is not scheduled at all, so `reloadDate` falls
    /// through to `stalePeriod` and asks again in an hour rather than parking
    /// until then. `clampedReload` is the backstop under that, not the thing
    /// doing the work — see its note.
    func timelineDates(from now: Date) -> [Date] {
        var dates: [Date] = [now]
        guard let window else { return dates }
        let horizon: Date = now.addingTimeInterval(WidgetSnapshot.maxWait)
        for boundary in [window.opensAt, window.endsAt].sorted() {
            guard boundary > now, boundary <= horizon else { continue }
            dates.append(boundary)
        }
        return dates
    }

    /// Hold a reload target inside the band a widget may wait: never sooner
    /// than `minWait` (a boundary one second away is still a whole reload out
    /// of §5-A's budget), never later than `maxWait`.
    ///
    /// **Honest about which half is load-bearing.** Today only the lower clamp
    /// can bind through `reloadDate`, because `timelineDates` has already
    /// dropped every boundary past the same horizon — the upper one is the
    /// guard that keeps `maxWait` true if that filter is ever relaxed (say to
    /// schedule an entry at a distant window open). A backstop nothing can
    /// reach is a backstop nothing can test, so it is a function of its own and
    /// tested directly rather than only through its caller.
    static func clampedReload(_ target: Date, from now: Date) -> Date {
        let earliest: Date = now.addingTimeInterval(WidgetSnapshot.minWait)
        let latest: Date = now.addingTimeInterval(WidgetSnapshot.maxWait)
        return min(max(target, earliest), latest)
    }

    /// When WidgetKit should come back for a NEW timeline — i.e. re-read the
    /// file. The last boundary worth waiting for, or an hour when there is
    /// nothing to wait for, clamped (see the constants above).
    func reloadDate(from now: Date) -> Date {
        let upcoming: [Date] = timelineDates(from: now).dropFirst().sorted()
        let target: Date = upcoming.last ?? now.addingTimeInterval(WidgetSnapshot.stalePeriod)
        return WidgetSnapshot.clampedReload(target, from: now)
    }

    /// Whether this says the same thing as `other`, ignoring when it was said.
    /// `AppState` publishes on every mutation and most mutations do not move
    /// the home screen; this is what keeps that from being a disk write every
    /// time somebody taps the tasbih counter.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        var mine: WidgetSnapshot = self
        mine.writtenAt = other.writtenAt
        return mine == other
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case writtenAt, mode, window, you, circle
    }

    init(writtenAt: Date, mode: CircleMode, window: Window?, you: You, circle: Circle) {
        self.writtenAt = writtenAt
        self.mode = mode
        self.window = window
        self.you = you
        self.circle = circle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writtenAt = (try? c.decodeIfPresent(Date.self, forKey: .writtenAt))
            ?? Date(timeIntervalSince1970: 0)
        mode = (try? c.decodeIfPresent(CircleMode.self, forKey: .mode)) ?? .demo
        window = (try? c.decodeIfPresent(Window.self, forKey: .window)) ?? nil
        you = (try? c.decodeIfPresent(You.self, forKey: .you)) ?? You(logged: false, streak: 0)
        circle = (try? c.decodeIfPresent(Circle.self, forKey: .circle)) ?? Circle.empty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(writtenAt, forKey: .writtenAt)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encode(you, forKey: .you)
        try c.encode(circle, forKey: .circle)
    }
}

// MARK: - Nested decoders

extension WidgetSnapshot.Window {
    private enum CodingKeys: String, CodingKey { case prayer, dayKey, opensAt, endsAt }

    /// A window is all-or-nothing: without a prayer or its two boundaries there
    /// is nothing to draw and nothing to schedule against, so an incomplete one
    /// throws and the optional above becomes nil. Every OTHER field in this file
    /// degrades to a default; this is the one that cannot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prayer = try c.decode(Prayer.self, forKey: .prayer)
        dayKey = (try? c.decodeIfPresent(String.self, forKey: .dayKey)) ?? ""
        opensAt = try c.decode(Date.self, forKey: .opensAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
    }
}

extension WidgetSnapshot.You {
    private enum CodingKeys: String, CodingKey { case logged, streak }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logged = (try? c.decodeIfPresent(Bool.self, forKey: .logged)) ?? false
        streak = (try? c.decodeIfPresent(Int.self, forKey: .streak)) ?? 0
    }
}

extension WidgetSnapshot.Circle {
    static let empty = WidgetSnapshot.Circle(prayedCount: 0, memberCount: 0,
                                             posts: [], waiting: [])

    private enum CodingKeys: String, CodingKey {
        case prayedCount, memberCount, posts, waiting
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prayedCount = (try? c.decodeIfPresent(Int.self, forKey: .prayedCount)) ?? 0
        memberCount = (try? c.decodeIfPresent(Int.self, forKey: .memberCount)) ?? 0
        posts = (try? c.decodeIfPresent([WidgetSnapshot.Post].self, forKey: .posts)) ?? []
        waiting = (try? c.decodeIfPresent([WidgetSnapshot.Waiting].self, forKey: .waiting)) ?? []
    }
}

extension WidgetSnapshot.Post {
    private enum CodingKeys: String, CodingKey { case name, emoji, tier, loggedAt, thumb }

    /// A tier this build has never heard of still means "they prayed", so it
    /// lands on `.prayed` rather than dropping the post — the count and the
    /// face are the point, and the colour is decoration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🙂"
        tier = (try? c.decodeIfPresent(LogTier.self, forKey: .tier)) ?? .prayed
        loggedAt = (try? c.decodeIfPresent(Date.self, forKey: .loggedAt))
            ?? Date(timeIntervalSince1970: 0)
        thumb = (try? c.decodeIfPresent(String.self, forKey: .thumb)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(emoji, forKey: .emoji)
        try c.encode(tier, forKey: .tier)
        try c.encode(loggedAt, forKey: .loggedAt)
        try c.encodeIfPresent(thumb, forKey: .thumb)
    }
}

extension WidgetSnapshot.Waiting {
    private enum CodingKeys: String, CodingKey { case userID, name, emoji, nudgedThisWindow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = (try? c.decodeIfPresent(String.self, forKey: .userID)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🙂"
        nudgedThisWindow = (try? c.decodeIfPresent(Bool.self, forKey: .nudgedThisWindow)) ?? false
    }
}

// MARK: - The file itself

/// Where `widget.json` lives, and the ONE encoder/decoder pair either process
/// is allowed to use on it.
///
/// The pair is here, together, on purpose: the app encodes and the widget
/// decodes, they are separately compiled binaries that can be different
/// versions of this app, and a date strategy that drifted apart between them
/// would fail silently and completely. Two functions in one file cannot drift.
enum WidgetFile {

    /// The App Group container both processes share (v5 §2). `SharedContainer`
    /// takes its identifier from here rather than the other way round, because
    /// the extension cannot compile `SharedContainer` (it pulls in `PhotoStore`,
    /// `BuddyPhotoCache` and the whole of `Store` behind it) and one spelling of
    /// this string is the difference between a widget that reads the app's data
    /// and one that reads an empty sandbox.
    static let appGroupID: String = "group.org.amacvoters.salahbuddymock"

    static let name: String = "widget.json"

    /// nil when this build is not entitled to the container — a test host, CI,
    /// or a profile that lost the capability. The app then writes into its
    /// Documents fallback (see `Store.directory`) and the widget, which has no
    /// fallback and must not invent one, simply renders its empty state.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var url: URL? {
        containerURL?.appendingPathComponent(name)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        try? encoder().encode(snapshot)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        try? decoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Read the file. Every failure — no container, no file, unreadable bytes,
    /// JSON that is not this — is the same answer: nil, and an empty widget.
    /// A home-screen tile is never the right place to raise an error.
    static func read(at url: URL? = WidgetFile.url) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Write it atomically. Only the app ever calls this; the widget has no
    /// business writing anything (and, until P4's intent, no way to).
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot, to url: URL) -> Bool {
        guard let data: Data = encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
