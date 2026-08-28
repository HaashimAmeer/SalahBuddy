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
///
/// Everything the confirm stage promises is asked of ONE seam,
/// `AppState.postOutlook` — which prayers a tap writes, at which tier, and
/// whether it writes anything at all. The XP line, the countdown card and the
/// Post button each read it themselves, on the clock, so they cannot disagree
/// with each other or with the log that follows.
struct CameraFlowSheet: View {
    let target: CameraTarget

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var captured: UIImage?
    /// Set ONLY when the window lapsed under this flow and the log landed as a
    /// make-up. On the success path it stays nil and nothing here changes.
    @State private var lapse: GameEngine.LapseSummary?
    /// One tap is all this screen gets. See `post`.
    @State private var hasPosted = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let lapse {
                LapsedWindowNotice(name: lapse.name, xp: lapse.xp, onDone: { dismiss() })
            } else if let image = captured {
                PostConfirmView(prayer: target.prayer,
                                combinedLead: target.combinedLead,
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
    ///
    /// v4.1: and ONE tap is all it gets. The swap to `LapsedWindowNotice` runs
    /// under `Theme.spring`, so for the length of that animation the Post
    /// button is still on screen fading out — and a second tap used to run all
    /// of this again: another JPEG written, the log refused this time (already
    /// logged), the JPEG deleted as an orphan, `added` empty, and the `guard`
    /// below dismissing the very explanation the first tap had just earned.
    /// Harmless before this screen existed; the whole point of it now.
    private func post(_ image: UIImage, jamaat: Bool, place: PlaceTag?, placeName: String?) {
        guard !hasPosted else { return }
        hasPosted = true
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
        withAnimation(Theme.spring) { lapse = GameEngine.LapseSummary(added: added) }
    }
}

// MARK: - Confirm step

/// Photo preview + optional "Prayed in jamaat 🕌" toggle (+5 XP) + optional
/// one-tap place tag + post CTA. Tagging is never required — skipping is fine.
struct PostConfirmView: View {
    let prayer: Prayer
    /// v4.1: set when this post is a travel pair (jam'), mirroring
    /// `CameraTarget.combinedLead`. Both strips below need it: what the tap
    /// writes is two logs judged against the COMBINED window, and neither the
    /// XP it promises nor the make-up it warns about is the single-prayer one.
    let combinedLead: Prayer?
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

                PotentialXPLine(prayer: prayer, combinedLead: combinedLead, jamaat: jamaat)

                // v4.1: sits directly under the XP line because it is that line
                // that expires. Renders nothing at all until the window is
                // nearly out, so an ordinary post never sees it.
                WindowClosingNotice(prayer: prayer, combinedLead: combinedLead,
                                    windowEnd: windowEnd)

                // v3.9: no circle yet → nowhere to post it "to".
                PostCTA(prayer: prayer, combinedLead: combinedLead, solo: state.isSoloMode) {
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

/// The "+30 XP — On time! ⚡" line, in the same place and the same paint — but
/// now on a clock, and now quoting the tap it is actually attached to.
///
/// It was a snapshot before: nothing here read the time, so the line kept
/// promising whatever tier was current when the screen was built. Left alone
/// it would sit directly above a notice saying the window had CLOSED, still
/// offering 30 XP for a tap that would book a make-up. So it moved into its own
/// view, which reads `\.appNow` and re-renders once a second — the tier falls
/// through the quarters as they pass, and the line leaves the screen at the
/// same instant `WindowClosingNotice` starts saying the window is gone.
///
/// It asks `AppState.postOutlook`, the same seam the notice below it asks, and
/// that is the point: a travel pair used to be priced off the LEAD prayer's own
/// window while the countdown beside it ran on the pair's, so at Dhuhr's end
/// the line vanished on a tap that still paid in-window XP for three more
/// hours. One seam, one window, and the number is the whole tap — 30 for a pair
/// posting two prayers, not 15 with the other half unmentioned.
private struct PotentialXPLine: View {
    let prayer: Prayer
    let combinedLead: Prayer?
    let jamaat: Bool

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        if let outlook = state.postOutlook(prayer: prayer, combinedLead: combinedLead, at: now),
           outlook.tier.isInWindow {
            Text("+\(outlook.xp(jamaat: jamaat)) XP — \(jamaat ? "Jamaat 🕌" : outlook.tier.label)")
                .font(Theme.sans(15, .bold))
                .foregroundStyle(Theme.gold)
                .animation(Theme.spring, value: jamaat)
        }
    }
}

/// The Post button — the third small strip on its own clock, for the same
/// reason as the two above it.
///
/// It is off exactly when the tap would be REFUSED: `postOutlook` returning nil
/// is `AppState.log` appending nothing, and a tap that writes no log, no XP and
/// no photo must not look like a tap that saves a prayer. Today the one way to
/// reach that is a pre-fajr yesterday-isha block whose end passed while this
/// screen was open, and the card directly above says so in words — this is the
/// button agreeing with it. Every ordinary post sees a live green button, on
/// every frame, and never learns any of this exists.
private struct PostCTA: View {
    let prayer: Prayer
    let combinedLead: Prayer?
    let solo: Bool
    let onPost: () -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        ChunkyButton(title: solo ? "Post your prayer 🎉" : "Post to your circle 🎉",
                     color: Theme.green,
                     isEnabled: state.postOutlook(prayer: prayer, combinedLead: combinedLead,
                                                  at: now) != nil,
                     action: onPost)
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
/// `GameEngine.lapseNotice` decides WHEN; `AppState.postOutlook` decides what
/// it is allowed to promise. This only draws. Amber, because amber is how this
/// app raises its voice (`Theme.mist` for missed, never red).
///
/// The make-up it names is asked for, never assumed. Two reasons, and the
/// second one is why this card is worth its complexity:
///
/// - A travel pair posts TWO make-ups from one tap, so the number is 10.
///   Hard-coding `qada.xp` had this card saying 5 and `LapsedWindowNotice`
///   saying 10 about the same tap, thirty seconds apart.
/// - Sometimes there is no make-up at all. Past the end of a PRE-FAJR
///   yesterday-isha block, `AppState.log` refuses outright — tonight's isha has
///   not opened — and nothing whatsoever is written. Promising "+5 XP, it still
///   counts" there would be a false confirmation of a save on the one screen
///   this exists to make honest, so `postOutlook` is asked at the deadline (for
///   the countdown's tail) and at `now` (for the closed card), and when the
///   answer is `nil` the copy says what really happens instead.
private struct WindowClosingNotice: View {
    let prayer: Prayer
    let combinedLead: Prayer?
    let windowEnd: Date

    @EnvironmentObject private var state: AppState
    @Environment(\.appNow) private var now

    var body: some View {
        let landing = outlook(at: now)
        switch GameEngine.lapseNotice(windowEnd: windowEnd, now: now) {
        case .none:
            EmptyView()
        case .closingSoon:
            notice(headline: "\(name(landing)) closes in \(HomeTimeFormat.countdown(to: windowEnd, from: now))",
                   detail: detail(afterTheDeadline: outlook(at: windowEnd)))
        case .closed:
            notice(headline: "\(name(landing))'s window has closed",
                   detail: closedDetail(landing))
        }
    }

    /// What a tap at `when` would actually write, or nil if it would be refused.
    private func outlook(at when: Date) -> PostOutlook? {
        state.postOutlook(prayer: prayer, combinedLead: combinedLead, at: when)
    }

    /// What is closing. The outlook names it when there is one (a pair reads
    /// "Dhuhr + Asr"); past a refusal there is no outlook left to ask, so fall
    /// back to what the flow set out to post.
    private func name(_ landing: PostOutlook?) -> String {
        landing?.name ?? GameEngine.postName(pairOrSingle)
    }

    private var pairOrSingle: [Prayer] {
        guard let lead = combinedLead, let follow = TravelPairs.partner(of: lead) else {
            return [prayer]
        }
        return [lead, follow]
    }

    /// The countdown's second line: what the NEXT tap does once the clock runs
    /// out — a make-up, or nothing at all.
    private func detail(afterTheDeadline after: PostOutlook?) -> String {
        guard let after, after.tier == .qada else {
            return "Post before then — once it closes there's nothing left here to save it to."
        }
        return "Post before then to keep this XP. After that it saves as a make-up (+\(after.makeUpXP) XP) and the photo isn't kept."
    }

    /// The closed card. `landing` is what a tap right now would write, so the
    /// promise is not a prediction at all — it is the current answer.
    private func closedDetail(_ landing: PostOutlook?) -> String {
        guard let landing, landing.tier == .qada else {
            return "It closed before this was posted, so there's nothing left here to save it to and the photo isn't kept. You can still mark it made up from that day in Journey 💙"
        }
        return "Posting now saves it as a make-up (+\(landing.makeUpXP) XP), and the photo isn't kept. It still counts 💙"
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
///
/// Both numbers come from `GameEngine.LapseSummary`, which reads the logs that
/// landed — pure, and tested, because a summed XP living beside its own label
/// in a view file is exactly where "+10" quietly goes back to being "+5".
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
