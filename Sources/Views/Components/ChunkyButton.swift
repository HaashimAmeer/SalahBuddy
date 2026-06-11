import SwiftUI

// Owned by the components agent.
// Duolingo-style 3D button: filled rounded rect riding on a darker bottom
// edge; the top face depresses onto the edge while pressed; haptic on tap.
struct ChunkyButton: View {
    let title: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(Theme.rounded(18, .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChunkyPressStyle(
            color: isEnabled ? color : Theme.inkSoft.opacity(0.65),
            isEnabled: isEnabled))
        .disabled(!isEnabled)
    }
}

private struct ChunkyPressStyle: ButtonStyle {
    let color: Color
    let isEnabled: Bool

    private let depth: CGFloat = 4
    private let cornerRadius: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let depress: CGFloat = pressed ? depth - 1 : 0
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return ZStack {
            // Darker bottom edge — the "3D" base the face sits on.
            shape
                .fill(color)
                .overlay(shape.fill(Color.black.opacity(0.3)))
                .offset(y: depth)

            // Top face + label depress together.
            ZStack {
                shape.fill(color)
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.14), .clear],
                    startPoint: .top, endPoint: .center))
                configuration.label
            }
            .offset(y: depress)
        }
        .padding(.bottom, depth)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .opacity(isEnabled ? 1 : 0.9)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        ChunkyButton(title: "I prayed 🤲", color: Theme.green, isEnabled: true) {}
        ChunkyButton(title: "Make up (Qada) +5 XP", color: Theme.sky, isEnabled: true) {}
        ChunkyButton(title: "Not yet", color: Theme.green, isEnabled: false) {}
    }
    .padding(24)
    .background(Theme.cream)
}
#endif
