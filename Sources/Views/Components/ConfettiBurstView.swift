import SwiftUI

// Owned by the components agent.
/// Replays a confetti burst whenever `trigger` increments.
/// Particles are generated with a seeded RNG (stable per burst) and animated
/// with simple ballistic physics in a Canvas. Non-interactive overlay.
struct ConfettiBurstView: View {
    let trigger: Int

    @State private var burst: ConfettiBurst?

    var body: some View {
        ZStack {
            if let burst {
                ConfettiCanvas(burst: burst)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, newValue in
            let newBurst = ConfettiBurst(
                seed: UInt64(bitPattern: Int64(newValue)),
                start: AppClock.now)
            burst = newBurst
            // Tear the canvas down once the burst has fully played out.
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if burst?.id == newBurst.id { burst = nil }
            }
        }
    }
}

// MARK: - Burst model

private struct ConfettiBurst: Equatable {
    let id = UUID()
    let seed: UInt64
    let start: Date

    static func == (lhs: ConfettiBurst, rhs: ConfettiBurst) -> Bool {
        lhs.id == rhs.id
    }
}

private enum ConfettiKind: CaseIterable {
    case rect, circle, triangle
}

private struct ConfettiParticle {
    let vx: Double
    let vy: Double
    let delay: Double
    let life: Double
    let size: Double
    let spin: Double
    let initialRotation: Double
    let color: Color
    let kind: ConfettiKind

    init(rng: inout ConfettiRNG) {
        // Mostly-upward fan; gravity pulls everything back down.
        let angle = -Double.pi / 2 + Double.random(in: -1.15...1.15, using: &rng)
        let speed = Double.random(in: 260...720, using: &rng)
        vx = cos(angle) * speed
        vy = sin(angle) * speed
        delay = Double.random(in: 0...0.08, using: &rng)
        life = Double.random(in: 1.2...2.2, using: &rng)
        size = Double.random(in: 6...12, using: &rng)
        spin = Double.random(in: -9...9, using: &rng)
        initialRotation = Double.random(in: 0...(2 * .pi), using: &rng)
        let palette: [Color] = [Theme.green, Theme.gold, Theme.coral, Theme.sky, Theme.lilac]
        color = palette[Int.random(in: 0..<palette.count, using: &rng)]
        kind = ConfettiKind.allCases[Int.random(in: 0..<ConfettiKind.allCases.count, using: &rng)]
    }
}

// MARK: - Canvas

private struct ConfettiCanvas: View {
    let burst: ConfettiBurst
    private let particles: [ConfettiParticle]

    private static let gravity: Double = 760
    private static let duration: Double = 2.6

    init(burst: ConfettiBurst) {
        self.burst = burst
        var rng = ConfettiRNG(seed: burst.seed &+ 0x9E3779B97F4A7C15)
        self.particles = (0..<90).map { _ in ConfettiParticle(rng: &rng) }
    }

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, canvasSize in
                let t = AppClock.now.timeIntervalSince(burst.start)
                guard t >= 0, t < Self.duration else { return }
                let origin = CGPoint(x: canvasSize.width / 2,
                                     y: canvasSize.height * 0.42)

                for p in particles {
                    let pt = t - p.delay
                    guard pt > 0 else { continue }
                    let fade = max(0, min(1, (p.life - pt) / 0.45))
                    guard fade > 0 else { continue }

                    let x = origin.x + CGFloat(p.vx * pt)
                    let y = origin.y + CGFloat(p.vy * pt + 0.5 * Self.gravity * pt * pt)
                    // Cheap "tumble" — width oscillates like a flipping paper square.
                    let tumble = 0.35 + 0.65 * abs(sin(pt * 7 + p.initialRotation))

                    var layer = context
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(p.spin * pt + p.initialRotation))
                    layer.opacity = fade

                    let s = CGFloat(p.size)
                    switch p.kind {
                    case .rect:
                        let rect = CGRect(x: -s / 2, y: -s * 0.3 * tumble,
                                          width: s, height: s * 0.6 * tumble)
                        layer.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                   with: .color(p.color))
                    case .circle:
                        let rect = CGRect(x: -s / 2, y: -s / 2 * tumble,
                                          width: s, height: s * tumble)
                        layer.fill(Path(ellipseIn: rect), with: .color(p.color))
                    case .triangle:
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: -s / 2))
                        path.addLine(to: CGPoint(x: s / 2, y: s / 2))
                        path.addLine(to: CGPoint(x: -s / 2, y: s / 2))
                        path.closeSubpath()
                        layer.fill(path, with: .color(p.color))
                    }
                }
            }
        }
    }
}

// MARK: - Seeded RNG (SplitMix64 — stable particle field per burst)

private struct ConfettiRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4B9F9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
