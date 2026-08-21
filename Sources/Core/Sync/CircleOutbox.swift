import Foundation

// MARK: - Ops

/// One pending write to the backend.
///
/// The scalar ops carry only what identifies the ROW, not who owns it: the
/// circle id and user id are filled in from the live session when the queue
/// drains. Leaving a circle therefore clears the queue rather than re-targeting
/// it — writes owed to a circle you left are meaningless.
///
/// Codable is hand-written with a `kind` discriminator instead of relying on
/// the synthesised form for enums with associated values. The synthesised
/// shape is an implementation detail that has changed between Swift releases;
/// a queue written by an older build has to keep decoding across an update,
/// so the wire format is pinned here in plain sight.
enum CircleOp: Codable, Equatable, Sendable {
    /// The whole row — `id` is the client UUID, which is what makes a replay
    /// idempotent (the upsert lands on the same primary key).
    case upsertPost(RemotePost)
    case deletePost(postID: UUID)
    /// Excused is a BARE FLAG (§3): true inserts the row, false deletes it.
    /// The reason never appears here because it never leaves the device.
    case setExcused(dayKey: String, excused: Bool)
    case setRecoveryWeek(weekKey: String, xp: Int)
    case upsertChallenge(RemoteCustomChallenge)
    case deleteChallenge(challengeID: String)
    /// `filename` is the local `PhotoStore` file; `path` is its
    /// `<circle>/<user>/<uuid>.jpg` destination in Storage.
    case uploadPhoto(postID: UUID, filename: String, path: String)
    /// Retract an object that already reached Storage. Deleting the post ROW
    /// is not enough: the retention sweep enumerates paths from `posts`, so an
    /// object whose row is gone is never collected and stays readable by every
    /// circle member (§4). Undoing a post whose photo has already uploaded
    /// queues this behind the row delete.
    case deletePhoto(path: String)

    enum Kind: String, Codable, Sendable {
        case upsertPost, deletePost, setExcused, setRecoveryWeek
        case upsertChallenge, deleteChallenge, uploadPhoto, deletePhoto
    }

    var kind: Kind {
        switch self {
        case .upsertPost: return .upsertPost
        case .deletePost: return .deletePost
        case .setExcused: return .setExcused
        case .setRecoveryWeek: return .setRecoveryWeek
        case .upsertChallenge: return .upsertChallenge
        case .deleteChallenge: return .deleteChallenge
        case .uploadPhoto: return .uploadPhoto
        case .deletePhoto: return .deletePhoto
        }
    }

    // MARK: Collapse signatures

    // Two ops with the same signature hit the same row with the same kind of
    // write, so keeping both would just replay work. Upserts and deletes get
    // DIFFERENT signatures on purpose — a delete cancels a pending upsert
    // (see `CircleOutbox.enqueue`) rather than quietly replacing it.

    static func upsertPostSignature(_ postID: UUID) -> String {
        "post.upsert:\(postID.uuidString)"
    }

    static func uploadPhotoSignature(_ postID: UUID) -> String {
        "photo:\(postID.uuidString)"
    }

    static func upsertChallengeSignature(_ challengeID: String) -> String {
        "challenge.upsert:\(challengeID)"
    }

