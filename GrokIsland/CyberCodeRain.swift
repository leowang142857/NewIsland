import SwiftUI

/// Shared chrome for the floating island. Deep navy-black glass, neon edge, spring reveal.
enum IslandChrome {
    /// Deep navy-black wash over the frost. Still translucent so the material reads as glass.
    static let glassTint = Color(red: 0.012, green: 0.018, blue: 0.032).opacity(0.84)

    static let neonCyan = Color(red: 0.28, green: 0.96, blue: 1.0)
    static let electricGreen = Color(red: 0.22, green: 1.0, blue: 0.58)

    static let cornerRadius: CGFloat = 16

    static let borderGradient = LinearGradient(
        colors: [
            neonCyan.opacity(0.95),
            electricGreen.opacity(0.55),
            Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.85)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Paired with the panel frame timing in `IslandPanelController.applyFrame`.
    static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)

    static let revealTransition: AnyTransition = .scale(scale: 0.84, anchor: .top).combined(with: .opacity)
}

/// Vertical code streams drawn behind island content.
///
/// Deterministic from time (no stored randomness) so SwiftUI can redraw the canvas
/// from a `TimelineView` clock. Opacity stays low; the glass tint does the rest.
struct CyberCodeRain: View {
    var veil: Double = 0.32

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                drawRain(
                    into: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .opacity(veil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Dark frosted fill. Material is rearmost so it can blur the desktop; the tint
/// keeps the panel near-black; rain sits above that and below UI content.
struct IslandGlassBackdrop: View {
    var rainVeil: Double = 0.32

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(IslandChrome.glassTint)
            CyberCodeRain(veil: rainVeil)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Rounded (or capsule) dark glass, code rain, and a thin neon stroke.
    func islandChrome<S: InsettableShape>(
        _ shape: S,
        rainVeil: Double = 0.32,
        emphasized: Bool = false
    ) -> some View {
        background {
            IslandGlassBackdrop(rainVeil: rainVeil)
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    IslandChrome.borderGradient,
                    lineWidth: emphasized ? 1.5 : 1
                )
                .shadow(
                    color: IslandChrome.neonCyan.opacity(emphasized ? 0.9 : 0.55),
                    radius: emphasized ? 5 : 3
                )
                .allowsHitTesting(false)
        }
        .overlay {
            if emphasized {
                shape
                    .strokeBorder(IslandChrome.neonCyan.opacity(0.95), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Rain drawing

private let rainGlyphs: [Character] = Array("01ABCDEFGHIJKLMNOPQRSTUVWXYZ#$%&*+-/<>[]{}|=^~")

private func drawRain(into context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    guard size.width > 2, size.height > 2 else { return }

    let fontSize: CGFloat = 11
    let columnWidth: CGFloat = 13
    let rowHeight: CGFloat = 13
    let columns = max(1, Int(ceil(size.width / columnWidth)))
    let tick = Int(time / 0.55)

    for column in 0..<columns {
        let seed = columnSeed(column)
        let trail = 8 + (seed % 7)
        let speed = 8.0 + Double(seed % 9)
        let phase = Double((seed / 5) % 320)
        let loop = Double(size.height) + Double(trail + 2) * Double(rowHeight)
        let head = (time * speed + phase).truncatingRemainder(dividingBy: loop)
        let x = CGFloat(column) * columnWidth + columnWidth * 0.5
        let cyanColumn = (seed % 3) != 0

        for step in 0..<trail {
            var y = CGFloat(head) - CGFloat(step) * rowHeight
            if y < -rowHeight {
                y += CGFloat(loop)
            }
            guard y > -rowHeight, y < size.height + rowHeight else { continue }

            let glyph = rainGlyphs[glyphIndex(seed: seed, step: step, tick: tick)]
            let color = glyphColor(step: step, trail: trail, cyan: cyanColumn)
            let mark = context.resolve(
                Text(String(glyph))
                    .font(.custom("Menlo", size: step == 0 ? fontSize : fontSize - 0.5))
                    .foregroundStyle(color)
            )
            let point = CGPoint(x: x, y: y)

            if step == 0 {
                var glow = context
                glow.addFilter(.blur(radius: 2.2))
                glow.opacity = 0.8
                glow.draw(mark, at: point, anchor: .center)
            }

            context.draw(mark, at: point, anchor: .center)
        }
    }
}

private func columnSeed(_ column: Int) -> Int {
    var x = column &* 1_103_515_245 &+ 12_345
    x = (x ^ (x >> 16)) &* 2_246_822_519
    return (x ^ (x >> 13)) & 0x7FFF_FFFF
}

private func glyphIndex(seed: Int, step: Int, tick: Int) -> Int {
    let mixed = (seed &+ step &* 17 &+ tick &* 31) & 0x7FFF_FFFF
    return mixed % rainGlyphs.count
}

private func glyphColor(step: Int, trail: Int, cyan: Bool) -> Color {
    if step == 0 {
        return Color(red: 0.88, green: 1.0, blue: 0.98).opacity(0.95)
    }
    let fade = 1 - Double(step) / Double(max(trail - 1, 1))
    let base = cyan ? IslandChrome.neonCyan : IslandChrome.electricGreen
    return base.opacity(0.12 + 0.72 * fade)
}
