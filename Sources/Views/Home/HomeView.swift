import SwiftUI

/// Today screen. v5 (mockup): a sideways pager with one page per prayer
/// (`TodayPager`) — header, "Your day", the prayer's own card, make-ups, and
/// the circle's feed for that prayer. This view owns what sits above the
/// pager: the camera sheet, the celebration, and tap-to-enlarge.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var cameraTarget: CameraTarget?
    @State private var enlarged: EnlargedPost?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            // v5 (mockup): swipe between today's prayers; each page scrolls
            // down into that prayer's circle feed.
            TodayPager(
                onPost: { page in
                    // The CTA only exists while the window is open, so
                    // `inWindowAtOpen` is true in practice — but it is
                    // answered from the clock rather than assumed, because it
                    // is what decides whether a qada gets apologised for.
                    cameraTarget = CameraTarget(prayer: page.prayer, dayKey: page.dayKey,
                                                windowEnd: page.end,
                                                inWindowAtOpen: now < page.end,
                                                combinedLead: page.combinedWith != nil ? page.prayer : nil)
                },
                onEnlarge: { entry, prayer in enlarged = EnlargedPost(entry: entry, prayer: prayer) })

            if state.celebration != nil {
                CelebrationOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(10)
            }

            // v3.8: enlarge a tapped square in place — centered modal, no scroll.
            if let post = enlarged {
                CenteredModal(onClose: { enlarged = nil }) {
                    PrayerPhotoDetailContent(entry: post.entry, prayer: post.prayer)
                }
                .zIndex(15)
            }
        }
        .animation(Theme.spring, value: state.celebration != nil)
        .animation(Theme.spring, value: enlarged)
        .sheet(item: $cameraTarget) { target in
            CameraFlowSheet(target: target)
        }
    }
}

// MARK: - Header

/// Compact header: date line + greeting on the left, streak flame + XP chip
/// on the right. A faint crescent accent sits behind the greeting.
struct TodayHeader: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        // v3.6 (design session): bigger, more spaced greeting; the little moon
        // sits right next to the salam instead of floating out of place.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(HomeTimeFormat.dayLine(now))
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 8) {
                    Text("Salam, \(displayName)")
                        .font(Theme.sans(28, .bold))
                        .foregroundStyle(Theme.inkDeep)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.green.opacity(0.55))
                        .offset(y: -5)
                }
                // v3.2: level lives under the greeting (design session) — the
                // right side keeps just the flame, less crowded.
                HStack(spacing: 6) {
                    Text("Level \(state.level) · \(state.levelTitle)")
                        .font(Theme.sans(12, .bold))
                        .foregroundStyle(Theme.inkMuted)
                    ProgressRing(progress: levelProgress, lineWidth: 2.5, color: Theme.gold)
                        .frame(width: 13, height: 13)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            StreakFlameView(streak: state.profile.streak, isLitToday: streakLitToday)
        }
        .padding(.top, 4)
    }

    private var levelProgress: Double {
        guard state.xpNeededForLevel > 0 else { return 1 }
        return min(1, Double(state.xpIntoLevel) / Double(state.xpNeededForLevel))
    }

    private var displayName: String {
        let trimmed = state.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "friend" : trimmed
    }

    private var streakLitToday: Bool {
        state.profile.lastStreakDayKey == state.todayKey
    }
}

// MARK: - Camera sheet routing

/// Identifiable target for the camera sheet (prayer + the schedule day the
/// log will attach to — yesterday's dayKey for the pre-fajr isha block).
struct CameraTarget: Identifiable, Equatable {
    let prayer: Prayer
    let dayKey: String
    /// v4.1: when the window this flow is racing closes — for a travel pair the
    /// END of the pair, which is the deadline `logCombined` will actually be
    /// judged against. The confirm screen counts down to it.
    let windowEnd: Date
    /// v4.1: was the window still open when this flow was OPENED? A qada that
    /// lands out of a flow that started in-window is a lapse and is explained;
    /// a flow that set out to record a make-up is a choice and is left alone.
    /// No default — the one thing a future make-up caller must not get wrong.
    let inWindowAtOpen: Bool
    /// v3.3: when set, posting logs this prayer AND its travel partner together
    /// (jam') via `logCombined`. `prayer` is the lead (earlier) prayer.
    var combinedLead: Prayer? = nil
    var id: String { "\(dayKey)|\(prayer.rawValue)\(combinedLead != nil ? "|combined" : "")" }
}
