import SwiftUI
import UIKit

/// The capture sheet flow around `CameraCaptureView`:
/// capture → confirm (jamaat toggle + optional place tag) → PhotoStore.save →
/// appState.log → drop the JPEG if the log didn't take it → dismiss (the
/// existing celebration overlay then fires on Today).
/// Owned by the home agent.
///
/// v4.1: the confirm stage has a deadline, and it now says so at both ends.
/// BEFORE — near the window's close, a live countdown under the XP line
/// (`WindowClosingNotice`), because the XP the screen is promising expires.
/// AFTER — if the window closed anyway and the log landed as a make-up, the
/// sheet stops dismissing itself and says what happened (`LapsedWindowNotice`).
/// Capture never warns: there is nothing to lose yet, and a countdown over the
/// viewfinder would only rush the photo.
struct CameraFlowSheet: View {
    let target: CameraTarget

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var captured: UIImage?
    /// Set ONLY when the window lapsed under this flow and the log landed as a
    /// make-up. On the success path it stays nil and nothing here changes.
    @State private var lapse: LapseOutcome?

    /// What actually landed, read off the logs rather than off the target, so
    /// the notice can name it: a travel pair posts two make-ups from one tap
    /// and is worth 10, not 5 — and a pair that `logCombined` could not form
    /// after all posted just the one, which this still gets right.
    private struct LapseOutcome: Equatable {
        let name: String
        let xp: Int

        init(_ added: [PrayerLog]) {
            name = added.map(\.prayer.displayName).joined(separator: " + ")
            xp = added.reduce(0) { $0 + $1.xp }
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let lapse {
                LapsedWindowNotice(name: lapse.name, xp: lapse.xp, onDone: { dismiss() })
            } else if let image = captured {
                PostConfirmView(prayer: target.prayer,
                                image: image,
                                windowEnd: target.windowEnd,
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
    ///
    /// v4.1: and the same lapse is no longer silent. `log` reports what it did
    /// by what it APPENDED, so the ids the array did not have a moment ago are
    /// exactly the logs this tap wrote — ask them their tier, and a `.qada` out
    /// of a flow that started in-window (`GameEngine.lapsedIntoQada`) holds the
    /// sheet open for one short explanation instead of vanishing on 5 XP.
    private func post(_ image: UIImage, jamaat: Bool, place: PlaceTag?, placeName: String?) {
        // Photo-save failure (disk) must never lose the prayer: an empty
        // filename from PhotoStore.save is treated as "no photo".
        let saved = PhotoStore.save(image, dayKey: target.dayKey, prayer: target.prayer)
        let filename = saved.isEmpty ? nil : saved
        let known = Set(state.logs.map(\.id))
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

        let added = state.logs.filter { !known.contains($0.id) }
        guard GameEngine.lapsedIntoQada(added: added, startedInWindow: target.inWindowAtOpen) else {
            dismiss()
            return
        }
        withAnimation(Theme.spring) { lapse = LapseOutcome(added) }
    }
}

// MARK: - Confirm step

/// Photo preview + optional "Prayed in jamaat 🕌" toggle (+5 XP) + optional
/// one-tap place tag + post CTA. Tagging is never required — skipping is fine.
struct PostConfirmView: View {
    let prayer: Prayer
    let image: UIImage
    /// v4.1: when this screen's window closes — see `WindowClosingNotice`.
    let windowEnd: Date
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

                PotentialXPLine(prayer: prayer, jamaat: jamaat, windowEnd: windowEnd)

                // v4.1: sits directly under the XP line because it is that line
                // that expires. Renders nothing at all until the window is
                // nearly out, so an ordinary post never sees it.
                WindowClosingNotice(prayer: prayer, windowEnd: windowEnd)

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

// MARK: - Before: the window is about to close (v4.1)

/// The "+30 XP — On time! ⚡" line, unchanged in every pixel — but now on a
/// clock.
///
/// It was a snapshot before: nothing here read the time, so the line kept
/// promising whatever tier was current when the screen was built. Left alone
/// it would sit directly above a notice saying the window had CLOSED, still
/// offering 30 XP for a tap that would book a make-up. So it moved into its own
/// view, which reads `\.appNow` and re-renders once a second — the tier falls
/// through the quarters as they pass, and the line leaves the screen at the
/// same instant `WindowClosingNotice` starts saying the window is gone.
///
/// The tier still comes from `AppState` (it owns the window and the isha
/// midnight case); `now` is what makes the question get asked again.
private struct PotentialXPLine: View {
    let prayer: Prayer
    let jamaat: Bool
    let windowEnd: Date

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        if GameEngine.lapseNotice(windowEnd: windowEnd, now: now) != .closed,
           let tier = state.potentialTier(for: prayer), tier.isInWindow {
            Text("+\(GameEngine.prayerXP(tier: tier, jamaat: jamaat)) XP — \(jamaat ? "Jamaat 🕌" : tier.label)")
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.gold)
                .animation(Theme.spring, value: jamaat)
        }
    }
}

/// The countdown the confirm screen owes you, and nothing else.
///
/// Like `PotentialXPLine` it reads `\.appNow` ITSELF rather than letting
/// `PostConfirmView` read it, which is the whole point of both being separate
/// views: the two small strips re-render each second and the 330pt photo
/// preview above them is not diffed sixty times a minute. Until the last two
/// minutes this renders EMPTY, so an ordinary post is untouched — it never
/// even learns the screen had a deadline.
///
/// `GameEngine.lapseNotice` decides; this only draws. Amber, because amber is
/// how this app raises its voice (`Theme.mist` for missed, never red).
private struct WindowClosingNotice: View {
    let prayer: Prayer
    let windowEnd: Date

    @Environment(\.appNow) private var now

    var body: some View {
        switch GameEngine.lapseNotice(windowEnd: windowEnd, now: now) {
        case .none:
            EmptyView()
        case .closingSoon:
            notice(headline: "\(prayer.displayName) closes in \(HomeTimeFormat.countdown(to: windowEnd, from: now))",
                   detail: "Post before then to keep this XP. After that it saves as a make-up (+\(LogTier.qada.xp) XP) and the photo isn't kept.")
        case .closed:
            notice(headline: "\(prayer.displayName)'s window has closed",
                   detail: "Posting now saves it as a make-up (+\(LogTier.qada.xp) XP), and the photo isn't kept. It still counts 💙")
        }
    }

    private func notice(headline: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .semibold))
                Text(headline)
                    .font(Theme.sans(14, .bold))
            }
            .foregroundStyle(Theme.amber)

