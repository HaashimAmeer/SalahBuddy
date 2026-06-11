import Foundation

/// Dead-simple JSON persistence in the app's Documents directory.
/// Corrupt or missing files NEVER crash — they fall back to the default.
enum Store {
    static let profileFile = "profile.json"
    static let logsFile = "logs.json"
    static let settingsFile = "settings.json"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

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
        guard let value = try? decoder.decode(T.self, from: data) else { return defaultValue }
        return value
    }

    static func save<T: Encodable>(_ value: T, to filename: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: filename), options: .atomic)
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }
}
