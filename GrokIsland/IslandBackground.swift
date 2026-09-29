import Foundation

/// sRGB color with 0...1 components. Stored as hex so the saved preference stays readable.
struct IslandRGB: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
    }

    /// Accepts `#RRGGBB`, `RRGGBB`, or the short `#RGB` form.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return "#" + bytes.map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    /// WCAG relative luminance, 0 (black) ... 1 (white).
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let color = IslandRGB(hex: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad hex color \(raw)"))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

private extension IslandRGB {
    /// Only for the built-in presets below, which are known-good literals.
    static func literal(_ hex: String) -> IslandRGB {
        IslandRGB(hex: hex) ?? IslandRGB(red: 0, green: 0, blue: 0)
    }
}

enum IslandBackgroundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case aurora
    case solid
    case gradient
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "极光"
        case .solid: "纯色"
        case .gradient: "渐变"
        case .image: "图片"
        }
    }
}

/// What sits behind the expanded island's content, on top of the frosted desktop blur.
///
/// Custom fills get a dark veil (`effectiveDim`) so white text and the neon chrome stay
/// readable; bright colors raise the veil's floor no matter what the slider says.
struct IslandBackgroundStyle: Codable, Equatable, Sendable {
    static let dimRange: ClosedRange<Double> = 0...0.8
    static let opacityRange: ClosedRange<Double> = 0.3...1
    static let blurRange: ClosedRange<Double> = 0...24
    static let auroraOverlayRange: ClosedRange<Double> = 0...1
    static let angleRange: ClosedRange<Double> = 0...360
    static let gradientStopRange: ClosedRange<Int> = 2...4
    /// A photo can be bright anywhere, so it always gets at least this much veil.
    static let imageMinimumDim = 0.18

    var kind: IslandBackgroundKind = .aurora
    var solid: IslandRGB = Self.solidPresets[0].color
    var gradient: [IslandRGB] = Self.gradientPresets[0].colors
    /// Degrees clockwise from left → right; 90 runs top → bottom.
    var gradientAngle: Double = 135
    /// File name inside the backgrounds folder. Kept when switching kinds so the photo comes back.
    var imageFileName: String?
    var imageBlur: Double = 6
    var dim: Double = 0.3
    /// Below 1 the frosted desktop blur shows through the custom fill.
    var opacity: Double = 0.92
    /// How much of the animated aurora is screened over the custom fill.
    var auroraOverlay: Double = 0.25

    static let `default` = IslandBackgroundStyle()

    init() {}

    var usesCustomFill: Bool { kind != .aurora }

    /// Veil floor that keeps white caption text legible over this fill.
    var minimumDim: Double {
        switch kind {
        case .aurora:
            return 0
        case .solid:
            return Self.dimFloor(forLuminance: solid.luminance * opacity)
        case .gradient:
            let brightest = gradient.map(\.luminance).max() ?? 0
            return Self.dimFloor(forLuminance: brightest * opacity)
        case .image:
            return Self.imageMinimumDim
        }
    }

    var effectiveDim: Double {
        min(max(dim, minimumDim), Self.dimRange.upperBound)
    }

    /// Unit-square endpoints for `gradientAngle`, in SwiftUI's y-down space.
    var gradientPoints: (start: (x: Double, y: Double), end: (x: Double, y: Double)) {
        let radians = gradientAngle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return ((0.5 - dx, 0.5 - dy), (0.5 + dx, 0.5 + dy))
    }

    /// Clamps every value into its range and repairs the gradient stop count.
    func sanitized() -> IslandBackgroundStyle {
        var copy = self
        copy.gradientAngle = Self.clamp(gradientAngle, Self.angleRange, fallback: 135)
        copy.imageBlur = Self.clamp(imageBlur, Self.blurRange, fallback: 6)
        copy.dim = Self.clamp(dim, Self.dimRange, fallback: 0.3)
        copy.opacity = Self.clamp(opacity, Self.opacityRange, fallback: 0.92)
        copy.auroraOverlay = Self.clamp(auroraOverlay, Self.auroraOverlayRange, fallback: 0.25)
        if copy.gradient.count > Self.gradientStopRange.upperBound {
            copy.gradient = Array(copy.gradient.prefix(Self.gradientStopRange.upperBound))
        }
        while copy.gradient.count < Self.gradientStopRange.lowerBound {
            copy.gradient.append(copy.gradient.last ?? solid)
        }
        if let name = copy.imageFileName, !Self.isPlainFileName(name) {
            copy.imageFileName = nil
        }
        return copy
    }

