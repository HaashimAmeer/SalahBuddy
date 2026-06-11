import SwiftUI

// Owned by the components agent.
/// Deterministic cozy prayer-space illustration — a buddy's "photo".
/// Every visual choice (wall tone, mat shape, rug pattern, window / lamp /
/// plant accents) is drawn from a SplitMix64 seeded with `seed`, so the same
/// seed always renders the identical scene. Pure SwiftUI shapes, §2 palette.
struct IllustratedPrayerCard: View {
    let seed: UInt64

    private let design: SceneDesign

    init(seed: UInt64) {
        self.seed = seed
        self.design = SceneDesign(seed: seed)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Wall.
                design.wall

                // Floor band.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(design.floor)
                        .frame(height: h * 0.30)
                }

                // Window with crescent — upper area.
                if design.hasWindow {
                    windowView(w: w, h: h)
                        .position(x: w * design.windowX, y: h * 0.27)
                }

                // Hanging lamp accent.
                if design.hasLamp {
                    lampView(w: w, h: h)
                        .position(x: w * design.lampX, y: h * 0.30)
                }

                // Plant accent.
                if design.hasPlant {
                    plantView(w: w, h: h)
                        .position(x: w * design.plantX, y: h * 0.62)
                }

                // Prayer mat — the centerpiece, sitting on the floor.
                matView(w: w, h: h)
                    .position(x: w * 0.5, y: h * 0.72)
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    // MARK: - Pieces

    private func windowView(w: CGFloat, h: CGFloat) -> some View {
        let winW = w * 0.30
        let winH = h * 0.34
        return ZStack {
            ArchShape().fill(design.sky)
            ArchShape().stroke(design.frameColor, lineWidth: max(2, w * 0.012))

            // Crescent moon: gold circle with a sky-colored bite.
            ZStack {
                Circle()
                    .fill(Theme.gold)
                    .frame(width: winW * 0.34, height: winW * 0.34)
                Circle()
                    .fill(design.sky)
                    .frame(width: winW * 0.30, height: winW * 0.30)
                    .offset(x: winW * 0.10, y: -winW * 0.06)
            }
            .offset(x: -winW * 0.12, y: -winH * 0.10)

            if design.hasStars {
                Image(systemName: "sparkle")
                    .font(.system(size: winW * 0.14, weight: .bold))
                    .foregroundStyle(Theme.gold.opacity(0.9))
                    .offset(x: winW * 0.22, y: winH * 0.04)
            }
        }
        .frame(width: winW, height: winH)
        .clipShape(ArchShape())
        .overlay(ArchShape().stroke(design.frameColor, lineWidth: max(2, w * 0.012)))
        .frame(width: winW, height: winH)
    }

    private func lampView(w: CGFloat, h: CGFloat) -> some View {
        let lw = w * 0.10
        return VStack(spacing: 0) {
            Rectangle()
                .fill(design.frameColor)
                .frame(width: max(1.5, lw * 0.08), height: h * 0.12)
            Circle()
                .fill(Theme.gold.opacity(0.9))
                .frame(width: lw, height: lw)
                .overlay(Circle().stroke(design.frameColor, lineWidth: max(1, lw * 0.07)))
                .shadow(color: Theme.gold.opacity(0.55), radius: lw * 0.45)
            Triangle()
                .fill(design.frameColor)
                .frame(width: lw * 0.5, height: lw * 0.35)
                .rotationEffect(.degrees(180))
        }
    }

