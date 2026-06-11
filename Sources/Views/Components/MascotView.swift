import SwiftUI

// PLACEHOLDER — owned by the components agent, which will replace this file.
// Signatures are the cross-agent contract; do not change them.

enum MascotMood { case celebrating, happy, neutral, sleepy, worried }

struct MascotView: View {
    let mood: MascotMood
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.gold.opacity(0.3))
            Text("🌙")
                .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
    }
}
