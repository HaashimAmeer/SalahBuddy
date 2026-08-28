import UIKit

/// Local photo persistence for prayer posts. JPEGs live in
/// Documents/photos/; logs reference them by bare filename.
/// Saves downscale to max 1200px on the long edge (JPEG 0.7) so grids never
/// need to hold huge images.
enum PhotoStore {

    static let maxDimension: CGFloat = 1200
    static let jpegQuality: CGFloat = 0.7

    static var directory: URL {
        let dir = Store.directory.appendingPathComponent("photos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Downscale + save a captured photo. Returns the stored filename, or ""
    /// if the write failed (caller should treat "" as nil — the log must
    /// still record without a photo rather than losing the prayer).
    static func save(_ image: UIImage, dayKey: String, prayer: Prayer) -> String {
        let filename = "\(dayKey)_\(prayer.rawValue)_\(UUID().uuidString.prefix(8)).jpg"
        guard write(image, filename: filename) else { return "" }
        return filename
    }

    static func load(_ filename: String) -> UIImage? {
        guard !filename.isEmpty,
              let data = try? Data(contentsOf: url(for: filename)) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ filename: String) {
        guard !filename.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    /// v4.1: the other half of `save` — take a JPEG back off the disk unless
    /// some log still points at it.
    ///
    /// It sits next to `save` so the two are read together, because the
    /// failure it exists to prevent is a caller that wrote a photo and then
    /// found out the log would not have it. The decision itself is
    /// `GameEngine.isPhotoOrphaned` and belongs there; this is only the file
    /// operation that follows from it.
    static func deleteIfOrphaned(_ filename: String?, in logs: [PrayerLog]) {
        guard let filename, GameEngine.isPhotoOrphaned(filename, in: logs) else { return }
        delete(filename)
    }

    /// Deletes the whole photos directory (reset-all-data path).
    static func deleteAll() {
        try? FileManager.default.removeItem(at: Store.directory.appendingPathComponent("photos", isDirectory: true))
    }

    // MARK: - Demo images

    /// Deterministic gradient/pattern card — used for DEBUG demo data and as
    /// the sim-camera fallback ("Use a demo photo").
    static func demoImage(seed: UInt64) -> UIImage {
        var rng = SplitMix64(seed: seed)
        let size = CGSize(width: 600, height: 600)

        // Soft, friendly palette — hues drawn deterministically.
        let hueA = CGFloat(rng.uniform())
        let hueB = CGFloat(rng.uniform())
        let colorA = UIColor(hue: hueA, saturation: 0.35, brightness: 0.95, alpha: 1)
        let colorB = UIColor(hue: hueB, saturation: 0.45, brightness: 0.80, alpha: 1)
        let patternKind = Int(rng.next() % 3)
        let dotCount = 6 + Int(rng.next() % 10)
        let dotSeedValues: [(x: Double, y: Double, r: Double)] = (0..<dotCount).map { _ in
            (rng.uniform(), rng.uniform(), rng.uniform())
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            // Gradient background.
            let colors = [colorA.cgColor, colorB.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: .zero,
                                      end: CGPoint(x: size.width, y: size.height),
                                      options: [])
            }
            // Deterministic pattern overlay.
            cg.setFillColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            for dot in dotSeedValues {
                let radius = 12 + dot.r * 50
                let rect = CGRect(x: dot.x * Double(size.width) - radius,
                                  y: dot.y * Double(size.height) - radius,
                                  width: radius * 2, height: radius * 2)
                switch patternKind {
                case 0: cg.fillEllipse(in: rect)
                case 1: cg.fill(rect.insetBy(dx: radius * 0.4, dy: 0))
                default:
                    cg.beginPath()
                    cg.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    cg.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    cg.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    cg.closePath()
                    cg.fillPath()
                }
            }
            // Subtle crescent accent.
            cg.setFillColor(UIColor.white.withAlphaComponent(0.30).cgColor)
            let crescentRect = CGRect(x: size.width * 0.62, y: size.height * 0.12,
                                      width: 110, height: 110)
            cg.fillEllipse(in: crescentRect)
            cg.setFillColor(colorB.withAlphaComponent(0.9).cgColor)
            cg.fillEllipse(in: crescentRect.offsetBy(dx: 26, dy: -10))
        }
    }

    /// Save a demo image with a "demo-" filename prefix so generated photos
    /// never collide with real captures.
    static func saveDemo(seed: UInt64, dayKey: String, prayer: Prayer) -> String? {
        let filename = "demo-\(dayKey)_\(prayer.rawValue)_\(String(seed, radix: 16)).jpg"
        guard write(demoImage(seed: seed), filename: filename) else { return nil }
        return filename
    }

    // MARK: - Internals

    private static func write(_ image: UIImage, filename: String) -> Bool {
        guard let data = downscaled(image).jpegData(compressionQuality: jpegQuality) else { return false }
        do {
            try data.write(to: url(for: filename), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension, longEdge > 0 else { return image }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
