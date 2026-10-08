import AppKit
import ImageIO
import SwiftUI

/// Shared chrome for the floating island: a quiet ink surface, a hairline edge, spring reveal.
///
/// Color carries meaning only. `accent` marks the one thing you're interacting with; green,
/// amber, orange, and red are task states. Everything else is white at some opacity.
enum IslandChrome {
    static let name = "NewIsland"

    static let accent = Color(red: 0.45, green: 0.64, blue: 1.0)
    static let positive = Color(red: 0.42, green: 0.82, blue: 0.55)
    static let danger = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let caution = Color(red: 0.96, green: 0.76, blue: 0.36)
    static let ember = Color(red: 0.97, green: 0.58, blue: 0.30)

    /// Near-black, a touch warm, so it sits next to the notch without looking like a hole.
    static let ink = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let surface = Color.white.opacity(0.055)
    static let surfaceRaised = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.08)
    static let edge = Color.white.opacity(0.11)

    static let cornerRadius: CGFloat = 18
    static let innerRadius: CGFloat = 9

    /// Paired with the panel frame timing in `IslandPanelController.applyFrame`.
    static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.1)

    static let revealTransition: AnyTransition = .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
}

/// One-pixel divider between the island's layers.
struct IslandHairline: View {
    var body: some View {
        Rectangle()
            .fill(IslandChrome.hairline)
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Small grey label that names a section, in place of boxes and colored badges.
    func islandSectionLabel() -> some View {
        font(.system(size: 10, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }

    /// Borderless text field on a soft fill; reads as part of the island rather than a system box.
    func islandField(highlighted: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(IslandChrome.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(highlighted ? IslandChrome.accent.opacity(0.8) : Color.clear, lineWidth: 1)
            }
    }
}

/// Colors sampled from the aurora photo, plus the island's own navy / neon blues.
private enum AuroraPalette {
    typealias RGB = SIMD3<Double>

    static let night: RGB = [0.035, 0.045, 0.13]
    static let navy: RGB = [0.10, 0.13, 0.38]
    static let indigo: RGB = [0.24, 0.10, 0.46]
    static let violet: RGB = [0.30, 0.22, 0.70]
    static let magenta: RGB = [0.62, 0.20, 0.72]
    static let iceBlue: RGB = [0.35, 0.75, 1.0]
    static let cyan: RGB = [0.28, 0.96, 1.0]
    static let mint: RGB = [0.30, 0.92, 0.58]
    static let green: RGB = [0.55, 0.90, 0.45]
    static let lime: RGB = [0.80, 0.98, 0.32]
    static let teal: RGB = [0.16, 0.55, 0.66]

    /// Three 4x4 mesh layouts (rows top → bottom). Each mesh point drifts through them in turn.
    static let layouts: [[RGB]] = [
        [
            night, navy, violet, night,
            magenta, indigo, iceBlue * 0.75, navy,
            mint, green, mint * 0.9, teal,
            night, teal * 0.8, navy, night
        ],
        [
            navy, iceBlue * 0.65, night, violet,
            indigo, cyan * 0.7, magenta, navy,
            teal, mint, iceBlue * 0.85, green * 0.9,
            night, navy, teal * 0.8, night
        ],
        [
            violet, night, magenta, navy,
            navy, magenta * 0.9, violet, iceBlue * 0.75,
            green, teal, mint, cyan * 0.7,
            navy, night, indigo, night
        ]
    ]

    static func color(_ rgb: RGB) -> Color {
        Color(red: min(rgb.x, 1), green: min(rgb.y, 1), blue: min(rgb.z, 1))
    }
}

/// Deterministic from time, so SwiftUI can redraw it from a `TimelineView` clock.
private enum AuroraField {
    static let columns = 4
    static let rows = 4

    static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for row in 0..<rows {
            for column in 0..<columns {
                var x = Double(column) / Double(columns - 1)
                var y = Double(row) / Double(rows - 1)
                let seed = Double(row * columns + column)
                let edgeX = column == 0 || column == columns - 1
                let edgeY = row == 0 || row == rows - 1
                if !edgeX { x += 0.09 * sin(time * 0.21 + seed * 1.7) }
                if !edgeY { y += 0.07 * sin(time * 0.17 + seed * 2.3) }
                points.append(SIMD2(Float(x), Float(y)))
            }
        }
        return points
    }

    static func rgb(at time: TimeInterval) -> [AuroraPalette.RGB] {
        let layouts = AuroraPalette.layouts
        return (0..<(rows * columns)).map { index in
            let phase = Double(index) * 0.137
            let cycle = (time * 0.035 + phase).truncatingRemainder(dividingBy: 1) * Double(layouts.count)
            let from = Int(cycle) % layouts.count
            let to = (from + 1) % layouts.count
            let t = cycle - floor(cycle)
            let eased = t * t * (3 - 2 * t)
            return layouts[from][index] * (1 - eased) + layouts[to][index] * eased
        }
    }

    static func colors(at time: TimeInterval) -> [Color] {
        rgb(at: time).map(AuroraPalette.color)
    }
}

/// Continuously shifting aurora sky: mesh gradient, light curtains, faint stars. No glyphs.
/// Only drawn when the user turns up "aurora overlay" on a custom background.
struct AuroraBackdrop: View {
    /// 0...1 strength of the bright curtains and stars.
    var glow: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                AuroraSky(time: time)
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    drawCurtains(into: &context, size: size, time: time, glow: glow)
                    drawStars(into: &context, size: size, time: time, glow: glow)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AuroraSky: View {
    var time: TimeInterval

    var body: some View {
        if #available(macOS 15.0, *) {
            MeshGradient(
                width: AuroraField.columns,
                height: AuroraField.rows,
                points: AuroraField.points(at: time),
                colors: AuroraField.colors(at: time),
                smoothsColors: true
            )
        } else {
            let colors = AuroraField.colors(at: time)
            LinearGradient(
                colors: stride(from: 1, to: colors.count, by: AuroraField.columns).map { colors[$0] },
                startPoint: UnitPoint(x: 0.5 + 0.3 * sin(time * 0.1), y: 0),
                endPoint: UnitPoint(x: 0.5 - 0.3 * sin(time * 0.1), y: 1)
            )
        }
    }
}

/// Dark frosted fill. Material is rearmost so it can blur the desktop; the ink (or the user's
/// own fill) sits on top of it, and a dark veil keeps white UI text readable.
struct IslandGlassBackdrop: View {
    var glow: Double = 1
    var style: IslandBackgroundStyle = .default
    var imageURL: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if let fill = customFill {
                fill
                    .opacity(style.opacity)
                if style.auroraOverlay > 0 {
                    AuroraBackdrop(glow: glow * style.auroraOverlay)
                        .opacity(style.auroraOverlay)
                        .blendMode(.screen)
                }
                customVeil
            } else {
                IslandChrome.ink.opacity(0.94)
                // Barely-there top light, so the surface has a direction without a gradient show.
                LinearGradient(
                    colors: [.white.opacity(0.035), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.35)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Nil means "use the stock ink surface", including when the picked image can't be read.
    private var customFill: IslandBackgroundFill? {
        switch style.kind {
        case .standard:
            return nil
        case .solid, .gradient:
            return IslandBackgroundFill(style: style, image: nil)
        case .image:
            guard let image = IslandBackgroundImageCache.image(at: imageURL) else { return nil }
            return IslandBackgroundFill(style: style, image: image)
        }
    }

    /// Heavier at the header and footer, where the densest text sits.
    private var customVeil: some View {
        let dim = style.effectiveDim
        return LinearGradient(
            colors: [.black.opacity(dim * 0.95), .black.opacity(dim * 0.7), .black.opacity(min(1, dim * 1.1))],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The user's solid color, gradient, or photo, without any veil.
struct IslandBackgroundFill: View {
    let style: IslandBackgroundStyle
    let image: NSImage?

    var body: some View {
        switch style.kind {
        case .standard:
            Color.clear
        case .solid:
            Rectangle().fill(Color(islandRGB: style.solid))
        case .gradient:
            let points = style.gradientPoints
            LinearGradient(
                colors: style.gradient.map { Color(islandRGB: $0) },
                startPoint: UnitPoint(x: points.start.x, y: points.start.y),
                endPoint: UnitPoint(x: points.end.x, y: points.end.y)
            )
        case .image:
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    }
                    .clipped()
                    .blur(radius: style.imageBlur, opaque: true)
            } else {
                Color.clear
            }
        }
    }
}

extension Color {
    init(islandRGB rgb: IslandRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

extension IslandRGB {
    init?(color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }
}

/// Decodes the background photo once, downsampled to about the island's Retina size.
/// Imported photos get a fresh file name, so caching by URL never serves a stale picture.
enum IslandBackgroundImageCache {
    private static let maxPixelSize = 1400
    private static let lock = NSLock()
    private static var cached: (url: URL, image: NSImage?)?

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.url == url { return cached.image }
        let image = decode(url)
        cached = (url, image)
        return image
    }

    static func canDecode(_ url: URL) -> Bool {
        decode(url) != nil
    }

    private static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension View {
    /// Ink glass with a hairline edge. Pass a custom `background` to swap the ink for the
    /// user's fill. `emphasized` (a drag over the island) turns the edge to the accent.
    func islandChrome<S: InsettableShape>(
        _ shape: S,
        glow: Double = 1,
        emphasized: Bool = false,
        background style: IslandBackgroundStyle = .default,
        imageURL: URL? = nil
    ) -> some View {
        background {
            IslandGlassBackdrop(glow: glow, style: style, imageURL: imageURL)
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    emphasized ? IslandChrome.accent : IslandChrome.edge,
                    lineWidth: emphasized ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Curtains and stars

private func drawCurtains(into context: inout GraphicsContext, size: CGSize, time: TimeInterval, glow: Double) {
    guard glow > 0, size.width > 2, size.height > 2 else { return }
    var layer = context
    layer.blendMode = .plusLighter
    layer.addFilter(.blur(radius: max(2.5, min(size.width, size.height) * 0.035)))

    let rays = 12
    let fringe = AuroraPalette.color(AuroraPalette.magenta)
    for index in 0..<rays {
        let seed = Double(index) * 1.618
        let wave = { (speed: Double, offset: Double) in 0.5 + 0.5 * sin(time * speed + seed * offset) }
        let centerX = size.width * ((Double(index) + 0.5) / Double(rays) + 0.06 * sin(time * 0.11 + seed * 2.1))
        let width = size.width * (0.025 + 0.04 * wave(0.17, 1))
        let top = size.height * (0.06 + 0.16 * wave(0.09, 3))
        let bottom = size.height * (0.58 + 0.18 * wave(0.07, 1.3))
        let alpha = glow * (0.14 + 0.24 * wave(0.33, 4.7))
        let tint: Color
        switch index % 4 {
        case 0: tint = AuroraPalette.color(AuroraPalette.cyan)
        case 1, 3: tint = AuroraPalette.color(AuroraPalette.mint)
        default: tint = AuroraPalette.color(AuroraPalette.lime)
        }
        let rect = CGRect(x: centerX - width / 2, y: top, width: width, height: bottom - top)
        let gradient = Gradient(stops: [
            .init(color: fringe.opacity(0), location: 0),
            .init(color: fringe.opacity(alpha * 0.5), location: 0.18),
            .init(color: tint.opacity(alpha * 0.7), location: 0.55),
            .init(color: tint.opacity(alpha), location: 0.85),
            .init(color: tint.opacity(0), location: 1)
        ])
        layer.fill(
            Path(roundedRect: rect, cornerRadius: width / 2),
            with: .linearGradient(gradient, startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
        )
    }
}

private func drawStars(into context: inout GraphicsContext, size: CGSize, time: TimeInterval, glow: Double) {
    guard glow > 0, size.height > 60 else { return }
    let count = Int(size.width * size.height / 2600)
    for index in 0..<count {
        let h1 = unitHash(index, 1), h2 = unitHash(index, 2), h3 = unitHash(index, 3)
        let point = CGPoint(x: h1 * size.width, y: h2 * size.height * 0.62)
        let radius = 0.4 + 0.8 * h3
        let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * (0.6 + h3 * 1.4) + h1 * 40))
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(.white.opacity(0.5 * twinkle * glow))
        )
    }
}

private func unitHash(_ index: Int, _ salt: Int) -> Double {
    var x = (index &* 73_856_093) ^ (salt &* 19_349_663)
    x = (x ^ (x >> 13)) &* 1_274_126_177
    return Double((x ^ (x >> 16)) & 0xFFFF) / 65_535
}
