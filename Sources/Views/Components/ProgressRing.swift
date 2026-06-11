import SwiftUI

// Owned by the components agent.
/// Rounded-cap progress ring with a soft track. Springs to new values.
/// Strokes are inset so the ring stays inside its frame.
struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let color: Color

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.75), color]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * clamped)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(clamped >= 1 ? 0.5 : 0), radius: 4)
                .animation(Theme.spring, value: clamped)
        }
        .padding(lineWidth / 2)
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 24) {
        ProgressRing(progress: 0.3, lineWidth: 10, color: Theme.green)
            .frame(width: 80, height: 80)
        ProgressRing(progress: 0.75, lineWidth: 10, color: Theme.gold)
            .frame(width: 80, height: 80)
        ProgressRing(progress: 1.0, lineWidth: 10, color: Theme.green)
            .frame(width: 80, height: 80)
    }
    .padding()
    .background(Theme.cream)
}
#endif
