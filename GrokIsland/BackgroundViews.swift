import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings block for the expanded island's background: the built-in ink glass (default), or an
/// opt-in solid, gradient, or photo.
/// Edits apply live, so the island behind this screen is the preview.
struct IslandBackgroundSection: View {
    @ObservedObject var settings: IslandSettings

    @State private var note: String?
    @Namespace private var kindThumb

    /// Above the island's `.statusBar` panel, so pickers never open underneath it.
    private static let pickerLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    var body: some View {
        IslandGroup("岛背景") {
            HStack(spacing: 0) {
                ForEach(IslandBackgroundKind.allCases) { kind in
                    IslandSegment(
                        title: kind.title,
                        selected: settings.background.kind == kind,
                        namespace: kindThumb
                    ) {
                        withAnimation(IslandChrome.selectSpring) { settings.background.kind = kind }
                    }
                }
            }
            .islandSegmentTrack()

            switch settings.background.kind {
            case .standard:
                caption("深色磨砂底，和刘海一样安静。自定义过的颜色和图片会保留，随时可以切回去。")
            case .solid:
                solidControls
            case .gradient:
                gradientControls
            case .image:
                imageControls
            }

            if settings.background.usesCustomFill {
                sharedSliders
            }

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandChrome.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            if settings.background != .default {
                Button("全部重置") {
                    settings.resetBackground()
                    note = nil
                }
                .buttonStyle(.islandPill(.quiet, compact: true))
                .help("回到默认背景，并清掉自定义的颜色和图片。只想切回原样、保留自定义，点上面的「默认」就行。")
            }
        }
        .onAppear { NSColorPanel.shared.level = Self.pickerLevel }
        .onDisappear {
            if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        }
    }

    // MARK: - Kinds

    private var solidControls: some View {
        HStack(spacing: 6) {
            ForEach(IslandBackgroundStyle.solidPresets) { preset in
                swatch(
                    Color(islandRGB: preset.color),
                    selected: settings.background.solid == preset.color,
                    help: preset.title
                ) {
                    settings.background.solid = preset.color
                }
            }
            Spacer(minLength: 0)
            ColorPicker("", selection: solidBinding, supportsOpacity: false)
                .labelsHidden()
                .help("自定义颜色")
        }
    }

    private var gradientControls: some View {
        let stops = settings.background.gradient
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ForEach(IslandBackgroundStyle.gradientPresets) { preset in
                    swatch(
                        LinearGradient(
                            colors: preset.colors.map { Color(islandRGB: $0) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        selected: stops == preset.colors,
                        help: preset.title,
                        width: 28
                    ) {
                        settings.background.gradient = preset.colors
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Text("色标")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(stops.indices, id: \.self) { index in
                    ColorPicker("", selection: stopBinding(index), supportsOpacity: false)
                        .labelsHidden()
                }
                Spacer(minLength: 0)
                Button {
                    settings.background.gradient.removeLast()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(IslandIconButtonStyle(size: 22))
                .disabled(stops.count <= IslandBackgroundStyle.gradientStopRange.lowerBound)
                .help("去掉最后一个色标")
                Button {
                    settings.background.gradient.append(stops.last ?? settings.background.solid)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IslandIconButtonStyle(size: 22))
                .disabled(stops.count >= IslandBackgroundStyle.gradientStopRange.upperBound)
                .help("加一个色标")
            }
            sliderRow("角度", value: $settings.background.gradientAngle, in: IslandBackgroundStyle.angleRange) {
                "\(Int($0.rounded()))°"
            }
        }
    }

    private var imageControls: some View {
        let hasImage = settings.backgroundImageURL != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(hasImage ? "正在用自己的图片" : "还没选图片")
                        .font(.system(size: 11, weight: .medium))
                    caption(hasImage ? "拷了一份到 Application Support/GrokIsland/backgrounds" : "选好之前先用默认背景。")
                }
                Spacer(minLength: 0)
                Button(hasImage ? "换一张" : "选图片", action: pickImage)
                    .buttonStyle(.islandPill(compact: true))
            }
            sliderRow("模糊", value: $settings.background.imageBlur, in: IslandBackgroundStyle.blurRange) {
                "\(Int($0.rounded()))"
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let image = IslandBackgroundImageCache.image(at: settings.backgroundImageURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 30)
                .clipShape(shape)
                .overlay { shape.strokeBorder(IslandChrome.edge, lineWidth: 1) }
        } else {
            shape
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 30)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Readability

    private var sharedSliders: some View {
        let style = settings.background
        return VStack(alignment: .leading, spacing: 4) {
            sliderRow("暗化", value: $settings.background.dim, in: IslandBackgroundStyle.dimRange, display: percent)
            if style.minimumDim > style.dim + 0.005 {
                caption("这个背景偏亮，已自动暗化到 \(percent(style.effectiveDim))，免得文字看不清。")
            }
            sliderRow("不透明度", value: $settings.background.opacity, in: IslandBackgroundStyle.opacityRange, display: percent)
            sliderRow("极光叠加", value: $settings.background.auroraOverlay, in: IslandBackgroundStyle.auroraOverlayRange, display: percent)
            caption("不透明度调低会透出毛玻璃。喜欢以前的流动极光，可以把极光叠加调上去。")
        }
    }

    // MARK: - Pieces

    private func swatch<Fill: ShapeStyle>(
        _ fill: Fill,
        selected: Bool,
        help: String,
        width: CGFloat = 22,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button(action: action) {
            shape
                .fill(fill)
                .frame(width: width, height: 18)
                .overlay {
                    shape.strokeBorder(
                        selected ? Color.white.opacity(0.9) : Color.white.opacity(0.15),
                        lineWidth: selected ? 1.5 : 1
                    )
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 48, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(display(value.wrappedValue))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var solidBinding: Binding<Color> {
        Binding(
            get: { Color(islandRGB: settings.background.solid) },
            set: { color in
                if let rgb = IslandRGB(color: color) { settings.background.solid = rgb }
            }
        )
    }

    /// Index-safe: a stop can be removed while its color well is still on screen.
    private func stopBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let stops = settings.background.gradient
                let rgb = stops.indices.contains(index) ? stops[index] : (stops.last ?? settings.background.solid)
                return Color(islandRGB: rgb)
            },
            set: { color in
                guard let rgb = IslandRGB(color: color), settings.background.gradient.indices.contains(index) else { return }
                settings.background.gradient[index] = rgb
            }
        )
    }

    // MARK: - Picking

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.title = "选择岛背景图片"
        panel.prompt = "用作背景"
        panel.message = "会复制一份到 Application Support，原图之后移动或删除都没关系。"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = Self.pickerLevel
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard IslandBackgroundImageCache.canDecode(url) else {
            note = IslandBackgroundError.unreadable.localizedDescription
            return
        }
        do {
            try settings.importBackgroundImage(from: url)
            note = nil
        } catch {
            note = error.localizedDescription
        }
    }
}
