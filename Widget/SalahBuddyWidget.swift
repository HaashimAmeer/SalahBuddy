import SwiftUI
import WidgetKit

/// v5 §3 — the widget process.
///
/// It renders `widget.json` out of the shared container and does **nothing
/// else**. No `GameEngine`, no Adhan, no `BuddySimulator`, no network, no
/// Supabase client, no `Store`: the only app code this target compiles is
/// `Models.swift` (value types), `Theme.swift` (the palette) and
/// `WidgetSnapshot.swift` (the file's shape). If a number is wrong on the home
/// screen it is wrong in the file, and the file has one writer.
///
/// There is no `AppClock` here either, and there cannot be — the debug offset
/// lives in the app's `UserDefaults`, which is a different process's. Time in
/// this target comes from the timeline: `Date()` appears exactly twice below,
/// where WidgetKit demands a starting point, and every VIEW reads its entry's
/// own `date` instead. That is also what makes a window boundary free (see
/// `WidgetSnapshot.timelineDates`).
@main
struct SalahBuddyWidgets: WidgetBundle {
    var body: some Widget {
        CircleWidget()
    }
}

// MARK: - Configuration

struct CircleWidget: Widget {
    static let kind: String = "SalahBuddyCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CircleWidget.kind, provider: CircleTimelineProvider()) { entry in
            CircleWidgetView(entry: entry)
        }
        .configurationDisplayName("Your circle")
        .description("This prayer's window, and who in your circle has prayed.")
        // §3's table, minus the two families that need what P2 does not have:
        // systemLarge wants a week grid, and every photo is P3.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct CircleWidgetEntry: TimelineEntry {
    let date: Date
    /// nil when there is no file to read — a fresh install, or a build with no
    /// App Group entitlement. The view has an honest state for it.
    let snapshot: WidgetSnapshot?
}

/// Re-reads the file and schedules the next look.
///
/// Two mechanisms, per §5, and they do different jobs:
///
/// - **Entries** at the window's boundaries. The wording changes at `opensAt`
///   and again at `endsAt` while the DATA does not, so those renders come out
///   of the timeline WidgetKit already holds and cost nothing.
/// - **`.after(…)`** at the last of those boundaries, which is the only thing
///   that gets the file re-read without the app running. §5-A's budget is
///   ~40–70 reloads a day; five windows is five, and the app spends one more
///   each time it goes to the background.
///
/// What is NOT here is any way for a friend's post to reach this by itself —
/// §5 is explicit that no such API exists for a home-screen widget. P3's
/// notification service extension is the answer, and P4's Live Activity is the
/// better one.
struct CircleTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> CircleWidgetEntry {
        CircleWidgetEntry(date: Date(), snapshot: WidgetSnapshot.placeholder)
    }

    /// The gallery and the widget picker both land here. They must never show
    /// somebody's real circle to a screenshot, and they must never show an
    /// empty tile to somebody deciding whether to add one — so a preview gets
    /// the sample and everything else gets the truth.
    func getSnapshot(in context: Context, completion: @escaping (CircleWidgetEntry) -> Void) {
        let snapshot: WidgetSnapshot? = context.isPreview ? WidgetSnapshot.placeholder
                                                          : WidgetFile.read()
        completion(CircleWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CircleWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot: WidgetSnapshot? = WidgetFile.read()
        let dates: [Date] = snapshot?.timelineDates(from: now) ?? [now]
        let entries: [CircleWidgetEntry] = dates.map {
            CircleWidgetEntry(date: $0, snapshot: snapshot)
        }
        let reload: Date = snapshot?.reloadDate(from: now)
            ?? now.addingTimeInterval(WidgetSnapshot.stalePeriod)
        completion(Timeline(entries: entries, policy: .after(reload)))
    }
}

// MARK: - Sample

extension WidgetSnapshot {

    /// What the gallery shows. Invented people on an invented afternoon —
    /// never a read of anybody's real circle, which is the one thing a
    /// placeholder must not be.
    static var placeholder: WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(
            writtenAt: now,
            mode: .demo,
            window: Window(prayer: .asr, dayKey: "",
                           opensAt: now.addingTimeInterval(-45 * 60),
                           endsAt: now.addingTimeInterval(2 * 3600)),
            you: You(logged: true, streak: 12),
            circle: Circle(
                prayedCount: 3,
                memberCount: 5,
                posts: [
                    Post(name: "Mina", emoji: "🌸", tier: .onTime,
                         loggedAt: now.addingTimeInterval(-5 * 60), thumb: nil),
                    Post(name: "You", emoji: "😄", tier: .onTime,
                         loggedAt: now.addingTimeInterval(-18 * 60), thumb: nil),
                    Post(name: "Yusuf", emoji: "🧢", tier: .prayed,
                         loggedAt: now.addingTimeInterval(-32 * 60), thumb: nil),
                ],
                waiting: [
                    Waiting(userID: "sample-1", name: "Harun", emoji: "🎧",
                            nudgedThisWindow: false),
                    Waiting(userID: "sample-2", name: "Sara", emoji: "🌙",
                            nudgedThisWindow: false),
                ]))
    }
}
