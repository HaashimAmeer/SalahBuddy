import SwiftUI
import UIKit

/// v3.5: the "Recharge" space, reachable from the break card. A real digital
/// tasbih counter (unlimited) plus a few good-deed prompts. Dhikr/deeds earn
/// private XP up to a gentle daily cap — past it the act keeps going, just
/// without points. None of it ever touches the circle scoreboard.
struct RecoverySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    intro
                    tasbihCard
                    xpNote
                    deedsSection
                }
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

    private var intro: some View {
        Text("Worship that still counts while you rest. Take your time — none of this is timed or capped.")
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
                Text("You've earned today's XP — keep going for the reward that isn't points 🤍")
            } else {
                Text("+\(state.recoveryXPToday) XP today · up to \(GameEngine.recoveryDailyXPCap), then it's all for Allah")
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
