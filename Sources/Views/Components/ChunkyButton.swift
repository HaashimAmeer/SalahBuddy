import SwiftUI

// PLACEHOLDER — owned by the components agent, which will replace this file.
struct ChunkyButton: View {
    let title: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(18))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isEnabled ? color : Theme.inkSoft)
                )
        }
        .disabled(!isEnabled)
    }
}
