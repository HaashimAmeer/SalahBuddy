import SwiftUI

/// v4.1 — the screen for the places you pray.
///
/// Until now saved places were invisible: one anonymous spot per tag, recorded
/// the first time you tagged it, with no way to see it, name it, move it or
/// remove just one. `AppState` grew `renamePlace`/`reanchorPlace`/
/// `setPlaceRadius`/`forgetPlace` for exactly this screen — everything here is
/// a thin shell over those four calls, so the rules stay in one place.
///
/// Two decisions worth keeping:
///
/// - **The name commits on submit or on losing focus, never per keystroke.**
///   `AppState.settings` persists in its `didSet`, so binding a `TextField`
///   straight through would write `settings.json` on every character typed.
/// - **"Move here" is the answer to the old permanent mistake.** A Home
///   anchored at a friend's house used to stay wrong forever; re-anchoring is
///   the whole reason this screen has to exist rather than just a delete
///   button.
struct SavedPlacesSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingForgetAll = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                if state.settings.savedPlaces.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            ForEach(state.settings.savedPlaces) { place in
                                PlaceCard(place: place)
                            }
                            forgetAllRow
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkMuted.opacity(0.5))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("📍")
                .font(.system(size: 44))
            Text("No places yet")
                .font(Theme.sans(17, .bold))
                .foregroundStyle(Theme.inkDeep)
            Text("Tag a prayer as Home, Masjid or Work and the spot is remembered, so next time you pray nearby the tag is already picked.")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Forget all

    private var forgetAllRow: some View {
        VStack(spacing: 10) {
            if confirmingForgetAll {
                Text("Forget all \(state.settings.savedPlaces.count) places? Tags still work — you just won't get suggestions until you tag somewhere again.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Keep them") {
                        withAnimation(Theme.spring) { confirmingForgetAll = false }
                    }
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .buttonStyle(.plain)

                    Button("Forget all") {
                        state.clearSavedPlaces()
                        confirmingForgetAll = false
                    }
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.amber)
                    .buttonStyle(.plain)
                }
            } else {
                Button("Forget all places") {
                    withAnimation(Theme.spring) { confirmingForgetAll = true }
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - One place

/// A single saved place. Kept as its own view so each card owns the draft name
/// and the focus state that decides when to commit it.
private struct PlaceCard: View {
    let place: SavedPlace

    @EnvironmentObject private var state: AppState
    @FocusState private var nameFocused: Bool

    @State private var draftName: String = ""
    @State private var confirmingForget = false
    @State private var reanchorFailed = false

    /// The radius presets. A house, a big building, a campus — the numbers are
    /// chosen to be recognisable rather than round in metres.
    private static let radiusOptions: [SegmentedChoice<Double>.Option] = [
        .init(250, "House"),
        .init(600, "Building"),
        .init(1_500, "Campus"),
    ]

    private var radiusBinding: Binding<Double> {
        Binding(
            get: {
                // Snap whatever is stored to the nearest preset so a value set
                // on an older build still lights one of the three up.
                Self.radiusOptions
                    .min { abs($0.value - place.radiusMeters) < abs($1.value - place.radiusMeters) }?
                    .value ?? SavedPlace.defaultRadiusMeters
            },
            set: { state.setPlaceRadius(id: place.id, meters: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(Theme.mist.opacity(0.4))
            radiusRow
            actionsRow
            if reanchorFailed {
                Text("No location fix right now — turn location on, or try again outside.")
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .cardStyle()
        .onAppear { draftName = place.name ?? "" }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
    }

    // MARK: Header — emoji, editable name, provenance

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(place.tag.emoji)
                .font(.system(size: 30))

            VStack(alignment: .leading, spacing: 3) {
                TextField(place.tag.displayName, text: $draftName)
                    .font(Theme.sans(16, .bold))
                    .foregroundStyle(Theme.inkDeep)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitName() }
                    .accessibilityLabel("Name for this \(place.tag.displayName)")

                Text(subtitle)
                    .font(Theme.sans(11.5, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    /// "Masjid · praying here since Aug 12, 2026" — the tag is worth repeating
    /// because once a place is named "Al-Noor" nothing else says what it is.
    private var subtitle: String {
        var parts: [String] = [place.tag.displayName]
        if let savedAt = place.savedAt {
            parts.append("praying here since "
                         + savedAt.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Radius

    private var radiusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How close counts")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.inkMuted)
            SegmentedChoice(options: Self.radiusOptions, selection: radiusBinding)
        }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 14) {
            Button {
                reanchorFailed = !state.reanchorPlace(id: place.id)
            } label: {
                Label("Move here", systemImage: "location.fill")
                    .font(Theme.sans(13, .bold))
                    .foregroundStyle(Theme.green)
            }
            .buttonStyle(.plain)

            Spacer()

            if confirmingForget {
                Button("Cancel") {
                    withAnimation(Theme.spring) { confirmingForget = false }
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)

                Button("Forget") {
                    state.forgetPlace(id: place.id)
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.amber)
                .buttonStyle(.plain)
            } else {
                Button("Forget") {
                    withAnimation(Theme.spring) { confirmingForget = true }
                }
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.inkMuted)
                .buttonStyle(.plain)
            }
        }
    }

    private func commitName() {
        guard draftName != (place.name ?? "") else { return }
        state.renamePlace(id: place.id, to: draftName)
    }
}
