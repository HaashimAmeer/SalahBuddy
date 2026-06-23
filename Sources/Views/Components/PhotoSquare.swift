import SwiftUI

// Owned by the components agent.
/// One member's tile in a `PrayerPhotoGrid` — all five §3 presentations:
/// - waiting: dashed square with the member's avatar emoji
/// - posted:  photo (lazy thumbnail via PhotoStore) or seeded illustration,
///            with name + timestamp + tier dot
/// - qada:    blue "Made up" tile (no photo, ever)
/// - missed:  quiet mist tile
/// - excused: lilac moon tile
struct PhotoSquare: View {
    let entry: GridEntry
    let size: CGFloat
    /// v3.8: flush mode for the Today grid — square (un-rounded) cells with no
    /// location pill, so a 2×2 fills the card edge-to-edge (the outer card does
    /// the rounding). Other surfaces keep the rounded standalone tile.
    var flush: Bool = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var cornerRadius: CGFloat { flush ? 0 : max(12, size * 0.14) }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .waiting:
            waitingTile
        case .posted(let content, let tier, let at):
            postedTile(content: content, tier: tier, at: at)
        case .qada(let at):
            qadaTile(at: at)
        case .missed:
            missedTile
        case .excused:
            excusedTile
        }
    }

    // MARK: Waiting — dashed square w/ avatar emoji

    private var waitingTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.greenSoft.opacity(0.35))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Theme.inkMuted.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            VStack(spacing: size * 0.05) {
                Text(entry.member.emoji)
                    .font(.system(size: size * 0.26))
                Text(entry.member.name)
                    .font(Theme.sans(nameFontSize, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Posted — image/illustration + name + timestamp + tier dot

    private func postedTile(content: PostContent, tier: LogTier, at: Date) -> some View {
        ZStack(alignment: .bottomLeading) {
            switch content {
            case .photo(let filename):
                LazyThumbnail(filename: filename, pixelSize: size)
            case .illustration(let seed):
                IllustratedPrayerCard(seed: seed)
            }

            // Soft scrim so the caption reads on any image.
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                // v3: where they prayed, when tagged — "🏠 Home", "📍 Capitol Hill".
                // v3.8: hidden in the flush Today grid (it moves to tap-to-enlarge).
                if let place = entry.placeLabel, size >= 70, !flush {
                    Text(place)
                        .font(Theme.sans(max(8, size * 0.07), .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                HStack(spacing: 4) {
                    Text(entry.member.name)
                        .font(Theme.sans(nameFontSize, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text(Self.timeFormatter.string(from: at))
                        .font(Theme.sans(max(8, size * 0.075), .semibold))
                        .opacity(0.9)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.07)
            .padding(.bottom, size * 0.055)
        }
        .overlay(alignment: .topTrailing) {
            // Tier dot — §2 grid color language.
            Circle()
                .fill(Theme.color(for: .inWindow(tier)))
                .frame(width: size * 0.11, height: size * 0.11)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .padding(size * 0.06)
        }
    }

    // MARK: Qada — blue "Made up"

    private func qadaTile(at: Date) -> some View {
        ZStack {
            Theme.qadaBlue.opacity(0.16)
            VStack(spacing: size * 0.045) {
                Text(entry.member.emoji)
                    .font(.system(size: size * 0.20))
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(Theme.qadaBlue)
                Text("Made up")
                    .font(Theme.sans(nameFontSize, .bold))
                    .foregroundStyle(Theme.qadaBlue)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.qadaBlue.opacity(0.35), lineWidth: 1.5))
    }

    // MARK: Missed — quiet mist (never red, no shaming)

    private var missedTile: some View {
        ZStack {
            Theme.mist.opacity(0.4)
            VStack(spacing: size * 0.05) {
                Text(entry.member.emoji)
                    .font(.system(size: size * 0.22))
                    .saturation(0)
                    .opacity(0.55)
                Text(entry.member.name)
                    .font(Theme.sans(nameFontSize, .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    // MARK: Excused — lilac moon

    private var excusedTile: some View {
        ZStack {
            Theme.lilac.opacity(0.20)
            VStack(spacing: size * 0.05) {
                Image(systemName: "moon.fill")
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .foregroundStyle(Theme.lilac)
                Text(entry.member.name)
                    .font(Theme.sans(nameFontSize, .semibold))
                    .foregroundStyle(Theme.lilac)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.lilac.opacity(0.35), lineWidth: 1.5))
    }

    private var nameFontSize: CGFloat { max(9, size * 0.085) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

// MARK: - Member avatar (v3.8)

/// A circular avatar that shows the member's profile photo when it's "you" and
/// a photo is set, otherwise their emoji. Used on the scoreboard, member
/// detail, and week grid.
struct MemberAvatarView: View {
    let member: CircleMember
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(member.emoji).font(.system(size: size * 0.52))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: member.avatarFilename) {
            guard member.isYou, let name = member.avatarFilename else { image = nil; return }
            let side = size * UIScreen.main.scale
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let full = PhotoStore.load(name) else { return nil }
                return full.preparingThumbnail(of: CGSize(width: side, height: side)) ?? full
            }.value
        }
    }
}

// MARK: - Lazy thumbnail loader

/// Loads a stored photo off the main thread and downscales it to roughly the
/// rendered square size, so grids never hold full-res UIImages (§6.10).
private struct LazyThumbnail: View {
    let filename: String
    let pixelSize: CGFloat

    @State private var image: UIImage?
    /// Which filename `image` was loaded for — so a reused cell whose filename
    /// changes reloads instead of showing the previous post's photo (v3.8 bug
    /// fix: SwiftUI reuses these views, and the old `guard image == nil` kept
    /// the stale image).
    @State private var loadedFor: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.greenSoft.opacity(0.5)
                Image(systemName: "photo")
                    .font(.system(size: max(14, pixelSize * 0.16)))
                    .foregroundStyle(Theme.inkMuted.opacity(0.5))
            }
        }
        .task(id: filename) {
            guard loadedFor != filename else { return }
            let name = filename
            let side = max(80, pixelSize) * UIScreen.main.scale
            let thumb = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let full = PhotoStore.load(name) else { return nil }
                return full.preparingThumbnail(of: CGSize(width: side, height: side)) ?? full
            }.value
            image = thumb
            loadedFor = name
        }
    }
}

#if DEBUG
#Preview {
    let mina = CircleMember(id: "mina", name: "Mina", emoji: "🌸", isYou: false)
    let you = CircleMember(id: "you", name: "You", emoji: "🙂", isYou: true)
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        PhotoSquare(entry: GridEntry(id: "1", member: you, state: .waiting), size: 160)
        PhotoSquare(entry: GridEntry(
            id: "2", member: mina,
            state: .posted(.illustration(seed: 42), tier: .onTime, at: AppClock.now)), size: 160)
        PhotoSquare(entry: GridEntry(id: "3", member: mina, state: .qada(at: AppClock.now)), size: 160)
        PhotoSquare(entry: GridEntry(id: "4", member: mina, state: .missed), size: 160)
        PhotoSquare(entry: GridEntry(id: "5", member: mina, state: .excused), size: 160)
    }
    .padding()
    .background(Theme.bg)
}
#endif
