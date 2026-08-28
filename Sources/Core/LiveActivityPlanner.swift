import Foundation

/// v5 §6 — what the Live Activity should be doing, decided from the file the
/// home screen already reads.
///
/// PURE, in the `GameEngine` sense: no clock, no ActivityKit, no singletons,
/// every input passed in. `LiveActivityController` is the effect; this is the
/// decision, and keeping them apart is what makes the whole state machine —
/// start, move, replace, end — testable without a device that can show one.
///
/// **Its input is `WidgetSnapshot`, deliberately.** The Lock Screen and the
/// home screen are two renderings of the same window, and deriving them
/// separately is how they come to disagree: the widget would say "3 of 5" while
/// the Dynamic Island said 2, on the same phone, at the same second, and
/// neither would be wrong about its own source. One derivation
/// (`WidgetSnapshotBuilder`), one file, two surfaces. It also means §7 arrives
/// for free — a reported photo, a rest day and `breakReason` are already gone
/// by the time this sees anything.
enum LiveActivityPlanner {

    /// What one running activity is, as far as this file is concerned.
    struct Running: Equatable {
        var attributes: PrayerWindowAttributes
        var state: PrayerWindowAttributes.ContentState
    }

    enum Plan: Equatable {
        /// Leave things exactly as they are.
        case none
        case start(PrayerWindowAttributes, PrayerWindowAttributes.ContentState)
        case update(PrayerWindowAttributes.ContentState)
        /// The window this activity is about is over, or the file no longer has
        /// one.
        case end
        /// The window MOVED under a running activity — Asr closed and Maghrib
        /// opened while nobody was looking. Attributes are immutable for an
        /// activity's life (they are its identity), so the only way to follow
        /// is to retire the old one and start a new one.
        case restart(PrayerWindowAttributes, PrayerWindowAttributes.ContentState)
    }

    /// The static half: which window this activity is about. nil when the file
    /// has no window at all (no schedule yet — a first launch before any
    /// location is known, or Adhan at an extreme latitude).
    static func attributes(for snapshot: WidgetSnapshot) -> PrayerWindowAttributes? {
        guard let window = snapshot.window else { return nil }
        return PrayerWindowAttributes(prayer: window.prayer,
                                      dayKey: window.dayKey,
                                      endsAt: window.endsAt)
    }

    /// The moving half.
    ///
    /// `faces` are `WidgetSnapshot`'s posts, already newest-first and already
    /// capped — the SAME four the medium widget draws, through the same hide
    /// (§7) and the same photo setting (§9-02). The tier travels as its
    /// rawValue; the photo does not travel at all, because a 4 KB push cannot
    /// carry one and §7 forbids a second store to put one in.
    static func contentState(for snapshot: WidgetSnapshot,
                             now: Date) -> PrayerWindowAttributes.ContentState {
        PrayerWindowAttributes.ContentState(
            prayedCount: snapshot.circle.prayedCount,
            memberCount: snapshot.circle.memberCount,
            youLogged: snapshot.you.logged,
            faces: snapshot.circle.posts.prefix(PrayerWindowAttributes.faceCap).map {
                PrayerWindowAttributes.Face(name: $0.name, emoji: $0.emoji, tier: $0.tier)
            },
            updatedAt: now.timeIntervalSince1970)
    }

    /// Whether an activity should be on screen at this instant.
    ///
    /// **Only while the window is OPEN.** The file deliberately names the NEXT
    /// window when nothing is open (`WidgetSnapshotBuilder.window` — the tile
    /// still has to say "Dhuhr, opens 1:00 PM"), and a Live Activity for a
    /// prayer whose time has not come in is a countdown to nothing on somebody's
    /// Lock Screen for six hours. `endsAt` closes it from the other side, which
    /// is §6's "ending itself when the window closes".
    static func shouldRun(snapshot: WidgetSnapshot?, now: Date) -> Bool {
        guard let window = snapshot?.window else { return false }
        return now >= window.opensAt && now < window.endsAt
    }

    /// Whether two activities are about the same window. Attributes are an
    /// activity's IDENTITY — they cannot be updated — so this is what decides
    /// between `.update` and `.restart`.
    static func isSameWindow(_ left: PrayerWindowAttributes,
                             _ right: PrayerWindowAttributes) -> Bool {
        left.prayerRaw == right.prayerRaw && left.dayKey == right.dayKey
    }

    /// The whole state machine, in one pure function.
    ///
    /// - Parameters:
    ///   - snapshot: what the app just wrote (or would write) to
    ///     `widget.json`. nil is a phone with no file yet.
    ///   - running: the activity currently on screen, if any.
    ///   - now: `AppClock.now`. Time travel therefore moves the Lock Screen
    ///     exactly as it moves everything else — which is the point of the
    ///     house rule, and the reason this takes an instant rather than reading
    ///     one.
    static func plan(snapshot: WidgetSnapshot?,
                     running: Running?,
                     now: Date) -> Plan {
        guard let snapshot, LiveActivityPlanner.shouldRun(snapshot: snapshot, now: now),
              let wanted: PrayerWindowAttributes = attributes(for: snapshot) else {
            // Nothing should be running. Ending an activity that is not there
            // is not free (it is an await into ActivityKit), so say so.
            return running == nil ? .none : .end
        }
        let state: PrayerWindowAttributes.ContentState = contentState(for: snapshot, now: now)
        guard let running else { return .start(wanted, state) }
        guard LiveActivityPlanner.isSameWindow(running.attributes, wanted) else {
            return .restart(wanted, state)
        }
        // `updatedAt` moves on every publish and nothing renders it as a
        // difference, so it is excluded from the comparison — otherwise every
        // tasbih tap would be an ActivityKit update, and updates are the thing
        // iOS rations when it decides an app is being noisy.
        var comparable: PrayerWindowAttributes.ContentState = running.state
        comparable.updatedAt = state.updatedAt
        return comparable == state ? .none : .update(state)
    }
}
