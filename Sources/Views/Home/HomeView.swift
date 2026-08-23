import SwiftUI

/// Today screen (v2) — compact header + prayer-times strip, the live current
/// prayer block (photo grid + camera CTA), make-up rows, earlier-today
/// collapsed blocks, dimmed upcoming list, and the quiet excused-day flow.
/// Owned by the home agent. No mascot here in v2.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var cameraTarget: CameraTarget?
    @State private var travelSuggestionDismissed = false
    @State private var enlarged: EnlargedPost?

    var body: some View {
        // ONE call, not three. This body re-runs every second — it reads
        // `appNow` — and `currentTodayBlock` is not free: it filters and
        // maxes over the day's windows, and takes `Calendar.current` on the
        // pre-fajr path. Asking the same question three times per tick was
        // pure waste, and the three answers were always identical anyway.
        let block = state.currentTodayBlock(now: now)
        return ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        TodayHeader()
                            .id("tour-home-top")
                        PrayerTimesStrip(currentPrayer: block?.isYesterdayIsha == false
                                         ? block?.prayer : nil)

                        // One travel banner at a time: a fresh crossing is
                        // more specific and more urgent than "you look far
                        // from home", so it wins while it stands.
                        if state.pendingTravelNotice != nil {
                            TimeZoneChangeBanner()
                        } else {
                            TravelSuggestionBanner(dismissed: $travelSuggestionDismissed)
                        }

                        if let block {
                            CurrentPrayerBlock(
                                block: block,
                                onPost: {
                                    cameraTarget = CameraTarget(prayer: block.prayer, dayKey: block.dayKey,
                                                                combinedLead: block.combinedWith != nil ? block.prayer : nil)
                                },
                                onEnlarge: { enlarged = EnlargedPost(entry: $0, prayer: block.prayer) })
                            .tutorialTarget(.postPhoto)
                        }

                        MakeUpSection()
                        EarlierTodaySection()
                            .tutorialTarget(.earlierToday)
                            .id("tour-earlier")
                        UpcomingSection()
                        // v3.6: travel + "can't pray" controls moved to Settings
                        // (design session) — they're not everyday actions.
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                // v3.7: the guided tour scrolls its targets into view.
                .onChange(of: state.tutorialStep) { previous, step in
                    // Tour over: back to the top of Today. The last step
                    // scrolled this view down to "Earlier today" and then the
                    // tour walked off to another tab, so returning here landed
                    // you mid-page looking at yesterday's leftovers rather than
                    // at the prayer you are meant to log next.
                    if step == nil, previous != nil {
                        withAnimation(Theme.spring) {
                            proxy.scrollTo("tour-home-top", anchor: .top)
                        }
                        return
                    }
                    guard let step else { return }
                    withAnimation(Theme.spring) {
                        if step == Tour.postPhotoIndex { proxy.scrollTo("tour-home-top", anchor: .top) }
                        if step == Tour.earlierTodayIndex { proxy.scrollTo("tour-earlier", anchor: .center) }
                    }
                }
            }

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

// MARK: - Prayer-times strip

/// Slim at-a-glance strip: 5 chips (name + start time); the current prayer
/// is highlighted in soft green.
struct PrayerTimesStrip: View {
    let currentPrayer: Prayer?

    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Prayer.allCases) { prayer in
                chip(for: prayer)
            }
        }
    }

    private func chip(for prayer: Prayer) -> some View {
        let isCurrent = prayer == currentPrayer
        return VStack(spacing: 1) {
            Text(prayer.displayName)
                .font(Theme.sans(11, .bold))
                .foregroundStyle(isCurrent ? Theme.inkDeep : Theme.inkMuted)
            Text(startText(for: prayer))
                .font(Theme.sans(11, .semibold))
                .foregroundStyle(isCurrent ? Theme.inkDeep : Theme.inkMuted.opacity(0.8))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? Theme.greenSoft : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? Theme.green.opacity(0.45) : .clear, lineWidth: 1.5)
        )
    }

    private func startText(for prayer: Prayer) -> String {
        guard let window = state.todaySchedule?.window(for: prayer) else { return "—" }
        return HomeTimeFormat.clock(window.start)
    }
}

// MARK: - Camera sheet routing

/// Identifiable target for the camera sheet (prayer + the schedule day the
/// log will attach to — yesterday's dayKey for the pre-fajr isha block).
struct CameraTarget: Identifiable, Equatable {
    let prayer: Prayer
    let dayKey: String
    /// v3.3: when set, posting logs this prayer AND its travel partner together
    /// (jam') via `logCombined`. `prayer` is the lead (earlier) prayer.
    var combinedLead: Prayer? = nil
    var id: String { "\(dayKey)|\(prayer.rawValue)\(combinedLead != nil ? "|combined" : "")" }
}
