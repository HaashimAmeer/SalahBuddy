import SwiftUI
import WidgetKit

// MARK: - Presentation

/// Everything the three families draw, derived once from one entry.
///
/// PURE, and deliberately so: the extension's whole job is to turn a file into
/// pixels, and every decision it is allowed to make lives in this initialiser.
/// There is no clock read here — `date` is the timeline entry's own date, which
/// is what makes a window boundary a free re-render rather than a reload (see
/// `WidgetSnapshot.timelineDates`).
struct CircleWidgetModel {

    enum Phase {
        /// No file yet: a fresh install, or a build with no App Group.
        case empty
        /// The window has not opened.
        case beforeOpen
        case open
        /// The window closed and the app has not written the next one yet.
        case closed
    }

    let phase: Phase
    let prayer: Prayer?
    let title: String
    /// The one line under the title — "until 6:42 PM", "opens 3:12 PM".
    let timeLine: String
    /// "3 of 5 prayed", or your own standing when there is nobody else.
    let countLine: String
    let posts: [WidgetSnapshot.Post]
    let waiting: [WidgetSnapshot.Waiting]
    let prayedCount: Int
    let memberCount: Int
    let isSolo: Bool
    let youLogged: Bool
    let streak: Int

    init(snapshot: WidgetSnapshot?, date: Date) {
        let circle: WidgetSnapshot.Circle = snapshot?.circle ?? .empty
        posts = circle.posts
        waiting = circle.waiting
        prayedCount = circle.prayedCount
        memberCount = circle.memberCount
        youLogged = snapshot?.you.logged ?? false
        streak = snapshot?.you.streak ?? 0
        // One person in the circle is you, and "0 of 1 prayed" is a strange way
        // to tell somebody they have not prayed yet.
        isSolo = circle.memberCount <= 1

        guard let snapshot, let window = snapshot.window else {
            phase = .empty
            prayer = nil
            title = "SalahBuddy"
            timeLine = "Open the app to get started"
            countLine = ""
            return
        }
        prayer = window.prayer
        title = window.prayer.displayName
        if date < window.opensAt {
            phase = .beforeOpen
            timeLine = "opens \(CircleWidgetModel.time(window.opensAt))"
        } else if date < window.endsAt {
            phase = .open
            timeLine = "until \(CircleWidgetModel.time(window.endsAt))"
        } else {
            phase = .closed
            timeLine = "window closed"
        }
        if isSolo {
            countLine = youLogged ? "Prayed" : "Not yet"
        } else {
            countLine = "\(circle.prayedCount) of \(circle.memberCount) prayed"
        }
    }

    /// 0…1, for the count track. Zero-safe: a circle of nobody has no progress.
    var progress: Double {
        guard memberCount > 0 else { return 0 }
        return min(1, max(0, Double(prayedCount) / Double(memberCount)))
    }

    /// The lock screen gets one line, so it is built rather than laid out.
    var accessoryLine: String {
        guard phase != .empty else { return "SalahBuddy" }
        return countLine.isEmpty ? title : "\(title) · \(countLine)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

// MARK: - The tile

struct CircleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CircleWidgetEntry

    private var model: CircleWidgetModel {
        CircleWidgetModel(snapshot: entry.snapshot, date: entry.date)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            // No ground and no palette: the lock screen renders accessory
            // widgets through its own vibrancy, and a colour set here would be
            // flattened anyway. §3 keeps this family text-only, which also
            // sidesteps the consent question about faces entirely.
            RectangularCircleView(model: model)
                .containerBackground(.clear, for: .widget)
        case .systemMedium:
            MediumCircleView(model: model)
                .containerBackground(WidgetTheme.ground, for: .widget)
        default:
            SmallCircleView(model: model)
                .containerBackground(WidgetTheme.ground, for: .widget)
        }
    }
}

// MARK: - Small

