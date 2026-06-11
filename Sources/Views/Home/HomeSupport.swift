import Foundation

/// Time formatting helpers for the Today screen + onboarding (home-agent owned).
enum HomeTimeFormat {

    /// Compact countdown: "2h 14m", "14m 5s", "45s". Never negative.
    static func countdown(to target: Date, from now: Date) -> String {
        let total = max(0, Int(target.timeIntervalSince(now)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Locale-aware short clock time, e.g. "5:12 AM".
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}
