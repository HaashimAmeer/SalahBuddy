import SwiftUI

// MARK: - Tap-to-enlarge detail (v3.8 — design session)

/// What HomeView needs to show the centered enlarge modal.
struct EnlargedPost: Identifiable, Equatable {
    let entry: GridEntry
    let prayer: Prayer
    var id: String { entry.id }
    static func == (l: EnlargedPost, r: EnlargedPost) -> Bool { l.id == r.id }
}

/// Tapping a square pops this open IN PLACE (inside `CenteredModal`, which
/// supplies the dim + close X) — the photo larger, with the details taken off
/// the small tile (location, full time, tier). No scrolling.
struct PrayerPhotoDetailContent: View {
    let entry: GridEntry
    let prayer: Prayer
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 14) {
            Text("\(prayer.emoji) \(entry.member.isYou ? "You" : entry.member.name)")
                .font(Theme.sans(20, .bold))
                .foregroundStyle(Theme.inkDeep)
            photo
            if let caption = entry.caption {
                Text(caption)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            detailRow
        }
    }

    @ViewBuilder
    private var photo: some View {
        Group {
            switch entry.state {
            case .posted(.photo(let filename), _, _):
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Theme.greenSoft.opacity(0.5)
                    }
                }
                .task(id: filename) {
                    let name = filename
                    image = await Task.detached(priority: .userInitiated) {
                        PhotoStore.load(name)
                    }.value
                }
            case .posted(.illustration(let seed), _, _):
                IllustratedPrayerCard(seed: seed)
            default:
                Theme.greenSoft.opacity(0.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var detailRow: some View {
        HStack(spacing: 8) {
            if case .posted(_, let tier, let at) = entry.state {
                chip(tier.label, Theme.color(for: .inWindow(tier)))
                chip(at.formatted(date: .omitted, time: .shortened), Theme.inkMuted)
            }
            if let place = entry.placeLabel {
                chip(place, Theme.qadaBlue)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.sans(12.5, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }
}

// MARK: - Make-up (qada) section

/// Today's passed-unlogged prayers as small tap-only rows, with gentle
/// "you missed out" copy — no shaming, no red.
struct MakeUpSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // v3.6: per-prayer excuse — a miss from BEFORE a mid-day break started
        // is still make-up-able.
        let prayers = state.makeUpPrayers.filter {
            !state.isExcused(prayer: $0, dayKey: state.todayKey)
        }
        if !prayers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.makeUpIsBeforeJoiningOnly ? "Already prayed today?" : "Make up")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .textCase(.uppercase)

                // Day one asks a question; every other day states a fact. The
                // rows underneath are identical either way.
                if state.makeUpIsBeforeJoiningOnly {
                    Text("Add the ones you've already prayed today — they still count 💙")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.missedOutXPToday > 0 {
                    Text("You missed out on +\(state.missedOutXPToday) XP today — a make-up still counts 💙")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(prayers) { prayer in
                    row(for: prayer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardStyle()
        }
    }

    private func row(for prayer: Prayer) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.logQada(prayer) }
        } label: {
            HStack(spacing: 10) {
                Text(prayer.emoji)
                Text("Make up \(prayer.displayName)")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Spacer(minLength: 8)
                Text("+\(LogTier.qada.xp) XP")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.qadaBlue)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.qadaBlue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.qadaBlue.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

/// One friend's nudge chip — emoji + name + a wave; flips to "✓" once sent.
struct NudgeChip: View {
    let member: CircleMember
    let prayer: Prayer
    let dayKey: String

    @EnvironmentObject private var state: AppState

    private var sent: Bool {
        state.nudgesSent.contains(state.nudgeKey(member: member, prayer: prayer, dayKey: dayKey))
    }

    var body: some View {
        Button {
            guard !sent else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Theme.spring) {
                state.sendNudge(to: member, prayer: prayer, dayKey: dayKey)
            }
        } label: {
            HStack(spacing: 5) {
                Text(member.emoji).font(.system(size: 13))
                Text(member.name)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text(sent ? "✓" : "👋")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(sent ? Theme.greenSoft.opacity(0.6) : Theme.bg))
            .overlay(Capsule().strokeBorder(
                sent ? Theme.green.opacity(0.5) : Theme.mist.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(sent)
    }
}

// MARK: - Travel mode (v3.3)
// v3.6: the manual travel toggle and the "Can't pray right now?" entry moved
// to Settings (design session) — they're occasional, not everyday actions.
// Only the location-based auto-suggestion stays on Today.

/// v4: the device crossed several timezones since it last looked.
///
/// Distinct from `TravelSuggestionBanner` below, which fires on DISTANCE from
/// your saved home and only ever offers to combine prayers. This one fires on
/// the clock moving, and its job is to say the two things a traveller actually
/// wants to know on landing: the times you are looking at are the local ones
/// now, and the day you spent in the air is not going to cost you a streak.
/// HomeView shows one or the other, never both — two travel banners stacked
/// would be noise at precisely the moment someone is tired and disoriented.
struct TimeZoneChangeBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var location = LocationProvider.shared

    var body: some View {
        if let notice = state.pendingTravelNotice {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.qadaBlue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline)
                            .font(Theme.sans(13, .bold))
                            .foregroundStyle(Theme.inkDeep)
                        Text("Your streak is safe for the days you were crossing.")
                            .font(Theme.sans(11.5, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                HStack(spacing: 14) {
                    if !state.isTraveling {
                        Button("Combine prayers") {
                            withAnimation(Theme.spring) {
                                state.setTraveling(true)
                                state.pendingTravelNotice = nil
                            }
                        }
                        .font(Theme.sans(13, .bold))
                        .foregroundStyle(Theme.green)
                        .buttonStyle(.plain)
                    }
                    Button("Got it") {
                        withAnimation(Theme.spring) { state.pendingTravelNotice = nil }
                    }
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .id(notice.id)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// Name the place when CoreLocation knows it; otherwise say the true thing
    /// without pretending to know where "here" is.
    private var headline: String {
        if let place = location.placeName ?? nonEmptyFallback {
            return "Prayer times now follow \(place)"
        }
        return "Prayer times updated for your new timezone"
    }

    private var nonEmptyFallback: String? {
        let name = state.settings.locationName
        return name.isEmpty ? nil : name
    }
}

/// Auto-suggestion banner: shows when you're far from your saved Home.
struct TravelSuggestionBanner: View {
    @EnvironmentObject private var state: AppState
    @Binding var dismissed: Bool

    var body: some View {
        if !dismissed, !state.isTraveling, state.shouldSuggestTravel() {
            HStack(spacing: 10) {
                Image(systemName: "airplane")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.qadaBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Looks like you're away from home")
                        .font(Theme.sans(13, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text("Combine prayers while you travel?")
                        .font(Theme.sans(11.5, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 8)
                Button("Not now") { withAnimation(Theme.spring) { dismissed = true } }
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)
                Button("Enable") {
                    withAnimation(Theme.spring) { state.setTraveling(true) }
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.qadaBlue))
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Theme.qadaBlue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Excused-day footer
// v3.6: gone from Today — the "Can't pray right now?" flow lives in Settings
// (BreakAndTravelCard), and resuming asks WHEN you started praying again
// (ResumeSheet in Views/Recovery).
