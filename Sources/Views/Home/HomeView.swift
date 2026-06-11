import SwiftUI

/// Today screen (v2) — compact header + prayer-times strip, the live current
/// prayer block (photo grid + camera CTA), make-up rows, earlier-today
/// collapsed blocks, dimmed upcoming list, and the quiet excused-day flow.
/// Owned by the home agent. No mascot here in v2.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    @State private var cameraTarget: CameraTarget?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    TodayHeader()
                    PrayerTimesStrip(currentPrayer: state.currentTodayBlock(now: now)?
                        .isYesterdayIsha == false ? state.currentTodayBlock(now: now)?.prayer : nil)

                    if let block = state.currentTodayBlock(now: now) {
                        CurrentPrayerBlock(block: block) {
                            cameraTarget = CameraTarget(prayer: block.prayer, dayKey: block.dayKey)
                        }
                    }

                    MakeUpSection()
                    EarlierTodaySection()
                    UpcomingSection()
                    ExcusedTodayFooter()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }

            if state.celebration != nil {
                CelebrationOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(10)
            }
        }
        .animation(Theme.spring, value: state.celebration != nil)
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(HomeTimeFormat.dayLine(now))
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                Text("Salam, \(displayName)")
                    .font(Theme.sans(24, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.green.opacity(0.25))
                    .offset(x: 20, y: -2)
            }

            Spacer(minLength: 8)

            StreakFlameView(streak: state.profile.streak, isLitToday: streakLitToday)
            XPChip(xp: state.profile.totalXP)
        }
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
    var id: String { "\(dayKey)|\(prayer.rawValue)" }
}
