import SwiftUI

/// Mascot (~120pt) with a speech bubble — countdown to next prayer,
/// encouragement, and mood logic per spec §4.
struct HomeMascotSection: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            MascotView(mood: mood, size: 120)
            speechBubble
            Spacer(minLength: 0)
        }
        .animation(Theme.spring, value: mood)
    }

    private var speechBubble: some View {
        Text(speech)
            .font(Theme.rounded(15, .semibold))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
            )
            .overlay(alignment: .leading) {
                HomeBubbleTail()
                    .fill(Theme.card)
                    .frame(width: 10, height: 18)
                    .offset(x: -9)
            }
    }

    // MARK: - Mood logic

    private var mood: MascotMood {
        // Celebrating: within ~4s of a log.
        if let lastLoggedAt = state.logs.map(\.loggedAt).max(),
           lastLoggedAt <= now, now.timeIntervalSince(lastLoggedAt) < 4 {
            return .celebrating
        }
        // Worried: an open window is unlogged with <30 min left.
        if mostUrgentOpen != nil, let (_, closesAt) = mostUrgentOpen,
           closesAt.timeIntervalSince(now) < 30 * 60 {
            return .worried
        }
        // Sleepy: before fajr, or 2h+ after isha starts.
        if isSleepyTime { return .sleepy }
        // Happy: 3+ in-window prayers today.
        if inWindowTodayCount >= 3 { return .happy }
        return .neutral
    }

    private var isSleepyTime: Bool {
        guard let schedule = state.todaySchedule,
              let fajr = schedule.window(for: .fajr),
              let isha = schedule.window(for: .isha) else { return false }
        if now < fajr.start { return true }
        if now > isha.start.addingTimeInterval(2 * 3600) { return true }
        return false
    }

    private var inWindowTodayCount: Int {
        state.todayLogs.filter { $0.tier.isInWindow }.count
    }

    /// Open (unlogged) prayer whose window closes soonest.
    private var mostUrgentOpen: (prayer: Prayer, closesAt: Date)? {
        Prayer.allCases
            .compactMap { prayer -> (Prayer, Date)? in
                if case .open(let closesAt) = state.status(of: prayer) {
                    return (prayer, closesAt)
                }
                return nil
            }
            .min { $0.1 < $1.1 }
    }

    /// Next prayer that hasn't opened yet.
    private var nextUpcoming: (prayer: Prayer, opensAt: Date)? {
        Prayer.allCases
            .compactMap { prayer -> (Prayer, Date)? in
                if case .upcoming(let opensAt) = state.status(of: prayer) {
                    return (prayer, opensAt)
                }
                return nil
            }
            .min { $0.1 < $1.1 }
    }

    // MARK: - Speech

    private var speech: String {
        switch mood {
        case .celebrating:
            return "Yes! That one counts. Keep it going! 🎉"

        case .worried:
            if let urgent = mostUrgentOpen {
                return "Hurry — \(urgent.prayer.displayName) closes in \(HomeTimeFormat.countdown(to: urgent.closesAt, from: now))! 😟"
            }
            return "Time's running out — don't miss it!"

        case .sleepy:
            if let fajr = state.todaySchedule?.window(for: .fajr), now < fajr.start {
                return "Fajr in \(HomeTimeFormat.countdown(to: fajr.start, from: now)). Rest up! 💤"
            }
            return "All quiet for now… time to rest. 💤"

        case .happy, .neutral:
            if let open = mostUrgentOpen {
                return "\(open.prayer.displayName) \(open.prayer.emoji) is open — \(HomeTimeFormat.countdown(to: open.closesAt, from: now)) left. You've got this! 🤲"
            }
            if let next = nextUpcoming {
                let lead = mood == .happy ? "You're on a roll!" : "Stay ready —"
                return "\(lead) \(next.prayer.displayName) \(next.prayer.emoji) in \(HomeTimeFormat.countdown(to: next.opensAt, from: now))."
            }
            if state.todayLogs.count == Prayer.allCases.count {
                return "All five logged — mashallah! ✨"
            }
            return "Every prayer counts — keep going! 🌙"
        }
    }
}

/// Small leftward triangle tail for the mascot's speech bubble.
struct HomeBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
