import ActivityKit
import SwiftUI
import WidgetKit

/// v5 §6 — the prayer window on the Lock Screen and in the Dynamic Island.
///
/// "Asr · 2h 14m left · 3 of 5 prayed", filling in as the circle posts, ending
/// itself when the window closes. It is the same window the home-screen tile
/// draws, from the same `WidgetSnapshot` (see `LiveActivityPlanner`), which is
/// what stops one phone showing two different counts for one prayer.
///
/// **This target renders and nothing else**, exactly as it does for the tile:
/// no `GameEngine`, no Adhan, no network, no `Store`, no `AppClock`. The app
/// decides the content state; the server moves it while the app is closed. And
/// the countdown is not a timer — `Text(timerInterval:)` is a SYSTEM-rendered
/// countdown, which is the only kind a Live Activity is allowed (§4: no
/// self-driven timers) and the only kind that stays right while the process is
/// asleep.
///
/// **No photos, deliberately.** §6 caps a pushed content state at 4 KB, which
/// cannot carry a picture, and §7 forbids a widget-only photo store to smuggle
/// one through. Emoji, names, counts and tier colours — which is exactly what
/// the accessory (lock screen) family already ships, and it sidesteps the
/// consent question about faces on a locked phone entirely.
struct PrayerWindowLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrayerWindowAttributes.self) { context in
            LockScreenActivityView(attributes: context.attributes,
                                   state: context.state)
                .activityBackgroundTint(WidgetTheme.ground)
                .activitySystemActionForegroundColor(WidgetTheme.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(ActivityCopy.title(context.attributes))
                            .font(Theme.sans(15, .bold))
                            .foregroundStyle(WidgetTheme.ink)
                    } icon: {
                        Text(context.attributes.prayer?.emoji ?? "🕌")
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(endsAt: context.attributes.endsAtDate)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(WidgetTheme.inkMuted)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ActivityCopy.count(context.state))
                            .font(Theme.sans(14, .semibold))
                            .foregroundStyle(WidgetTheme.ink)
                        if !context.state.isSolo {
                            CountTrack(progress: context.state.progress)
                        }
                        FaceStrip(faces: context.state.faces)
                    }
                }
            } compactLeading: {
                Text(context.attributes.prayer?.emoji ?? "🕌")
            } compactTrailing: {
                // The compact trailing slot is a few points wide, so it gets
                // the one number that changes: how much of the circle is in.
                Text(ActivityCopy.compactCount(context.state))
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(WidgetTheme.accent)
            } minimal: {
                Text(context.attributes.prayer?.emoji ?? "🕌")
            }
            .keylineTint(WidgetTheme.accent)
        }
    }
}

// MARK: - Copy

/// The words, in one place, because three presentations say the same things at
/// three widths and a phrase that drifted between them would read as a bug.
enum ActivityCopy {

    static func title(_ attributes: PrayerWindowAttributes) -> String {
        attributes.prayer?.displayName ?? "Prayer"
    }

    /// "3 of 5 prayed", or your own standing when there is nobody else — the
    /// same sentence `CircleWidgetModel` builds for the tile, for the same
    /// reason: "0 of 1 prayed" is a strange way to tell somebody they have not
    /// prayed yet.
    static func count(_ state: PrayerWindowAttributes.ContentState) -> String {
        if state.isSolo { return state.youLogged ? "Prayed" : "Not yet" }
        return "\(state.prayedCount) of \(state.memberCount) prayed"
    }

    static func compactCount(_ state: PrayerWindowAttributes.ContentState) -> String {
        state.isSolo ? (state.youLogged ? "✓" : "–")
                     : "\(state.prayedCount)/\(state.memberCount)"
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    let attributes: PrayerWindowAttributes
    let state: PrayerWindowAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(attributes.prayer?.emoji ?? "🕌")
                        .font(.system(size: 16))
                    Text(ActivityCopy.title(attributes))
                        .font(Theme.sans(18, .bold))
                        .foregroundStyle(WidgetTheme.ink)
                }
                CountdownText(endsAt: attributes.endsAtDate)
                    .font(Theme.sans(13, .medium))
                    .foregroundStyle(WidgetTheme.inkMuted)
                Text(ActivityCopy.count(state))
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(WidgetTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !state.isSolo {
                    CountTrack(progress: state.progress)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            FaceStack(faces: state.faces, youLogged: state.youLogged)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Pieces

/// The countdown, rendered by the SYSTEM.
///
/// `Text(timerInterval:)` is what makes "2h 14m left" tick on a Lock Screen the
/// app is not running behind. A `Date`-formatted string would be frozen at the
/// instant the content state was last set, which on the push path is whenever a
/// friend last prayed — so the window would appear to stop counting down
/// between posts.
///
/// The interval is clamped to start no later than it ends, because a window
/// that has already closed (a push that arrived late, a clock that moved) would
/// otherwise be an interval running backwards.
private struct CountdownText: View {
    let endsAt: Date

    var body: some View {
        let now = Date()
        if endsAt > now {
            Text(timerInterval: now ... endsAt, countsDown: true)
                .monospacedDigit()
        } else {
            Text("window closed")
        }
    }
}

/// How much of the circle has prayed. A track, not a ring, and never red at
/// zero — an empty window is a window that has not happened yet (the same rule
/// the tile draws by).
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

/// The circle as a column of faces on the Lock Screen: emoji on a tier-coloured
/// pill, the name under it, newest first. Capped by
/// `PrayerWindowAttributes.faceCap`, which the content state has already applied
/// — this only lays out what arrived.
///
/// **The name is drawn HERE and only here, and that is the point.** `Face.name`
/// crosses the wire and is counted against §6's 4 KB budget, so
/// `buildLiveActivityPush` trims whole faces oldest-first to fit — emoji chips
/// taken off somebody's Lock Screen to make room. A field that costs a face and
/// then goes undrawn is a field that should not be sent, so either it appears on
/// a surface or it leaves the content state. The Lock Screen is the surface with
/// the room: the Dynamic Island's expanded bottom region is already a count, a
/// track and this row inside a fixed height, and a second line of text per face
/// is what makes it clip.
private struct FaceStack: View {
    let faces: [PrayerWindowAttributes.Face]
    let youLogged: Bool

    var body: some View {
        if faces.isEmpty {
            Text(youLogged ? "🤲" : "")
                .font(.system(size: 22))
        } else {
            HStack(spacing: 4) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    FaceBadge(face: face, showsName: true)
                }
            }
        }
    }
}

/// The same row, laid out for the Dynamic Island's bottom region — see
/// `FaceStack` on why the name does not come with it.
private struct FaceStrip: View {
    let faces: [PrayerWindowAttributes.Face]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                FaceBadge(face: face, showsName: false)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FaceBadge: View {
    let face: PrayerWindowAttributes.Face
    let showsName: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(face.emoji)
                .font(.system(size: 17))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Capsule()
                // A tier this build has never heard of is a face with no
                // colour, not a face that is missing — `Face.logTier` answers
                // nil rather than throwing, which is the whole reason `tier`
                // crosses as a string.
                .fill(face.logTier.map { WidgetTheme.tier($0) } ?? WidgetTheme.divider)
                .frame(width: 16, height: 3)
            if showsName {
                // Scales rather than wraps, for the reason every other label on
                // these two surfaces does: the badge is 26pt wide and a name is
                // whatever somebody typed. A long one shrinks; it never widens
                // the row or pushes a fourth friend off the card.
                Text(face.name)
                    .font(Theme.sans(9, .semibold))
                    .foregroundStyle(WidgetTheme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: 26)
    }
}
