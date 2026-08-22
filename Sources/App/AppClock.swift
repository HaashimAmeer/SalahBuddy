import Foundation

/// Global clock. ALL time reads in the app go through `AppClock.now` so the
/// DEBUG time-travel controls work everywhere. Never use `Date()` directly.
enum AppClock {
    private static let offsetKey = "debug.timeOffset"
    private static let timeTravelKey = "debug.timeTravelAllowed"

    /// v4: whether the developer clock may leave real time (SPEC-V4 §3).
    /// False while a REAL circle is active — posting fictional timestamps to
    /// real friends breaks everything time travel exists to test. `AppState`
    /// sets it from `settings.circleMode`; demo mode keeps full time travel.
    /// Persisted (and absent → true) so the guard holds from the first read of
    /// launch, before `AppState` has booted.
    static var isTimeTravelAllowed: Bool {
        get { UserDefaults.standard.object(forKey: timeTravelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: timeTravelKey) }
    }

    /// Debug time-travel offset, persisted in UserDefaults.
    static var offset: TimeInterval {
        get { UserDefaults.standard.double(forKey: offsetKey) }
        set {
            // A pinned clock refuses every move EXCEPT back to real time, so
            // entering a real circle can always clear a stale offset.
            guard isTimeTravelAllowed || newValue == 0 else { return }
            UserDefaults.standard.set(newValue, forKey: offsetKey)
        }
    }

    /// The app's notion of "now".
    static var now: Date { Date().addingTimeInterval(offset) }

    /// The device's current UTC offset, in seconds.
    ///
    /// Lives here rather than at call sites for the same reason `now` does:
    /// every notion of "when and where" the app has should come from one
    /// place. Read `for: now` so a time-travelled clock lands on the right
    /// side of a DST boundary.
    static var utcOffsetSeconds: Int { TimeZone.current.secondsFromGMT(for: now) }

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

/// Build/runtime environment checks.
enum BuildEnv {

    /// True when the running build is a TestFlight (beta) install. TestFlight
    /// and the public App Store share one binary; they're told apart at
    /// runtime by the App Store receipt's filename — "sandboxReceipt" for
    /// TestFlight, "receipt" for a production purchase.
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Whether to surface the in-app Developer tools (time travel, demo seed,
    /// reset). On in DEBUG and in TestFlight; off in a public App Store
    /// release — so the very same archive auto-hides them once promoted.
    static var showsDeveloperTools: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }
}
