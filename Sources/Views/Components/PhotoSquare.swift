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
    /// v3.9: overlay metrics (name, timestamp, tier dot, state glyph) normally
    /// scale with `size`. The solo Today tile is a ~2× hero, which would make
    /// its caption larger than the block title — it passes a smaller `typeSize`
    /// to keep the type near grid scale. Defaults to `size` (unchanged).
    var typeSize: CGFloat? = nil

    /// v4 §4: the synced mirror, published by `RootView`. A tile needs it to
    /// turn a buddy's post into a Storage path; in demo mode (and in a
    /// preview) it is `.empty` and every lookup below short-circuits.
    ///
    /// Declared LAST on purpose: the three above are this view's memberwise
    /// initializer, and an environment property has no business sitting in the
    /// middle of an argument list two other files spell out.
    @Environment(\.circleMirror) private var circleMirror: CircleSnapshot

    /// The metric the overlays scale off (layout still uses `size`).
    private var t: CGFloat { typeSize ?? size }

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
            VStack(spacing: t * 0.05) {
                Text(entry.member.emoji)
                    .font(.system(size: t * 0.26))
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
            // Still exactly two cases, and they still mean what they always
            // meant: `.photo` is a JPEG in `PhotoStore`, which is YOURS and
            // permanent, while `.illustration` is a post with no local file.
            // v4 §4 adds one honest wrinkle to the second — a synced post may
            // have a picture in the circle's bucket, and the illustration is
            // what shows until (or unless) it arrives.
            switch content {
            case .photo(let filename):
                LazyThumbnail(filename: filename, pixelSize: size)
            case .illustration(let seed):
                BuddyRemotePhoto(path: remotePhotoPath, seed: seed, pixelSize: size)
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
                        .font(Theme.sans(max(8, t * 0.075), .semibold))
                        .opacity(0.9)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, t * 0.07)
            .padding(.bottom, t * 0.055)
        }
        .overlay(alignment: .topTrailing) {
            // Tier dot — §2 grid color language. v3.9: the ring scales too, so
            // the hero tile keeps a crisp edge instead of a hairline.
            Circle()
                .fill(Theme.color(for: .inWindow(tier)))
                .frame(width: t * 0.11, height: t * 0.11)
                .overlay(Circle().stroke(.white, lineWidth: max(1.5, t * 0.009)))
                .padding(t * 0.06)
        }
    }

    // MARK: Qada — blue "Made up"

    private func qadaTile(at: Date) -> some View {
        ZStack {
            Theme.qadaBlue.opacity(0.16)
            VStack(spacing: t * 0.045) {
                Text(entry.member.emoji)
                    .font(.system(size: t * 0.20))
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: t * 0.16, weight: .semibold))
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
            VStack(spacing: t * 0.05) {
                Text(entry.member.emoji)
                    .font(.system(size: t * 0.22))
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
            VStack(spacing: t * 0.05) {
                Image(systemName: "moon.fill")
                    .font(.system(size: t * 0.22, weight: .semibold))
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

    /// The Storage path behind this tile's picture, when there is one.
    ///
    /// Resolved HERE rather than carried on `GridEntry` because a remote path
    /// is not a `PostContent.photo`: that case means "a file this app owns",
    /// and everything downstream of it (the thumbnail loader, Memories) treats
    /// it that way. A buddy's picture is a disposable cache entry (§4), so it
    /// travels as a path and is resolved at the one place that draws it.
    ///
    /// Answers nil for your own square, for demo buddies, for a mirror with no
    /// circle and for any id this grid did not build (a SwiftUI preview) —
    /// every case where the seeded illustration is already the right answer.
    private var remotePhotoPath: String? {
        guard !entry.member.isYou, circleMirror.hasCircle else { return nil }
        guard let coords = AppState.gridEntryCoordinates(entry.id) else { return nil }
        let source: RemoteCircleDataSource = RemoteCircleDataSource(snapshot: circleMirror)
        return source.photoPath(forMember: coords.memberID, prayer: coords.prayer,
                                dayKey: coords.dayKey)
    }

    private var nameFontSize: CGFloat { max(9, t * 0.085) }

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

// MARK: - The circle mirror in the environment (v4 §4)

/// Published once by `RootView` so a tile deep in a grid can resolve a buddy's
/// photo path. A value type, `Equatable`, defaulting to `.empty` — which is
/// exactly what demo mode, a solo install and a SwiftUI preview want, and why
/// `PhotoSquare` can stay usable outside the app's environment.
private struct CircleMirrorKey: EnvironmentKey {
    static let defaultValue: CircleSnapshot = .empty
}

extension EnvironmentValues {
    var circleMirror: CircleSnapshot {
        get { self[CircleMirrorKey.self] }
        set { self[CircleMirrorKey.self] = newValue }
    }
}

// MARK: - Buddy photo (v4 §4)

/// A buddy's synced photo, with the seeded illustration underneath it.
///
/// The illustration is NOT an apology for a missing image: it is what a post
/// with no picture legitimately looks like — a join-week backfill never
/// uploads one, and the server sweeps photos after ~30 days — so a path that
/// never resolves lands on a tile that already looks finished. Nothing here
/// shows a spinner, and nothing here shows an error.
///
/// Buddy photos live in `Documents/circlephotos/` and never in `PhotoStore`:
/// they are disposable, they age out with the server's retention, and they
/// must never reach Memories (§4).
private struct BuddyRemotePhoto: View {
    let path: String?
    let seed: UInt64
    let pixelSize: CGFloat

    @State private var image: UIImage?
    /// Which path `image` belongs to. SwiftUI reuses these views, so without it
    /// a recycled cell keeps showing the previous member's photo — the same
    /// bug `LazyThumbnail.loadedFor` exists to prevent.
    @State private var loadedFor: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                IllustratedPrayerCard(seed: seed)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let path, !path.isEmpty else {
            image = nil
            loadedFor = nil
            return
        }
        guard loadedFor != path else { return }
        // v4 §4 FIX: a recycled cell arrives still holding the PREVIOUS path's
        // photo. `loadedFor` stops it being re-LOADED; it never stopped it
        // being re-DISPLAYED — so a tile whose path went A → B and whose fetch
        // for B failed (offline, or the tombstone gate 403-ing a retracted
        // post) kept rendering buddy A's picture under buddy B's name, tier and
        // timestamp, indefinitely. Dropping both up front costs at most one
        // frame of the illustration, which is what a post with no photo
        // legitimately looks like anyway.
        image = nil
        loadedFor = nil
        let side: CGFloat = max(80, pixelSize) * UIScreen.main.scale
        // Disk first, so a photo we already hold never flashes the illustration
        // on its way in.
        if let cached: UIImage = await BuddyRemotePhoto.cachedThumbnail(path: path, side: side) {
            image = cached
            loadedFor = path
            return
        }
        // Coalesced and non-throwing by design: the same photo appears in more
        // than one grid at once, and one that will not load is not an error
        // anybody should be shown.
        guard let fetched: UIImage = await PhotoSync.buddyPhoto(path: path) else { return }
        guard !Task.isCancelled else { return }
        image = await BuddyRemotePhoto.downscaled(fetched, side: side)
        loadedFor = path
    }

    /// Read + decode + downscale, all off the main actor — a grid must never
    /// hold full-resolution images (§6.10), and decoding one on the main thread
    /// is what makes it stutter.
    private static func cachedThumbnail(path: String, side: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let full: UIImage = PhotoSync.cachedBuddyPhoto(path: path) else { return nil }
            return full.preparingThumbnail(of: CGSize(width: side, height: side)) ?? full
        }.value
    }

    private static func downscaled(_ full: UIImage, side: CGFloat) async -> UIImage {
        await Task.detached(priority: .userInitiated) { () -> UIImage in
            full.preparingThumbnail(of: CGSize(width: side, height: side)) ?? full
        }.value
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
