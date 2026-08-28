import SwiftUI
import UIKit

/// The capture sheet flow around `CameraCaptureView`:
/// capture → confirm (jamaat toggle + optional place tag) → PhotoStore.save →
/// appState.log → drop the JPEG if the log didn't take it → dismiss (the
/// existing celebration overlay then fires on Today).
/// Owned by the home agent.
struct CameraFlowSheet: View {
    let target: CameraTarget

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var captured: UIImage?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let image = captured {
                PostConfirmView(prayer: target.prayer,
                                image: image,
                                onPost: { jamaat, place, placeName in
                                    post(image, jamaat: jamaat, place: place, placeName: placeName)
                                },
                                onRetake: { captured = nil },
                                onCancel: { dismiss() })
            } else {
                CameraCaptureView(onCapture: { captured = $0 },
                                  onCancel: { dismiss() })
            }
        }
        .interactiveDismissDisabled(captured != nil)
    }

    /// Write the JPEG, log the prayer, and — if the log did not take the
    /// photo — take the photo back.
    ///
    /// The write has to come FIRST and stays that way: `log` mirrors to the
    /// circle from inside itself, and `PhotoSync` re-reads the file off the
    /// disk when the outbox drains, so a photo written after the log would race
    /// its own upload.
    ///
    /// v4.1: which is why the cleanup is at the end instead. `log` and
    /// `logCombined` report a refusal by simply not appending — no target
    /// window, the prayer already logged, the window not open yet — and the
    /// window LAPSING while the confirm screen sat open is worse than a
    /// refusal: the log lands, as qada, and `buildLog` deliberately drops the
    /// photo. Both leave a JPEG on the disk that nothing references and nothing
    /// would ever come back for, so ask the logs, not the flow, whether the
    /// file is still wanted (`GameEngine.isPhotoOrphaned`) — a travel pair
    /// shares one photo across two logs and that has to keep counting as
    /// wanted.
    private func post(_ image: UIImage, jamaat: Bool, place: PlaceTag?, placeName: String?) {
        // Photo-save failure (disk) must never lose the prayer: an empty
        // filename from PhotoStore.save is treated as "no photo".
        let saved = PhotoStore.save(image, dayKey: target.dayKey, prayer: target.prayer)
        let filename = saved.isEmpty ? nil : saved
        withAnimation(Theme.spring) {
            if let lead = target.combinedLead {
                state.logCombined(lead: lead, photoFilename: filename, jamaat: jamaat,
                                  placeTag: place, placeName: placeName)
            } else {
                state.log(target.prayer, photoFilename: filename, jamaat: jamaat,
                          placeTag: place, placeName: placeName)
            }
        }
        PhotoStore.deleteIfOrphaned(filename, in: state.logs)
        dismiss()
    }
}

// MARK: - Confirm step

/// Photo preview + optional "Prayed in jamaat 🕌" toggle (+5 XP) + optional
/// one-tap place tag + post CTA. Tagging is never required — skipping is fine.
struct PostConfirmView: View {
    let prayer: Prayer
    let image: UIImage
    let onPost: (Bool, PlaceTag?, String?) -> Void
    let onRetake: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var state: AppState

    @State private var jamaat = false
    @State private var place: PlaceTag?
    @State private var autoSuggested = false

    /// Reverse-geocoded spot name, only attached for the "On the go" tag and
    /// only when the device location actually resolved one.
    private var resolvedPlaceName: String? {
        guard place == .onTheGo else { return nil }
        return state.location.placeName
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                header

                preview

                jamaatToggle

                placePicker

                if let tier = state.potentialTier(for: prayer), tier.isInWindow {
                    Text("+\(GameEngine.prayerXP(tier: tier, jamaat: jamaat)) XP — \(jamaat ? "Jamaat 🕌" : tier.label)")
                        .font(Theme.sans(15, .bold))
                        .foregroundStyle(Theme.gold)
                        .animation(Theme.spring, value: jamaat)
                }

                // v3.9: no circle yet → nowhere to post it "to".
                ChunkyButton(title: state.isSoloMode ? "Post your prayer 🎉" : "Post to your circle 🎉",
                             color: Theme.green, isEnabled: true) {
                    onPost(jamaat, place, resolvedPlaceName)
                }

                Button(action: onRetake) {
                    Text("Retake photo")
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .onAppear {
            // Near a remembered place? Pre-select its tag — one less tap.
            if place == nil, let suggestion = state.suggestedPlaceTag() {
                place = suggestion
                autoSuggested = true
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(prayer.emoji) \(prayer.displayName)")
                    .font(Theme.sans(22, .bold))
                    .foregroundStyle(Theme.inkDeep)
                Text("Looking good — mashallah ✨")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
    }

    /// v3.2: on Fridays the Dhuhr toggle is labelled Jumma (same 30 floor).
    private var isJumma: Bool {
        GameEngine.isJumma(prayer: prayer, date: AppClock.now)
    }

    /// v3: the whole card is the tap target — a big selectable chip instead
    /// of a small iOS toggle nobody noticed.
    private var jamaatToggle: some View {
        Button {
            jamaat.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 12) {
                Text("🕌")
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isJumma ? "Prayed Jumma" : "Prayed in jamaat")
                        .font(Theme.sans(16, .bold))
                        .foregroundStyle(Theme.inkDeep)
                    Text(isJumma
                         ? "It's Friday! Jumma lifts this prayer to 30 XP"
                         : "Prayed in a group? Lifts this prayer to 30 XP")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: jamaat ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(jamaat ? Theme.green : Theme.mist)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(jamaat ? Theme.greenSoft : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(jamaat ? Theme.green : Theme.mist.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: jamaat)
    }

    private var placePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where did you pray? (optional)")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 8) {
                ForEach(PlaceTag.allCases) { tag in
                    placeChip(tag)
                }
            }
            if autoSuggested, let place {
                Text("Looks like you're near your \(place.displayName.lowercased()) — tap to change.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.green)
                    .transition(.opacity)
            } else if let place, place != .onTheGo, state.location.deviceCoordinate != nil,
                      !state.savedPlaceTags.contains(place) {
                Text("We'll remember this spot as your \(place.displayName.lowercased()) and suggest it next time.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .transition(.opacity)
            }
            if place == .onTheGo {
                Text(state.location.placeName.map { "📍 \($0)" } ?? "📍 Using your current spot")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.qadaBlue)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .animation(Theme.spring, value: place)
    }

    private func placeChip(_ tag: PlaceTag) -> some View {
        let selected = place == tag
        return Button {
            place = selected ? nil : tag   // tap again to clear — never forced
            autoSuggested = false
        } label: {
            VStack(spacing: 3) {
                Text(tag.emoji).font(.system(size: 20))
                Text(tag.displayName)
                    .font(Theme.sans(11, selected ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? Theme.greenSoft : Theme.bg,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Theme.green : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Theme.inkDeep : Theme.inkMuted)
        }
        .buttonStyle(.plain)
    }
}
