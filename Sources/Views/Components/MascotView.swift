import SwiftUI

// Owned by the components agent.
// "Hilal" — SalahBuddy's crescent-moon mascot, drawn entirely with SwiftUI
// shapes (no image assets). Each mood gets distinct face + motion:
//   celebrating — bounces with sparkles, big open smile
//   happy       — warm smile, gentle breathing
//   neutral     — calm face
//   sleepy      — closed eyes, tilt, floating zzz
//   worried     — raised brows, frown, sweat drop, tiny tremble

enum MascotMood { case celebrating, happy, neutral, sleepy, worried }

struct MascotView: View {
    let mood: MascotMood
    let size: CGFloat

    var body: some View {
        // TimelineView only drives redraws; the animation phase itself is read
        // from AppClock.now so the app has a single time source.
        TimelineView(.animation) { _ in
            HilalFigure(mood: mood, size: size,
                        t: AppClock.now.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Figure

private struct HilalFigure: View {
    let mood: MascotMood
    let size: CGFloat
    let t: TimeInterval

    var body: some View {
        let bouncePhase = abs(sin(t * 7))
        let bounce: CGFloat = mood == .celebrating ? bouncePhase * size * 0.07 : 0
        let squash: CGFloat = mood == .celebrating ? (1 - bouncePhase) * 0.06 : 0
        let breathe: CGFloat = 1 + (mood == .sleepy ? sin(t * 1.5) * 0.02 : sin(t * 2.2) * 0.012)
        let tilt: Double = {
            switch mood {
            case .sleepy:  return -8 + sin(t * 1.5) * 1.5
            case .worried: return sin(t * 18) * 1.4
            default:       return 0
            }
        }()

        ZStack {
            orbitingStar

            if mood == .celebrating { sparkles }

            ZStack {
                crescentBody
                face
            }
            .scaleEffect(x: (1 + squash) * breathe, y: (1 - squash) * breathe, anchor: .bottom)
            .rotationEffect(.degrees(tilt))
            .offset(y: -bounce)

            if mood == .sleepy { zzz }
            if mood == .worried { sweatDrop }
        }
        .frame(width: size, height: size)
    }

    // MARK: Body

    private var crescentBody: some View {
        ZStack {
            CrescentShape()
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFDD7A), Theme.gold],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            CrescentShape()
                .stroke(Color(hex: 0xE09E12).opacity(0.55), lineWidth: max(1.5, size * 0.018))
        }
        .frame(width: size * 0.92, height: size * 0.92)
        .shadow(color: Theme.gold.opacity(0.35), radius: size * 0.06, y: size * 0.03)
        .position(p(0.5, 0.52))
    }

    // MARK: Face

    private var face: some View {
        ZStack {
            eyes
            if mood == .worried { brows }
            mouth
            blush
        }
    }

    @ViewBuilder private var eyes: some View {
        let leftEye = p(0.33, 0.45)
        let rightEye = p(0.56, 0.48)
        switch mood {
        case .celebrating:
            // happy-closed ^ ^ eyes
            closedArc(up: true).position(leftEye)
            closedArc(up: true).position(rightEye)
        case .sleepy:
            // restful closed eyes (downward curve)
            closedArc(up: false).position(leftEye)
            closedArc(up: false).position(rightEye)
        case .worried:
            openEye(scale: 1.18).position(leftEye)
            openEye(scale: 1.18).position(rightEye)
        default:
            openEye(scale: 1).position(leftEye)
            openEye(scale: 1).position(rightEye)
        }
    }

    private func openEye(scale: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Theme.ink)
                .frame(width: size * 0.095 * scale, height: size * 0.125 * scale)
            Circle()
                .fill(.white)
                .frame(width: size * 0.034, height: size * 0.034)
                .offset(x: -size * 0.016, y: -size * 0.028)
        }
    }

    private func closedArc(up: Bool) -> some View {
        ArcShape(startDegrees: up ? 200 : 20, endDegrees: up ? 340 : 160)
            .stroke(Theme.ink, style: StrokeStyle(lineWidth: size * 0.028, lineCap: .round))
            .frame(width: size * 0.11, height: size * 0.09)
    }

    private var brows: some View {
        let lift = sin(t * 6) * size * 0.006
        return ZStack {
            Capsule().fill(Theme.ink)
                .frame(width: size * 0.11, height: size * 0.022)
                .rotationEffect(.degrees(14))
                .position(p(0.32, 0.34))
                .offset(y: -lift)
            Capsule().fill(Theme.ink)
                .frame(width: size * 0.11, height: size * 0.022)
                .rotationEffect(.degrees(-14))
                .position(p(0.57, 0.37))
                .offset(y: -lift)
        }
    }

