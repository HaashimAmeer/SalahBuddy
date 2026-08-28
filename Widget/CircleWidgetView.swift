import SwiftUI
import UIKit
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
    /// v5 §7/§9-02 — how much of a friend's photo this home screen may show.
    /// The writer has already applied `.namesAndTier` (no post carries a
    /// `thumb`); what is left for this side is `.blurred`.
    let photoStyle: WidgetPhotoStyle
    /// v5 §4 (P4) — what the nudge button needs to name a person and a window.
    /// Both come straight out of the file; nothing here re-derives a schedule.
    let dayKey: String?
    let prayerRaw: String?
    /// The person the button is aimed at: the first in `waiting` who has not
    /// been nudged. nil when there is nobody to nudge, which is the ordinary
    /// state for most of a window (`waiting` is empty until it has been open
    /// half an hour — see `WidgetSnapshotBuilder.nudgesAllowed`).
    let nudgeTarget: WidgetSnapshot.Waiting?
    /// Whether THIS PROCESS can send the nudge itself.
    ///
    /// §2 tooth #3: the extension may never refresh the session, so an expired
    /// one is not a failed button — it is a deep link into the app. Deciding it
    /// at RENDER time (rather than discovering it inside `perform()`) is what
    /// makes the difference visible: the tile draws a link, and the tap goes
    /// somewhere that can actually sign you in.
    ///
    /// **This render is a guess, and `NudgeSender` asks again.** A timeline
    /// entry is drawn and archived when the timeline is produced, which can be
    /// hours before anybody looks at it — so a Button here is a claim about a
    /// token that may since have expired, and the intent re-decides before it
    /// writes anything. `NudgeRoute` is the one function both spend.
    ///
    /// A Keychain read per render, which is cheap and rare — a widget renders
    /// at window boundaries and on reloads, not continuously. It answers false
    /// on a device that has not been unlocked since boot, and false is the safe
    /// answer there too — except in demo, which needs no session at all.
    let canNudge: Bool

    init(snapshot: WidgetSnapshot?, date: Date) {
        let circle: WidgetSnapshot.Circle = snapshot?.circle ?? .empty
        photoStyle = snapshot?.photoStyle ?? .photos
        posts = circle.posts
        waiting = circle.waiting
        prayedCount = circle.prayedCount
        memberCount = circle.memberCount
        youLogged = snapshot?.you.logged ?? false
        streak = snapshot?.you.streak ?? 0
        // One person in the circle is you, and "0 of 1 prayed" is a strange way
        // to tell somebody they have not prayed yet.
        isSolo = circle.memberCount <= 1
        nudgeTarget = snapshot?.nextNudgeTarget
        // §9-03: `waiting[]` is populated for a demo circle too, so a demo user
        // MUST get a working button — they have no account, so a session check
        // is one that can never pass and the pill would bounce every first-run
        // user into the app forever.
        canNudge = nudgeTarget != nil
            && NudgeRoute.decide(mode: snapshot?.mode ?? NudgeRoute.modeWithoutAFile,
                                 token: SharedSession.load(), at: date).canSend

        guard let snapshot, let window = snapshot.window else {
            phase = .empty
            prayer = nil
            title = "SalahBuddy"
            timeLine = "Open the app to get started"
            countLine = ""
            dayKey = nil
            prayerRaw = nil
            return
        }
        dayKey = window.dayKey
        prayerRaw = window.prayer.rawValue
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

/// §3: the same window, plus this window's posts as a 4-up row — the one family
/// §3's table gives photos to. The nudge button that finishes it is P4's.
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
                            PostChip(post: post, photoStyle: model.photoStyle)
                        }
                    }
                }
                Spacer(minLength: 0)
                // v5 §4 (P4): the one thing you can DO from a home screen. It
                // falls back to the plain waiting line whenever there is nobody
                // to nudge, which is most of a window.
                NudgeRow(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The nudge (v5 §4)

/// The button, the deep link, or the sentence — in that order of preference.
///
/// Three states, and the middle one is the whole of SPEC-V5 §2's third tooth:
///
/// - **A person to nudge and a usable session** → `Button(intent:)`. The intent
///   runs headless, writes the optimistic state into the container before it
///   returns (§4), and this tile redraws with the next name.
/// - **A person to nudge and a session this process may not spend** →
///   `Link`. The extension NEVER refreshes a token (two processes rotating one
///   refresh token invalidate each other), so an expired one is handed to the
///   app rather than used, retried or repaired here.
/// - **Nobody to nudge** → `WaitingLine`, exactly as P2 shipped it.
///
/// `waiting` is spent VERBATIM. It is already the nudge list rather than
/// "everybody who has not posted" — the window must be open, thirty minutes in,
/// and never the carry-over isha (`WidgetSnapshotBuilder.nudgesAllowed`) — so
/// there is no gate on this side, and there must not be: two surfaces deciding
/// who is late is two surfaces that can disagree.
private struct NudgeRow: View {
    let model: CircleWidgetModel

    var body: some View {
        if let target = model.nudgeTarget, let dayKey = model.dayKey,
           let prayerRaw = model.prayerRaw {
            if model.canNudge {
                Button(intent: NudgeFriendIntent(memberID: target.userID,
                                                 dayKey: dayKey,
                                                 prayer: prayerRaw)) {
                    NudgeLabel(name: target.name, emoji: target.emoji)
                }
                .buttonStyle(.plain)
            } else if let url = SharedBackend.nudgeDeepLink(memberID: target.userID,
                                                            prayer: prayerRaw,
                                                            dayKey: dayKey) {
                Link(destination: url) {
                    NudgeLabel(name: target.name, emoji: target.emoji)
                }
            } else {
                WaitingLine(model: model)
            }
        } else {
            WaitingLine(model: model)
        }
    }
}

/// One chunky, flat, mint pill — the app's button language at widget scale.
///
/// Width is the constraint that decides everything here: the medium tile's
/// right-hand column is ~175pt on the narrowest phone iOS 18 runs on (see
/// `MediumCircleView`'s budget), and the four post chips above it already own
/// that width. So the label scales rather than wrapping, and nothing inside has
/// a fixed width.
private struct NudgeLabel: View {
    let name: String
    let emoji: String

    var body: some View {
        HStack(spacing: 4) {
            Text(emoji)
                .font(.system(size: 12))
            Text("Nudge \(name)")
                .font(Theme.sans(11, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(WidgetTheme.ground)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            Capsule().fill(WidgetTheme.accent))
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

/// One post: the photo if there is one, else the emoji — the name under it, and
/// the grid's tier colour across the bottom.
///
/// **Capped, never fixed.** A hard `.frame(width:)` here is what clipped the
/// fourth friend off the medium tile: four of them plus the left column came to
/// 338pt against a content width of 289–332, and a widget has no way to say so
/// — it just draws past its own rounded corner. Everything below is either
/// flexible or scales, so the row fits by giving up a few points per chip
/// instead.
///
/// **The picture is a FILE READ, on the render pass** (v5 §3, P3). The
/// extension has no network and never will; what it draws is the ~300px
/// thumbnail the app cached into `circlephotos/thumbs/` when the pull landed.
/// A missing one — a post whose photo has not been fetched yet, a build with no
/// App Group, a photo swept at thirty days — is not a failure state: the chip
/// falls back to exactly what P2 shipped.
private struct PostChip: View {
    let post: WidgetSnapshot.Post
    let photoStyle: WidgetPhotoStyle

    /// The chip at its most comfortable, on a tile with room for it.
    static let maxWidth: CGFloat = 44

    /// Enough to make a face unrecognisable at 44pt without turning the chip
    /// into a grey square: shape and colour survive, the person does not.
    private static let blurRadius: CGFloat = 7

    /// Read once per render. `UIImage(contentsOfFile:)` rather than
    /// `Image(uiImage:)` from a cache, because a widget process is built,
    /// rendered and torn down — there is no session for a cache to live in, and
    /// four 300px JPEGs are well inside the memory a tile is allowed.
    private var photo: UIImage? {
        guard let key: String = post.thumb,
              let url: URL = WidgetFile.thumbnailURL(forKey: key) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        VStack(spacing: 3) {
            // An OVERLAY on the ground, not a sibling in a ZStack. An overlay
            // is sized to the thing it covers and can never widen it; a
            // `scaledToFill` image inside a stack reports a size that OVERFLOWS
            // its proposal, the stack takes its largest child, and four chips
            // insisting on their full 44 is exactly what clipped the fourth
            // friend off a 375pt tile before P2's review caught it. The width
            // budget above only holds if nothing in here has an opinion about
            // width.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WidgetTheme.surface)
                .overlay {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            // Blurred INSIDE the clip below, so the soft edge
                            // stays within the rounded rectangle instead of
                            // bleeding a halo of somebody's face past its
                            // corner.
                            .blur(radius: photoStyle == .blurred
                                    ? PostChip.blurRadius : 0)
                    } else {
                        Text(post.emoji)
                            .font(.system(size: 19))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
