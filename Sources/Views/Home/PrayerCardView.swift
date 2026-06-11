import SwiftUI

/// One prayer card with all four status presentations:
/// upcoming (dimmed), open (highlighted + CTA), logged (check, long-press
/// undo), missedWindow (muted + Qada button).
struct PrayerCardView: View {
    let prayer: Prayer

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        let status = state.status(of: prayer)

        Group {
            if case .logged = status {
                card(status: status)
                    .onLongPressGesture(minimumDuration: 0.5) {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        withAnimation(Theme.spring) { state.undoLog(prayer) }
                    }
            } else {
                card(status: status)
            }
        }
        .animation(Theme.spring, value: status)
    }

    // MARK: - Card

    private func card(status: PrayerStatus) -> some View {
        VStack(spacing: 12) {
            header(status: status)

            if case .open = status {
                openControls
            }
            if case .missedWindow = status {
                qadaButton
            }
        }
        .padding(14)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accent, lineWidth: isOpen(status) ? 2.5 : 0)
        )
        .opacity(opacity(for: status))
    }

    private func header(status: PrayerStatus) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Text(prayer.emoji)
                    .font(.system(size: 22))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(prayer.displayName)
                    .font(Theme.rounded(18))
                    .foregroundStyle(Theme.ink)
                Text(windowText)
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }

            Spacer(minLength: 8)

            trailing(status: status)
        }
    }

    @ViewBuilder
    private func trailing(status: PrayerStatus) -> some View {
        switch status {
        case .upcoming(let opensAt):
            Text("Opens in \(HomeTimeFormat.countdown(to: opensAt, from: now))")
                .font(Theme.rounded(13, .bold))
                .foregroundStyle(Theme.inkSoft)

        case .open(let closesAt):
            Text("\(HomeTimeFormat.countdown(to: closesAt, from: now)) left")
                .font(Theme.rounded(13, .heavy))
                .foregroundStyle(accent)

        case .logged(let tier):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tier.label)
                        .font(Theme.rounded(13, .heavy))
                        .foregroundStyle(Theme.green)
                    Text("+\(tier.xp) XP")
                        .font(Theme.rounded(12, .bold))
                        .foregroundStyle(Theme.gold)
                    Text("hold to undo")
                        .font(Theme.rounded(9, .semibold))
                        .foregroundStyle(Theme.inkSoft.opacity(0.8))
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.green)
            }

        case .missedWindow:
            Text("Missed")
                .font(Theme.rounded(13, .heavy))
                .foregroundStyle(Theme.coral.opacity(0.85))
        }
    }

    // MARK: - Controls

    private var openControls: some View {
        VStack(spacing: 10) {
            if let tier = state.potentialTier(for: prayer) {
                Text("+\(tier.xp) XP if you pray now")
                    .font(Theme.rounded(13, .heavy))
                    .foregroundStyle(Theme.gold)
            }
            ChunkyButton(title: "I prayed 🤲", color: Theme.green, isEnabled: true) {
                withAnimation(Theme.spring) { state.log(prayer) }
            }
        }
    }

    private var qadaButton: some View {
        Button {
            withAnimation(Theme.spring) { state.log(prayer) }
        } label: {
            Text("Make up (Qada) +5 XP")
                .font(Theme.rounded(13, .bold))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Theme.cream)
                        .overlay(Capsule().stroke(Theme.inkSoft.opacity(0.45), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var accent: Color { Theme.color(for: prayer) }

    private var windowText: String {
        guard let window = state.todaySchedule?.window(for: prayer) else { return "—" }
        return "\(HomeTimeFormat.clock(window.start)) – \(HomeTimeFormat.clock(window.end))"
    }

    private func isOpen(_ status: PrayerStatus) -> Bool {
        if case .open = status { return true }
        return false
    }

    private func opacity(for status: PrayerStatus) -> Double {
        switch status {
        case .upcoming: return 0.55
        case .missedWindow: return 0.7
        case .open, .logged: return 1.0
        }
    }
}
