import SwiftUI

// Owned by the components agent.
/// BeReal-style 2-column grid of the circle's tiles for one prayer.
/// Each cell is a `PhotoSquare` (all five GridEntryState looks). `compact`
/// tightens spacing for collapsed "earlier today" blocks.
struct PrayerPhotoGrid: View {
    let entries: [GridEntry]
    let compact: Bool

    private var spacing: CGFloat { compact ? 8 : 12 }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: spacing),
                GridItem(.flexible(), spacing: spacing),
            ],
            spacing: spacing
        ) {
            ForEach(entries) { entry in
                SquareCell(entry: entry)
            }
        }
    }
}

/// Sizes a PhotoSquare to the grid column width while keeping cells square.
private struct SquareCell: View {
    let entry: GridEntry

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    PhotoSquare(entry: entry, size: geo.size.width)
                }
            )
    }
}

#if DEBUG
#Preview {
    let you = CircleMember(id: "you", name: "You", emoji: "🙂", isYou: true)
    let mina = CircleMember(id: "mina", name: "Mina", emoji: "🌸", isYou: false)
    let harun = CircleMember(id: "harun", name: "Harun", emoji: "🧢", isYou: false)
    let haifa = CircleMember(id: "haifa", name: "Haifa", emoji: "📚", isYou: false)
    return ScrollView {
        PrayerPhotoGrid(entries: [
            GridEntry(id: "1", member: mina,
                      state: .posted(.illustration(seed: 7), tier: .onTime, at: AppClock.now)),
            GridEntry(id: "2", member: harun, state: .qada(at: AppClock.now)),
            GridEntry(id: "3", member: haifa, state: .missed),
            GridEntry(id: "4", member: you, state: .waiting),
        ], compact: false)
        .padding()
    }
    .background(Theme.bg)
}
#endif