    var collapseSignature: String {
        switch self {
        case .upsertPost(let post):
            return CircleOp.upsertPostSignature(post.id)
        case .deletePost(let postID):
            return "post.delete:\(postID.uuidString)"
        case .setExcused(let dayKey, _):
            return "excused:\(dayKey)"
        case .setRecoveryWeek(let weekKey, _):
            return "recovery:\(weekKey)"
        case .upsertChallenge(let challenge):
            return CircleOp.upsertChallengeSignature(challenge.id)
        case .deleteChallenge(let challengeID):
            return "challenge.delete:\(challengeID)"
        case .uploadPhoto(let postID, _, _):
            return CircleOp.uploadPhotoSignature(postID)
        case .deletePhoto(let path):
            return "photo.delete:\(path)"
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind, post, postID, dayKey, excused, weekKey, xp
        case challenge, challengeID, filename, path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognised kind throws — a queue item written by a NEWER build
        // is one this build cannot execute. `CircleOutbox` drops just that item
        // instead of losing the whole queue.
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .upsertPost:
            let post = try c.decode(RemotePost.self, forKey: .post)
            self = .upsertPost(post)
        case .deletePost:
            let postID = try c.decode(UUID.self, forKey: .postID)
            self = .deletePost(postID: postID)
        case .setExcused:
            let dayKey = try c.decode(String.self, forKey: .dayKey)
            let excused: Bool = (try? c.decodeIfPresent(Bool.self, forKey: .excused)) ?? true
            self = .setExcused(dayKey: dayKey, excused: excused)
        case .setRecoveryWeek:
            let weekKey = try c.decode(String.self, forKey: .weekKey)
            let xp: Int = (try? c.decodeIfPresent(Int.self, forKey: .xp)) ?? 0
            self = .setRecoveryWeek(weekKey: weekKey, xp: xp)
        case .upsertChallenge:
            let challenge = try c.decode(RemoteCustomChallenge.self, forKey: .challenge)
            self = .upsertChallenge(challenge)
        case .deleteChallenge:
            let challengeID = try c.decode(String.self, forKey: .challengeID)
            self = .deleteChallenge(challengeID: challengeID)
        case .uploadPhoto:
            let postID = try c.decode(UUID.self, forKey: .postID)
            let filename = try c.decode(String.self, forKey: .filename)
            let path = try c.decode(String.self, forKey: .path)
            self = .uploadPhoto(postID: postID, filename: filename, path: path)
        case .deletePhoto:
            let path = try c.decode(String.self, forKey: .path)
            self = .deletePhoto(path: path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .upsertPost(let post):
            try c.encode(post, forKey: .post)
        case .deletePost(let postID):
            try c.encode(postID, forKey: .postID)
        case .setExcused(let dayKey, let excused):
            try c.encode(dayKey, forKey: .dayKey)
            try c.encode(excused, forKey: .excused)
        case .setRecoveryWeek(let weekKey, let xp):
            try c.encode(weekKey, forKey: .weekKey)
            try c.encode(xp, forKey: .xp)
        case .upsertChallenge(let challenge):
            try c.encode(challenge, forKey: .challenge)
        case .deleteChallenge(let challengeID):
            try c.encode(challengeID, forKey: .challengeID)
        case .uploadPhoto(let postID, let filename, let path):
            try c.encode(postID, forKey: .postID)
            try c.encode(filename, forKey: .filename)
            try c.encode(path, forKey: .path)
        case .deletePhoto(let path):
            try c.encode(path, forKey: .path)
        }
    }
}

// MARK: - Queue item

/// A queued op plus the bookkeeping the drain needs. `id` is the client UUID
/// the drain acknowledges by — it identifies the ATTEMPT, while the op's own
/// ids identify the rows.
struct OutboxItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var op: CircleOp
    var createdAt: Date
    var attempts: Int

    init(id: UUID = UUID(), op: CircleOp, createdAt: Date, attempts: Int = 0) {
        self.id = id
        self.op = op
        self.createdAt = createdAt
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case id, op, createdAt, attempts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        op = try c.decode(CircleOp.self, forKey: .op)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? Date(timeIntervalSince1970: 0)
        attempts = (try? c.decodeIfPresent(Int.self, forKey: .attempts)) ?? 0
    }
}

// MARK: - Queue

/// v4: the offline write queue (SPEC-V4 §3 — "posts created offline upload on
/// reconnect, in order, idempotently").
///
/// A pure value type: it owns ordering and collapsing, and does no I/O beyond
/// the `Store` load/save helpers at the bottom. `CircleService` drives it.
///
/// **Collapsing is the point.** A week offline should not become a hundred
/// redundant writes, so an op that entirely supersedes a queued one takes its
/// PLACE (preserving relative order), and a delete that cancels a never-sent
/// create removes both.
struct CircleOutbox: Codable, Equatable, Sendable {
    private(set) var items: [OutboxItem]

    /// The item the drain currently has on the wire, if any.
    ///
    /// v4 DECISION: **collapsing never touches the in-flight item.** An op that
    /// has been sent may already have been accepted, so cancelling it locally
    /// would leave the two sides disagreeing forever — undo tapped while the
    /// create was mid-flight used to swallow the delete and leave a permanent
    /// row in the circle's feed. Anything that would have collapsed onto the
    /// item being sent is appended fresh instead: one redundant write, and the
    /// final state is still correct.
    private(set) var inFlightID: UUID? = nil

    /// A write that keeps failing must not wedge the queue forever. After this
    /// many tries the op is dropped so everything behind it can drain — losing
    /// one write beats never syncing again.
    static let maxAttempts = 8

    init(items: [OutboxItem] = []) {
        self.items = items
    }

    static let empty = CircleOutbox()

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// The next op to send, left in place until it is acknowledged.
    var peek: OutboxItem? { items.first }

    var inFlightItem: OutboxItem? {
        guard let inFlightID else { return nil }
        return items.first { $0.id == inFlightID }
    }

    // MARK: Mutation

    /// Take the head to send it. It STAYS queued — only `remove(id:)`
    /// acknowledges it — and is marked in flight so a concurrent `enqueue`
    /// can't cancel a write the server may already have taken.
    mutating func checkout() -> OutboxItem? {
        inFlightID = items.first?.id
        return items.first
    }