    @ViewBuilder private var mouth: some View {
        let mouthPoint = p(0.45, 0.63)
        switch mood {
        case .celebrating:
            // big open joyful mouth with tongue
            ZStack {
                Ellipse().fill(Color(hex: 0x6B3B2A))
                    .frame(width: size * 0.16, height: size * 0.17)
                Ellipse().fill(Color(hex: 0xF7918B))
                    .frame(width: size * 0.12, height: size * 0.09)
                    .offset(y: size * 0.05)
            }
            .clipShape(Ellipse())
            .frame(width: size * 0.16, height: size * 0.17)
            .position(mouthPoint)
        case .happy:
            ArcShape(startDegrees: 25, endDegrees: 155)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                .frame(width: size * 0.17, height: size * 0.13)
                .position(mouthPoint)
        case .neutral:
            Capsule().fill(Theme.ink)
                .frame(width: size * 0.08, height: size * 0.024)
                .position(mouthPoint)
        case .sleepy:
            // tiny relaxed "o"
            Ellipse().fill(Theme.ink.opacity(0.85))
                .frame(width: size * 0.05, height: size * 0.055)
                .position(mouthPoint)
        case .worried:
            ArcShape(startDegrees: 205, endDegrees: 335)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: size * 0.028, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.1)
                .position(p(0.45, 0.65))
        }
    }

    private var blush: some View {
        let blushColor = Color(hex: 0xF7A6A0).opacity(mood == .worried ? 0.3 : 0.55)
        return ZStack {
            Ellipse().fill(blushColor)
                .frame(width: size * 0.1, height: size * 0.055)
                .position(p(0.24, 0.57))
            Ellipse().fill(blushColor)
                .frame(width: size * 0.1, height: size * 0.055)
                .position(p(0.65, 0.6))
        }
    }

    // MARK: Accents

    private var orbitingStar: some View {
        let speed: Double = mood == .celebrating ? 2.6 : 0.85
        let angle = t * speed
        let rx = size * 0.44
        let ry = size * 0.32
        return StarShape()
            .fill(LinearGradient(colors: [Color(hex: 0xFFE49B), Theme.gold],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size * 0.13, height: size * 0.13)
            .scaleEffect(1 + 0.16 * sin(t * 4))
            .rotationEffect(.degrees(t * 40))
            .position(x: size / 2 + cos(angle) * rx,
                      y: size / 2 + sin(angle) * ry)
            .opacity(0.95)
    }

    private var sparkles: some View {
        ForEach(0..<6, id: \.self) { i in
            let phase = t * 3.2 + Double(i) * .pi / 3
            let angleDeg = Double(i) * 60.0 + 15.0
            let r = size * (0.46 + 0.04 * sin(phase))
            StarShape()
                .fill(i.isMultiple(of: 2) ? Theme.gold : Theme.coral)
                .frame(width: size * 0.09, height: size * 0.09)
                .scaleEffect(0.55 + 0.5 * abs(sin(phase)))
                .opacity(0.45 + 0.55 * abs(sin(phase)))
                .rotationEffect(.degrees(phase * 30))
                .position(x: size / 2 + cos(angleDeg * .pi / 180) * r,
                          y: size / 2 + sin(angleDeg * .pi / 180) * r)
        }
    }

    private var zzz: some View {
        ForEach(0..<3, id: \.self) { i in
            let cycle = fmod(t * 0.45 + Double(i) * 0.33, 1.0)
            Text("z")
                .font(Theme.sans(size * (0.1 + 0.04 * CGFloat(i)), .heavy))
                .foregroundStyle(Theme.inkSoft)
                .opacity(1 - cycle)
                .position(p(0.8 + 0.05 * CGFloat(i), 0.28))
                .offset(x: CGFloat(sin(cycle * .pi * 2)) * size * 0.02,
                        y: -CGFloat(cycle) * size * 0.2)
        }
    }

    private var sweatDrop: some View {
        DropShape()
            .fill(LinearGradient(colors: [Color(hex: 0x9ED4F2), Theme.sky],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size * 0.085, height: size * 0.13)
            .rotationEffect(.degrees(10))
            .position(p(0.8, 0.3))
            .offset(y: CGFloat(abs(sin(t * 2.4))) * size * 0.03)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size, y: y * size)
    }
}

// MARK: - Shapes (private to avoid cross-file name collisions)

private struct CrescentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let disk = Path(ellipseIn: rect)
        let w = rect.width
        // A shallow bite at the upper-right keeps Hilal chunky and friendly
        // while still reading clearly as a crescent.
        let bite = Path(ellipseIn: CGRect(
            x: rect.minX + w * 0.55,
            y: rect.minY - w * 0.25,
            width: w * 0.62,
            height: w * 0.62))
        return disk.subtracting(bite)
    }
}

private struct ArcShape: Shape {
    let startDegrees: Double
    let endDegrees: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                 radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(startDegrees),
                 endAngle: .degrees(endDegrees),
                 clockwise: false)
        return p
    }
}

private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        var path = Path()
        for i in 0..<10 {
            let angle = Double(i) * .pi / 5 - .pi / 2
            let r = i.isMultiple(of: 2) ? outer : inner
            let pt = CGPoint(x: c.x + CGFloat(cos(angle)) * r,
                             y: c.y + CGFloat(sin(angle)) * r)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

private struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.maxX + rect.width * 0.35, y: rect.maxY * 0.78))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX - rect.width * 0.35, y: rect.maxY * 0.78))
        return p
    }
}

#if DEBUG
#Preview("Moods") {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            MascotView(mood: .celebrating, size: 110)
            MascotView(mood: .happy, size: 110)
        }
        HStack(spacing: 24) {
            MascotView(mood: .neutral, size: 110)
            MascotView(mood: .sleepy, size: 110)
            MascotView(mood: .worried, size: 110)
        }
    }
    .padding()
    .background(Theme.cream)
}
#endif
