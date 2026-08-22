import SwiftUI

/// A two-or-more-way choice that actually looks chosen.
///
/// Replaces `.pickerStyle(.segmented)`, which renders a `UISegmentedControl`
/// whose selected-segment tint does not follow SwiftUI's theming. On this
/// app's mint background that produced grey text on a grey pill against a grey
/// track — three tones of the same colour, and no way to tell at a glance
/// which side was active. The Asr madhab control shipped like that.
///
/// Selection here is carried by fill and weight, not a hairline of contrast:
/// the active segment is a solid `Theme.green` pill with white bold text. The
/// pill slides between segments via `matchedGeometryEffect`, so the change
/// reads as one object moving rather than two crossfading.
struct SegmentedChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }

        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    let options: [Option]
    @Binding var selection: Value

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(Theme.bg, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Theme.mist.opacity(0.45), lineWidth: 1))
    }

    private func segment(_ option: Option) -> some View {
        let isOn = selection == option.value
        return Button {
            guard !isOn else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Theme.spring) { selection = option.value }
        } label: {
            Text(option.label)
                .font(Theme.sans(14, isOn ? .bold : .semibold))
                .foregroundStyle(isOn ? Color.white : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if isOn {
                        Capsule(style: .continuous)
                            .fill(Theme.green)
                            .matchedGeometryEffect(id: "segmented.pill", in: pill)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