/// §3: the current window, "3 of 5 prayed", an emoji row. No photos.
private struct SmallCircleView: View {
    let model: CircleWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowHeader(model: model)
            Spacer(minLength: 6)
            Text(model.countLine)
                .font(Theme.sans(15, .bold))
                .foregroundStyle(WidgetTheme.ink)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            if !model.isSolo, model.memberCount > 0 {
                CountTrack(progress: model.progress)
                    .padding(.top, 5)
            }
            if model.phase != .empty {
                FaceRow(model: model)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Medium

/// §3: the same window, plus this window's posts as a 4-up row. The photos and
/// the nudge button that finish this family arrive in P3 and P4; what is here
/// is names, tiers and counts, which is the whole of P2.
///
/// **The width budget, because a widget cannot scroll and silently clips
/// instead.** A systemMedium tile is 321pt wide on the narrowest phone iOS 18
/// runs on (375pt class) and the system takes 16pt of margin each side, so the
/// content is 289pt — not the 329/364 of the bigger phones. Four chips is the
/// case §3 asks for and therefore the case that has to fit: 104 (left column)
/// + 10 (gap) leaves 175, and four chips with three 6pt gaps come to 39pt
/// each. `PostChip` is capped rather than fixed so that arithmetic is the
/// worst case and not the only one — on a 430pt phone the same four chips draw
/// at their full 44 and the row simply stops there.
private struct MediumCircleView: View {
    let model: CircleWidgetModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                WindowHeader(model: model)
                Spacer(minLength: 4)
                Text(model.countLine)
                    .font(Theme.sans(15, .bold))
                    .foregroundStyle(WidgetTheme.ink)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                if !model.isSolo, model.memberCount > 0 {
                    CountTrack(progress: model.progress)
                        .padding(.top, 5)
                }
                if model.streak > 0 {
                    Text("🔥 \(model.streak)")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(WidgetTheme.gold)
                        .padding(.top, 6)
                }
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if model.posts.isEmpty {
                    Text(model.phase == .empty ? "Nothing to show yet"
                                               : "Nobody has prayed this window yet")
                        .font(Theme.sans(12, .medium))
                        .foregroundStyle(WidgetTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // No trailing `Spacer` on purpose: a spacer is a subview
                    // and takes an equal share of a crowded row, which would
                    // squeeze four chips to make room for nothing. Under-full
                    // the stack is simply narrower than the column and the
                    // enclosing `.leading` alignment packs it left; over-full
                    // every chip gives up the same width.
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(model.posts.enumerated()), id: \.offset) { _, post in
                            PostChip(post: post)
                        }
                    }
                }
                Spacer(minLength: 0)
                WaitingLine(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock screen

/// §3: "Asr · 3 of 5 prayed". Text only.
private struct RectangularCircleView: View {
    let model: CircleWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.accessoryLine)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.timeLine)
                .font(.caption)
                .lineLimit(1)
            if !model.posts.isEmpty {
                Text(model.posts.map { $0.emoji }.joined(separator: " "))
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

private struct WindowHeader: View {
    let model: CircleWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if let prayer = model.prayer {
                    Text(prayer.emoji)
                        .font(.system(size: 14))
                }
                Text(model.title)
                    .font(Theme.sans(17, .bold))
                    .foregroundStyle(WidgetTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(model.timeLine)
                .font(Theme.sans(12, .medium))
                .foregroundStyle(WidgetTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// How much of the circle has prayed. A track, not a ring: it has to read at a
/// glance in a corner of a tile, and it never turns red at zero — an empty
/// window is a window that has not happened yet.
private struct CountTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetTheme.divider)
                Capsule()
                    .fill(WidgetTheme.accent)
                    .frame(width: max(progress > 0 ? 6 : 0, geo.size.width * progress))
            }
        }
        .frame(height: 6)
    }
}

/// The circle as a row of faces: who has prayed, then — dimmed — who has not.
///
/// Capped, for the same reason the medium row is: a systemSmall tile is 141pt
/// on the narrowest supported phone, so 109pt of content, and an emoji at 14pt
/// costs about 17 of them. Four faces and an overflow count come to ~95pt; the
/// seven a full circle could offer come to ~140pt and the last three would be
/// drawn straight off the edge of the tile, because a widget has no scroll view
/// to put them in.
private struct FaceRow: View {
    let model: CircleWidgetModel

    private static let maxFaces: Int = 4

    /// Prayed first, then whoever is still to pray — the reading order of the
    /// count above it.
    private var faces: [(emoji: String, dimmed: Bool)] {
        model.posts.map { ($0.emoji, false) } + model.waiting.map { ($0.emoji, true) }
    }

    var body: some View {
        let all: [(emoji: String, dimmed: Bool)] = faces
        let shown: [(emoji: String, dimmed: Bool)] = Array(all.prefix(FaceRow.maxFaces))
        let more: Int = all.count - shown.count
        HStack(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, face in
                Text(face.emoji)
                    .font(.system(size: 14))
                    .opacity(face.dimmed ? 0.32 : 1)
            }
            if more > 0 {
                Text("+\(more)")
                    .font(Theme.sans(10, .semibold))
                    .foregroundStyle(WidgetTheme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// One post: emoji, name, and the grid's tier colour underneath it. The photo
/// this chip will carry is P3's; the tier bar is what says "on time" today.
///
/// **Capped, never fixed.** A hard `.frame(width:)` here is what clipped the
/// fourth friend off the medium tile: four of them plus the left column came to
/// 338pt against a content width of 289–332, and a widget has no way to say so
/// — it just draws past its own rounded corner. Everything below is either
/// flexible or scales, so the row fits by giving up a few points per chip
/// instead.
private struct PostChip: View {
    let post: WidgetSnapshot.Post

    /// The chip at its most comfortable, on a tile with room for it.
    static let maxWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(WidgetTheme.surface)
                Text(post.emoji)
                    .font(.system(size: 19))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(WidgetTheme.tier(post.tier))
                    .frame(height: 3)
                    .frame(maxWidth: 22)
                    .padding(.bottom, 4)
            }
            Text(post.name)
                .font(Theme.sans(9, .semibold))
                .foregroundStyle(WidgetTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: PostChip.maxWidth)
    }
}

/// Who is still to pray. Names only — never a reason, never a rest day: a
/// person on a break is not in `waiting` at all (SPEC-V5 §7).
private struct WaitingLine: View {
    let model: CircleWidgetModel

    private var text: String? {
        guard model.phase != .empty, !model.isSolo else { return nil }
        guard !model.waiting.isEmpty else {
            return model.prayedCount > 0 && model.prayedCount == model.memberCount
                ? "Everyone's in 🎉" : nil
        }
        let names: [String] = model.waiting.prefix(3).map { $0.name }
        let more: Int = model.waiting.count - names.count
        let list: String = names.joined(separator: ", ")
        return more > 0 ? "Waiting on \(list) +\(more)" : "Waiting on \(list)"
    }

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.sans(11, .medium))
                .foregroundStyle(WidgetTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