    /// Rejects anything that could point outside the backgrounds folder.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." && !name.hasPrefix(".")
    }

    /// Luminance up to ~0.18 (a mid navy) needs nothing extra; white needs a heavy veil.
    private static func dimFloor(forLuminance luminance: Double) -> Double {
        min(max(0, (luminance - 0.18) * 0.75), 0.62)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case kind, solid, gradient, gradientAngle, imageFileName, imageBlur, dim, opacity, auroraOverlay
    }

    /// Missing or unknown fields fall back to defaults so older saved styles keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = IslandBackgroundStyle()
        kind = (try? container.decodeIfPresent(IslandBackgroundKind.self, forKey: .kind)) ?? fallback.kind
        solid = (try? container.decodeIfPresent(IslandRGB.self, forKey: .solid)) ?? fallback.solid
        gradient = (try? container.decodeIfPresent([IslandRGB].self, forKey: .gradient)) ?? fallback.gradient
        gradientAngle = (try? container.decodeIfPresent(Double.self, forKey: .gradientAngle)) ?? fallback.gradientAngle
        imageFileName = try? container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageBlur = (try? container.decodeIfPresent(Double.self, forKey: .imageBlur)) ?? fallback.imageBlur
        dim = (try? container.decodeIfPresent(Double.self, forKey: .dim)) ?? fallback.dim
        opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? fallback.opacity
        auroraOverlay = (try? container.decodeIfPresent(Double.self, forKey: .auroraOverlay)) ?? fallback.auroraOverlay
        self = sanitized()
    }
}

// MARK: - Presets

struct IslandSolidPreset: Identifiable, Sendable {
    let title: String
    let color: IslandRGB
    var id: String { title }
}

struct IslandGradientPreset: Identifiable, Sendable {
    let title: String
    let colors: [IslandRGB]
    var id: String { title }
}

extension IslandBackgroundStyle {
    static let solidPresets: [IslandSolidPreset] = [
        IslandSolidPreset(title: "午夜蓝", color: .literal("#0B1030")),
        IslandSolidPreset(title: "深空黑", color: .literal("#0A0A12")),
        IslandSolidPreset(title: "石墨", color: .literal("#1E2028")),
        IslandSolidPreset(title: "暗紫", color: .literal("#2A1250")),
        IslandSolidPreset(title: "墨绿", color: .literal("#082A26")),
        IslandSolidPreset(title: "酒红", color: .literal("#3A0C24"))
    ]

    static let gradientPresets: [IslandGradientPreset] = [
        IslandGradientPreset(title: "赛博霓虹", colors: [.literal("#0A0F2C"), .literal("#3B1C6E"), .literal("#00A8C0")]),
        IslandGradientPreset(title: "深海", colors: [.literal("#020617"), .literal("#0B3B5C"), .literal("#0E7490")]),
        IslandGradientPreset(title: "暮光", colors: [.literal("#1E1B4B"), .literal("#7C2D6B"), .literal("#E0662A")]),
        IslandGradientPreset(title: "极夜", colors: [.literal("#050510"), .literal("#1A1446"), .literal("#2E6B5E")]),
        IslandGradientPreset(title: "樱花", colors: [.literal("#2B0A22"), .literal("#8E2F66"), .literal("#E59BBE")]),
        IslandGradientPreset(title: "电光", colors: [.literal("#FF2E97"), .literal("#2EE6FF")])
    ]
}

enum IslandBackgroundError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case tooLarge(Int64)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return ext.isEmpty ? "不认识这个文件格式，请选 PNG / JPEG / HEIC 等图片" : "不支持 .\(ext) 图片，请选 PNG / JPEG / HEIC 等格式"
        case .tooLarge(let bytes):
            let megabytes = Double(bytes) / 1_048_576
            return String(format: "图片太大（%.0f MB），请选 40 MB 以内的", megabytes)
        case .unreadable:
            return "读不了这张图片"
        }
    }
}
