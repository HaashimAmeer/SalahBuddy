import SwiftUI

// Owned by the components agent.
/// v2 soft-chunky flat button: filled capsule, generous padding, subtle
/// pressed scale (0.97) + darker tint. The v1 3D bottom edge is gone —
/// "flatter, friendlier". Signature unchanged; haptic on tap kept.
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
                .font(Theme.sans(17, .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Capsule())
        }
        .buttonStyle(SoftChunkyStyle(
            color: isEnabled ? color : Theme.inkMuted.opacity(0.55),
            isEnabled: isEnabled))
        .disabled(!isEnabled)
    }
}

private struct SoftChunkyStyle: ButtonStyle {
    let color: Color
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .background(
                Capsule()
                    .fill(color)
                    // Darker tint while pressed (instead of a 3D depress).
                    .overlay(Capsule().fill(Color.black.opacity(pressed ? 0.16 : 0)))
                    .shadow(color: .black.opacity(isEnabled ? 0.05 : 0),
                            radius: 10, x: 0, y: 2)
            )
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .opacity(isEnabled ? 1 : 0.9)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        ChunkyButton(title: "I prayed 🤲", color: Theme.green, isEnabled: true) {}
        ChunkyButton(title: "Make up (Qada) +10 XP", color: Theme.qadaBlue, isEnabled: true) {}
        ChunkyButton(title: "Not yet", color: Theme.green, isEnabled: false) {}
    }
    .padding(24)
    .background(Theme.bg)
}
#endif
