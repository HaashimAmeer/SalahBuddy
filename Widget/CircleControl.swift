import AppIntents
import SwiftUI
import WidgetKit

/// v5 §3/§4 (P4) — "Nudge the circle", in Control Center.
///
/// The last row of §3's family table, and the smallest surface in the app: one
/// glyph, one label, one tap. No availability gate anywhere in this file —
/// §9-04 raised the floor to iOS 18 precisely so `ControlWidget` and ActivityKit
/// could be written plainly.
///
/// **§2 tooth #3 lives in the INTENT here, not in the template.** The extension
/// holds a session it may never refresh, so a control that could only nudge
/// would silently do nothing for anybody whose token has expired. The medium
/// tile answers that by rendering a `Link` instead of a `Button`; a control
/// cannot, because `ControlWidgetTemplateBuilder` takes no branches — one
/// control is one button, whatever the state, and the branch will not compile.
/// So it moved inside `NudgeCircleIntent`, which throws copy the system shows
/// (see the three doors its comment walks through). This provider's job is to
/// say so on the LABEL first, so the tap is never a surprise: the button
/// already reads "Sign in to nudge" before anybody touches it.
struct NudgeCircleControl: ControlWidget {

    static let kind: String = "org.amacvoters.salahbuddymock.control.nudge"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: NudgeCircleControl.kind,
                                   provider: NudgeControlProvider()) { value in
            ControlWidgetButton(action: NudgeCircleIntent()) {
                Label(value.label, systemImage: value.canNudge ? "hand.wave.fill"
                                                               : "hand.wave")
            }
        }
        .displayName("Nudge the circle")
        .description("Remind whoever hasn't prayed this window yet.")
    }
}

/// What the control needs to know, which is deliberately almost nothing.
struct NudgeControlValue {
    /// A usable session AND somebody to nudge. Both, because a control that
    /// offers to nudge an empty list is as broken as one that cannot
    /// authenticate.
    let canNudge: Bool
    let label: String
}

struct NudgeControlProvider: ControlValueProvider {

    /// What the gallery shows while somebody is deciding whether to add this.
    /// Never a read of anybody's real circle — the same rule
    /// `WidgetSnapshot.placeholder` follows.
    var previewValue: NudgeControlValue {
        NudgeControlValue(canNudge: true, label: "Nudge the circle")
    }

    func currentValue() async throws -> NudgeControlValue {
        let snapshot: WidgetSnapshot? = WidgetFile.read()
        let waiting: [WidgetSnapshot.Waiting] = snapshot?.circle.waiting ?? []
        let outstanding: [WidgetSnapshot.Waiting] = waiting.filter { !$0.nudgedThisWindow }
        // NEVER refreshed, only read (§2 tooth #3) — and demo needs no session
        // at all, which is the same call `CircleWidgetModel.canNudge` makes.
        let route: NudgeRoute = NudgeRoute.decide(
            mode: snapshot?.mode ?? NudgeRoute.modeWithoutAFile,
            token: SharedSession.load(), at: Date())

        guard route.canSend else {
            // The tap still does something — `NudgeCircleIntent` asks to
            // continue in the foreground — so the label says where it goes.
            return NudgeControlValue(canNudge: false, label: "Sign in to nudge")
        }
        guard !outstanding.isEmpty else {
            // `waiting` is the nudge list, so an empty one is either "nobody is
            // late yet" (the window has not been open thirty minutes) or
            // "everybody has been nudged". Both are honest as the same word,
            // and neither is a reason to send anything.
            return NudgeControlValue(canNudge: false,
                                     label: waiting.isEmpty ? "Nothing to nudge"
                                                            : "Nudged ✓")
        }
        return NudgeControlValue(
            canNudge: true,
            label: outstanding.count == 1 ? "Nudge \(outstanding[0].name)"
                                          : "Nudge \(outstanding.count) friends")
    }
}