            Text(detail)
                .font(Theme.sans(12.5, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.amber.opacity(0.12))
        )
        .transition(.opacity)
    }
}

// MARK: - After: it closed anyway (v4.1)

/// What the sheet says when the window closed while it was open: the log
/// landed, as a make-up, and `buildLog` dropped the photo on purpose.
///
/// This screen exists because the alternative was nothing. The sheet used to
/// dismiss on the same tap whatever the log decided, so the only evidence that
/// anything had gone differently was 5 XP in a celebration that had just been
/// promising 30 — and a photo that was never anywhere.
///
/// It is deliberately a dead end with one way out: dismissing itself after a
/// beat would put it back in the category of things you can miss.
private struct LapsedWindowNotice: View {
    /// The prayer, or the travel pair posted as one.
    let name: String
    /// What the make-up actually earned — 5, or 10 for a pair.
    let xp: Int
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: "hourglass")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Theme.amber)

            Text("The \(name) window closed")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.inkDeep)
                .multilineTextAlignment(.center)

            Text("It closed while this screen was open, so we saved it as a make-up — +\(xp) XP, and the photo isn't kept.")
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("A make-up still counts 💙")
                .font(Theme.sans(13, .bold))
                .foregroundStyle(Theme.qadaBlue)

            Spacer(minLength: 0)

            ChunkyButton(title: "Got it", color: Theme.green, isEnabled: true) {
                onDone()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
    }
}
