import Foundation

/// Marks a coder as writing to DISK rather than to the wire.
///
/// v4: the remote DTOs are used for both, and the two want different columns.
/// A server-owned column like `custom_challenges.created_at` is deliberately
/// absent from the INSERT grant, so sending it is a refusal — but the local
/// mirror still has to keep it, or every cold launch quietly drops it. One
/// encoder serving both jobs is what made that a silent data loss; this makes
/// the question explicit instead.
extension CodingUserInfoKey {
    static let persistingMirror = CodingUserInfoKey(rawValue: "org.amacvoters.salahbuddy.persistingMirror")!
}

/// Dead-simple JSON persistence in the app's shared container.
/// Corrupt or missing files NEVER crash — they fall back to the default.
enum Store {
    static let profileFile = "profile.json"
    static let logsFile = "logs.json"
    static let settingsFile = "settings.json"
    // v4: the real circle is offline-first — the synced mirror and the pending
    // write queue persist exactly like everything else, so a cold launch with
    // no network renders the circle and still owes the server the same writes.
    static let circleFile = "circle.json"
    static let outboxFile = "outbox.json"

    /// Where everything lived before v5, and where it still lives when the App
    /// Group container is unavailable.
    static let documentsDirectory: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

    /// v5 §2: the App Group container — **the one path every file in this app
    /// derives from**, which is exactly why repointing it is all a widget needs
    /// to be able to read any of this.
    ///
    /// `let`, not `var`: the answer cannot change inside a process, and asking
    /// the container question once is worth more than the computed property's
    /// tidiness — `Store.url(for:)` is on the path of every load and save.
    ///
    /// The fallback is not defensive decoration. `containerURL(…)` answers nil
    /// in a test host without the entitlement, on CI, and in a build whose
    /// profile lost the capability; falling back to Documents means those
    /// builds behave exactly like v4 instead of launching into an empty app.
    /// `SharedContainer.prepareOnLaunch()` sees the same two URLs and declines
    /// to record a migration it did not perform.
    static let directory: URL = SharedContainer.resolveDirectory(
        group: SharedContainer.containerURL,
        fallback: Store.documentsDirectory)

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Load `filename`, falling back to `defaultValue` on missing file,
    /// unreadable data, or corrupt/incompatible JSON.
    static func load<T: Decodable>(_ filename: String, default defaultValue: T) -> T {
        let fileURL = url(for: filename)
        guard let data = try? Data(contentsOf: fileURL) else { return defaultValue }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.persistingMirror] = true
        guard let value = try? decoder.decode(T.self, from: data) else { return defaultValue }
        return value
    }

    static func save<T: Encodable>(_ value: T, to filename: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.userInfo[.persistingMirror] = true
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: filename), options: .atomic)
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }
}