    private func plantView(w: CGFloat, h: CGFloat) -> some View {
        let pw = w * 0.16
        return VStack(spacing: -pw * 0.08) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Ellipse()
                        .fill(design.leaf.opacity(0.8 + Double(i) * 0.07))
                        .frame(width: pw * 0.34, height: pw * 0.85)
                        .rotationEffect(.degrees(Double(i - 1) * 34))
                }
            }
            UnevenRoundedRectangle(
                topLeadingRadius: pw * 0.05, bottomLeadingRadius: pw * 0.16,
                bottomTrailingRadius: pw * 0.16, topTrailingRadius: pw * 0.05)
                .fill(design.pot)
                .frame(width: pw * 0.55, height: pw * 0.42)
        }
    }

    private func matView(w: CGFloat, h: CGFloat) -> some View {
        let mw = w * 0.46
        let mh = h * 0.44
        return ZStack {
            // Mat body — arch-topped or rounded-rect variant.
            matShape.fill(design.matColor)
            matShape.stroke(design.matBorder, lineWidth: max(2, w * 0.014))

            // Rug pattern variant.
            Group {
                switch design.rugPattern {
                case 0:   // inner arch (mihrab niche)
                    ArchShape()
                        .stroke(design.matBorder.opacity(0.8),
                                lineWidth: max(1.5, w * 0.009))
                        .frame(width: mw * 0.68, height: mh * 0.68)
                        .offset(y: mh * 0.02)
                case 1:   // horizontal stripes
                    VStack(spacing: mh * 0.10) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(design.matBorder.opacity(0.55))
                                .frame(width: mw * 0.56, height: max(2, mh * 0.045))
                        }
                    }
                    .offset(y: mh * 0.08)
                default:  // diamond medallion
                    Rectangle()
                        .fill(design.matBorder.opacity(0.55))
                        .frame(width: mw * 0.24, height: mw * 0.24)
                        .rotationEffect(.degrees(45))
                        .offset(y: mh * 0.05)
                }
            }

            // Small crescent at the top of the mat.
            Image(systemName: "moon.stars.fill")
                .font(.system(size: mw * 0.13, weight: .semibold))
                .foregroundStyle(design.matBorder.opacity(0.9))
                .offset(y: -mh * 0.28)
        }
        .frame(width: mw, height: mh)
        .rotation3DEffect(.degrees(26), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
    }

    private var matShape: AnyShape {
        design.matIsArch
            ? AnyShape(ArchShape())
            : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Seeded design parameters

private struct SceneDesign {
    let wall: Color
    let floor: Color
    let sky: Color
    let frameColor: Color
    let leaf: Color
    let pot: Color
    let matColor: Color
    let matBorder: Color
    let matIsArch: Bool
    let rugPattern: Int
    let hasWindow: Bool
    let hasLamp: Bool
    let hasPlant: Bool
    let hasStars: Bool
    let windowX: CGFloat
    let lampX: CGFloat
    let plantX: CGFloat

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)

        // §2-palette variants, drawn deterministically in fixed order.
        let walls: [Color] = [
            Color(hex: 0xECF6EE), Color(hex: 0xE3F0E7),
            Color(hex: 0xF2EFE6), Color(hex: 0xEAF2F6),
        ]
        let floors: [Color] = [
            Color(hex: 0xD8E8DC), Color(hex: 0xCDEBD8),
            Color(hex: 0xE0DCCB), Color(hex: 0xD5E3EA),
        ]
        let mats: [(body: Color, border: Color)] = [
            (Color(hex: 0x2BAE66), Color(hex: 0x16382A)),   // green / dark green
            (Color(hex: 0x5B8DEF), Color(hex: 0x2B4A8F)),   // qada blue
            (Color(hex: 0xA98BDB), Color(hex: 0x5E4490)),   // lilac
            (Color(hex: 0xF2A65A), Color(hex: 0x9A5F22)),   // amber
        ]

        wall = walls[Int(rng.next() % UInt64(walls.count))]
        floor = floors[Int(rng.next() % UInt64(floors.count))]
        let mat = mats[Int(rng.next() % UInt64(mats.count))]
        matColor = mat.body
        matBorder = mat.border
        matIsArch = rng.uniform() < 0.6
        rugPattern = Int(rng.next() % 3)

        sky = Color(hex: 0x16382A).opacity(0.85)
        frameColor = Color(hex: 0x5F7A6C)
        leaf = Color(hex: 0x2BAE66)
        pot = Color(hex: 0xF2A65A)

        hasWindow = rng.uniform() < 0.8
        hasLamp = rng.uniform() < 0.55
        hasPlant = rng.uniform() < 0.6
        hasStars = rng.uniform() < 0.5

        windowX = rng.uniform() < 0.5 ? 0.26 : 0.72
        lampX = windowX < 0.5 ? 0.80 : 0.20
        plantX = rng.uniform() < 0.5 ? 0.13 : 0.87
    }
}

// MARK: - Shapes

/// Mihrab-style arch: rounded dome top, straight sides and bottom.
private struct ArchShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        var p = Path()
        let domeHeight = min(rect.height * 0.45, rect.width * 0.6)
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + domeHeight))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + domeHeight),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

#if DEBUG
#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach([7, 42, 99, 1234] as [UInt64], id: \.self) { s in
            IllustratedPrayerCard(seed: s)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
    .padding()
    .background(Theme.bg)
}
#endif
