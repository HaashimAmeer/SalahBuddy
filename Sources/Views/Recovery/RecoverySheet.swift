import SwiftUI
import UIKit

/// The break-card entry point — the Recharge space as a dismissable sheet.
struct RecoverySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                RechargeBody()
                    .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Recharge 🌸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkMuted.opacity(0.5))
                    }
                }
            }
        }
    }
}

// MARK: - Dhikr tab (v3.8 — permanent, for everyone)

/// The dedicated Dhikr tab: the same Recharge space, always available, with a
/// page header instead of a sheet close button.
struct DhikrView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    RechargeBody()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Dhikr")
                .font(Theme.sans(30, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("📿").font(.system(size: 22))
            Spacer()
        }
        .padding(.top, 16)
    }
}

// MARK: - Shared Recharge body

/// A real digital tasbih counter (unlimited taps) + good-deed prompts. Dhikr
/// and deeds earn XP toward your level and the weekly scoreboard, up to a
/// state-aware daily cap — past it the act keeps going, just without points.
/// Shared by the Dhikr tab and the break-card sheet.
struct RechargeBody: View {
    @EnvironmentObject private var state: AppState

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            intro
            tasbihCard
            xpNote
            deedsSection
        }
    }

    private var intro: some View {
        Text(state.isOnBreak
             ? "Worship that still counts while you rest. Take your time — none of this is timed."
             : "A little dhikr, any time. Earn a bit of XP — and a lot more than points.")
            .font(Theme.sans(13, .semibold))
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Tasbih

    private var tasbihCard: some View {
        let total = state.dhikrToday
        let p = Recharge.position(forTotal: total)
        return VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(p.phrase.arabic)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Theme.inkDeep)
                Text(p.phrase.translit)
                    .font(Theme.sans(18, .bold))
                    .foregroundStyle(Theme.green)
                Text(p.phrase.meaning)
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            Button {
                tap(currentPhraseIndex: p.phraseIndex)
            } label: {
                ZStack {
                    Circle().fill(Theme.greenSoft.opacity(0.5))
                    Circle()
                        .trim(from: 0, to: CGFloat(p.inSet) / CGFloat(p.phrase.count))
                        .stroke(Theme.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Theme.spring, value: p.inSet)
                    VStack(spacing: 2) {
                        Text("\(p.inSet)")
                            .font(Theme.sans(56, .heavy))
                            .foregroundStyle(Theme.inkDeep)
                            .contentTransition(.numericText())
                        Text("of \(p.phrase.count)")
                            .font(Theme.sans(14, .bold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(width: 210, height: 210)
                .scaleEffect(pulse ? 0.96 : 1)
            }
            .buttonStyle(.plain)

            Text("Tap to count")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted.opacity(0.8))

            HStack(spacing: 16) {
                Label("\(total) today", systemImage: "sparkles")
                Label("\(total / Recharge.roundTotal) rounds", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(Theme.sans(12, .bold))
            .foregroundStyle(Theme.gold)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func tap(currentPhraseIndex: Int) {
        state.tapTasbih()
        let newIndex = Recharge.position(forTotal: state.dhikrToday).phraseIndex
        // Heavier feedback when a 33/34 set just completed (phrase changed).
        UIImpactFeedbackGenerator(style: newIndex != currentPhraseIndex ? .heavy : .light)
            .impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { pulse = true }
        withAnimation(.easeOut(duration: 0.20).delay(0.08)) { pulse = false }
    }

    private var xpNote: some View {
        Group {
            if state.isRecoveryCapped {
                Text("You've reached today's max XP 🤍 — keep going, it's all for Allah now")
            } else {
                Text("+\(state.recoveryXPToday) XP today · up to \(state.recoveryDisplayCeiling), then it's all for Allah")
            }
        }
        .font(Theme.sans(12.5, .semibold))
        .foregroundStyle(Theme.lilac)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Good deeds

    private var deedsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Good deeds for today")
                .font(Theme.sans(16, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("A fresh set each day — tap when you've done one.")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted)

            ForEach(Recharge.goodDeeds) { deed in
                deedRow(deed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deedRow(_ deed: GoodDeed) -> some View {
        let done = state.deedsDoneToday.contains(deed.id)
        return Button {
            guard !done else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { state.completeDeed(deed.id) }
        } label: {
            HStack(spacing: 12) {
                Text(deed.emoji).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text(deed.title)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkDeep)
                    if let arabic = deed.arabic {
                        Text(arabic)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.green)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(done ? Theme.green : Theme.mist)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(done ? Theme.greenSoft.opacity(0.6) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(done ? Theme.green.opacity(0.4) : Theme.mist.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

// MARK: - Resume sheet (v3.6 — design session)

/// Ends a break by asking WHEN prayers actually resumed — people often start
/// praying again and forget to log for a day, so "just now" isn't always
/// right. Picking a prayer un-excuses today from that prayer onward; "before
/// today" un-excuses the whole day (older days can be edited in Journey).
struct ResumeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNow) private var now

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Theme.mist.opacity(0.6))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text("Welcome back 🌙")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("When did you start praying again? Prayers from then on count today — earlier ones stay excused.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    option(title: "Just now", subtitle: currentPrayerSubtitle, emoji: "✨") {
                        resume(at: state.currentTodayBlock(now: now)?
                            .isYesterdayIsha == false
                            ? state.currentTodayBlock(now: now)?.prayer : nil)
                    }
                    ForEach(startedPrayers, id: \.self) { prayer in
                        option(title: "Since \(prayer.displayName)",
                               subtitle: windowTime(prayer), emoji: prayer.emoji) {
                            resume(at: prayer)
                        }
                    }
                    option(title: "Before today", subtitle: "The whole day counts", emoji: "📅") {
                        resume(at: nil)
                    }
                }
                .padding(.horizontal, 20)
            }

            Button("Not yet — stay on break") { dismiss() }
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    /// Today's prayers whose windows already opened — the plausible answers.
    private var startedPrayers: [Prayer] {
        guard let schedule = state.todaySchedule else { return [] }
        return schedule.windows
            .filter { $0.start <= now }
            .sorted { $0.start < $1.start }
            .map(\.prayer)
    }

    private var currentPrayerSubtitle: String {
        if let block = state.currentTodayBlock(now: now), !block.isYesterdayIsha {
            return "\(block.prayer.displayName) onward counts"
        }
        return "From here on out"
    }

    private func windowTime(_ prayer: Prayer) -> String {
        guard let window = state.todaySchedule?.window(for: prayer) else { return "" }
        return window.start.formatted(date: .omitted, time: .shortened)
    }

    private func resume(at prayer: Prayer?) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(Theme.spring) { state.resumePrayers(startingAgainAt: prayer) }
        dismiss()
    }

    private func option(title: String, subtitle: String, emoji: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(emoji).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.6))
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
