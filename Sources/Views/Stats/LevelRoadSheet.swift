import SwiftUI

/// v3: the level road — every level laid out like a game progression map
/// (the "what's ahead" view Clash Royale players expect). Past levels are
/// checked off, the current level shows live progress, future levels show
/// the XP they'll take and the title you unlock at each tier.
struct LevelRoadSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Show the whole title ladder plus a bit of runway past wherever you are.
    private var maxLevel: Int {
        max(GameEngine.levelTitles.count * 5, state.level + 10)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(1...maxLevel, id: \.self) { level in
                                row(level: level)
                                    .id(level)
                            }
                            Text("…and beyond ✨")
                                .font(Theme.sans(13, .semibold))
                                .foregroundStyle(Theme.inkMuted)
                                .padding(.vertical, 18)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    }
                    .onAppear { proxy.scrollTo(state.level, anchor: .center) }
                }
            }
            .navigationTitle("Level road")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkMuted.opacity(0.5))
                    }
                }
            }
        }
    }

    // MARK: Row

    private func row(level: Int) -> some View {
        let status = status(of: level)
        let isTitleTier = titleChanges(at: level)

        return HStack(spacing: 14) {
            VStack(spacing: 0) {
                connector(visible: level > 1, done: level <= state.level)
                badge(level: level, status: status, highlighted: isTitleTier)
                connector(visible: level < maxLevel, done: level < state.level)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Level \(level)")
                        .font(Theme.sans(16, status == .current ? .heavy : .bold))
                        .foregroundStyle(status == .locked ? Theme.inkMuted : Theme.inkDeep)
                    if isTitleTier {
                        Text(GameEngine.title(forLevel: level))
                            .font(Theme.sans(11, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(status == .locked ? Theme.mist : Theme.green))
                    }
                }

                switch status {
                case .done:
                    Text("Cleared 💪")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                case .current:
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.greenSoft)
                                Capsule()
                                    .fill(LinearGradient(colors: [Theme.gold, Theme.green],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(8, geo.size.width * progress))
                            }
                        }
                        .frame(height: 8)
                        Text("\(state.xpIntoLevel) / \(state.xpNeededForLevel) XP — you are here")
                            .font(Theme.sans(12, .bold))
                            .foregroundStyle(Theme.green)
                    }
                case .locked:
                    Text("+\(GameEngine.xpToAdvance(from: level - 1)) XP to clear")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.vertical, 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .background {
            if status == .current {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
        }
    }

    // MARK: Pieces

    private enum LevelStatus { case done, current, locked }

    private func status(of level: Int) -> LevelStatus {
        if level < state.level { return .done }
        if level == state.level { return .current }
        return .locked
    }

    /// A new title kicks in every 5 levels (1, 6, 11, …) until the ladder ends.
    private func titleChanges(at level: Int) -> Bool {
        guard (level - 1) % 5 == 0 else { return false }
        return (level - 1) / 5 < GameEngine.levelTitles.count
    }

    private var progress: Double {
        guard state.xpNeededForLevel > 0 else { return 0 }
        return min(1, Double(state.xpIntoLevel) / Double(state.xpNeededForLevel))
    }

    private func badge(level: Int, status: LevelStatus, highlighted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(status == .locked ? Theme.surface
                      : status == .current ? Theme.green
                      : Theme.greenSoft)
                .overlay(Circle().strokeBorder(
                    status == .locked ? Theme.mist.opacity(0.7)
                    : Theme.green,
                    lineWidth: status == .current ? 0 : 1.5))

            switch status {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.green)
            case .current:
                Text("\(level)")
                    .font(Theme.sans(15, .heavy))
                    .foregroundStyle(.white)
            case .locked:
                Text("\(level)")
                    .font(Theme.sans(14, .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(width: highlighted ? 40 : 34, height: highlighted ? 40 : 34)
        .overlay {
            if highlighted && status != .done {
                Circle()
                    .strokeBorder(Theme.gold, lineWidth: 2)
                    .padding(-3)
            }
        }
    }

    private func connector(visible: Bool, done: Bool) -> some View {
        Rectangle()
            .fill(done ? Theme.green.opacity(0.5) : Theme.mist.opacity(0.5))
            .frame(width: 3, height: 14)
            .opacity(visible ? 1 : 0)
    }
}

#if DEBUG
#Preview {
    LevelRoadSheet()
        .environmentObject(AppState())
}
#endif