    mutating func enqueue(_ op: CircleOp, id: UUID = UUID(), at now: Date = AppClock.now) {
        switch op {
        case .deletePost(let postID):
            cancelPhotoUpload(forPost: postID, at: now)
            // A post that never reached the server has nothing to delete —
            // replaying create-then-delete is pure waste, and the delete would
            // find no row. Undo right after logging is the common case.
            if cancelPending(signature: CircleOp.upsertPostSignature(postID)) { return }
        case .deleteChallenge(let challengeID):
            if cancelPending(signature: CircleOp.upsertChallengeSignature(challengeID)) { return }
        default:
            break
        }

        let item = OutboxItem(id: id, op: op, createdAt: now, attempts: 0)
        let signature: String = op.collapseSignature
        // `inFlightID` is read into a local before every `items` closure here
        // and below. A closure that reaches back into `self` touches it while
        // `items` is being accessed, which Swift's exclusivity checking rejects
        // outright when the access is a mutation ("overlapping accesses to
        // 'self.items', but modification requires exclusive access").
        let inFlight: UUID? = inFlightID
        if let index = items.firstIndex(where: {
            $0.op.collapseSignature == signature && $0.id != inFlight
        }) {
            items[index] = item   // in place, so the queue's relative order holds
            return
        }
        items.append(item)
    }

    /// Acknowledge one item (it succeeded, or the server said it was already
    /// there). Safe to call for an id that is no longer queued.
    mutating func remove(id: UUID) {
        if inFlightID == id { inFlightID = nil }
        items.removeAll { $0.id == id }
    }

    mutating func recordFailure(id: UUID) {
        if inFlightID == id { inFlightID = nil }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].attempts += 1
        if items[index].attempts >= CircleOutbox.maxAttempts {
            items.remove(at: index)
        }
    }

    mutating func removeAll() {
        items.removeAll()
        inFlightID = nil
    }

    /// A photo for a post that is going away is moot — UNLESS its upload is
    /// already on the wire, in which case the object can still land in Storage
    /// after the row is deleted, where the retention sweep (which enumerates
    /// paths from `posts`) will never find it. That one case queues an explicit
    /// `.deletePhoto` behind the upload, because a retracted photo must not
    /// stay readable by the circle (§4).
    private mutating func cancelPhotoUpload(forPost postID: UUID, at now: Date) {
        let signature: String = CircleOp.uploadPhotoSignature(postID)
        if let sending: OutboxItem = inFlightItem,
           sending.op.collapseSignature == signature,
           let path: String = CircleOutbox.photoPath(of: sending.op) {
            items.append(OutboxItem(op: .deletePhoto(path: path), createdAt: now))
        }
        let inFlight: UUID? = inFlightID
        items.removeAll { $0.op.collapseSignature == signature && $0.id != inFlight }
    }

    private static func photoPath(of op: CircleOp) -> String? {
        guard case .uploadPhoto(_, _, let path) = op else { return nil }
        return path
    }

    /// Drops the queued op with `signature`, reporting whether there was one.
    /// The caller uses the answer to decide whether the cancelling op still has
    /// work left to do on the server. An in-flight op is never dropped, so the
    /// cancelling op falls through and is queued behind it.
    private mutating func cancelPending(signature: String) -> Bool {
        let inFlight: UUID? = inFlightID
        guard let index = items.firstIndex(where: {
            $0.op.collapseSignature == signature && $0.id != inFlight
        }) else {
            return false
        }
        items.remove(at: index)
        return true
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case items
    }

    /// Skips items it cannot decode instead of throwing, so one op from a newer
    /// build (or one corrupt entry) costs that op and not the whole queue —
    /// `Store.load` would otherwise fall back to an EMPTY outbox.
    private struct LossyItem: Decodable {
        let item: OutboxItem?
        init(from decoder: Decoder) throws {
            item = try? OutboxItem(from: decoder)
        }
    }

    /// `inFlightID` is deliberately not persisted: a queue reloaded from disk
    /// has nothing on the wire, so every item is collapsible again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw: [LossyItem] = (try? c.decodeIfPresent([LossyItem].self, forKey: .items)) ?? []
        items = raw.compactMap { $0.item }
        inFlightID = nil
    }

    /// Spelled out rather than synthesised: `inFlightID` has no `CodingKeys`
    /// case, and the queue file's shape is a compatibility promise — it should
    /// change only when someone edits this function.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
    }

    // MARK: Persistence

    static func load() -> CircleOutbox {
        Store.load(Store.outboxFile, default: .empty)
    }

    func save() {
        Store.save(self, to: Store.outboxFile)
    }

    static func clear() {
        Store.delete(Store.outboxFile)
    }
}
