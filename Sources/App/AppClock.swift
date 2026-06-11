import Foundation

/// Global clock. ALL time reads in the app go through `AppClock.now` so the
/// DEBUG time-travel controls work everywhere. Never use `Date()` directly.
enum AppClock {
    private static let offsetKey = "debug.timeOffset"

    /// Debug time-travel offset, persisted in UserDefaults.
    static var offset: TimeInterval {
        get { UserDefaults.standard.double(forKey: offsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: offsetKey) }
    }

    /// The app's notion of "now".
    static var now: Date { Date().addingTimeInterval(offset) }

    /// Local-calendar day key, "yyyy-MM-dd".
    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Inverse of `dayKey(for:)` — local midnight of that day (nil if malformed).
    static func date(fromDayKey dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return Calendar.current.date(from: comps)
    }
}
