import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings block for the expanded island's background: stock aurora, solid, gradient, or a photo.
/// Edits apply live, so the island behind this screen is the preview.
struct IslandBackgroundSection: View {
    @ObservedObject var settings: IslandSettings

    @State private var note: String?

    /// Above the island's `.statusBar` panel, so pickers never open underneath it.
    private static let pickerLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("岛背景")
                    .font(.caption.weight(.semibold))
                Spacer()
                if settings.background != .default {
                    Button("恢复默认") {
                        settings.resetBackground()
                        note = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }

            Picker("", selection: $settings.background.kind) {
                ForEach(IslandBackgroundKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch settings.background.kind {
            case .aurora:
                caption("默认的流动极光。换成纯色、渐变或图片后，霓虹边框保持不变。")
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
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                        width: 30
                    ) {
                        settings.background.gradient = preset.colors
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Text("色标")
                    .font(.caption2)
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
                .buttonStyle(.borderless)
                .disabled(stops.count <= IslandBackgroundStyle.gradientStopRange.lowerBound)
                .help("去掉最后一个色标")
                Button {
                    settings.background.gradient.append(stops.last ?? settings.background.solid)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
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
                    Text(hasImage ? "正在用自定义图片" : "还没选图片")
                        .font(.caption2.weight(.medium))
                    caption(hasImage ? "已复制到 Application Support/GrokIsland/backgrounds" : "选好之前先显示极光。")
                }
                Spacer(minLength: 0)
                Button(hasImage ? "换一张…" : "选择图片…", action: pickImage)
                    .controlSize(.small)
            }
            sliderRow("模糊", value: $settings.background.imageBlur, in: IslandBackgroundStyle.blurRange) {
                "\(Int($0.rounded()))"
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if let image = IslandBackgroundImageCache.image(at: settings.backgroundImageURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 30)
                .clipShape(shape)
                .overlay { shape.strokeBorder(IslandChrome.neonCyan.opacity(0.5), lineWidth: 1) }
        } else {
            shape
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 30)
                .overlay {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Readability

    private var sharedSliders: some View {
        let style = settings.background
        return VStack(alignment: .leading, spacing: 3) {
            sliderRow("暗化", value: $settings.background.dim, in: IslandBackgroundStyle.dimRange, display: percent)
            if style.minimumDim > style.dim + 0.005 {
                caption("这个背景偏亮，已自动暗化到 \(percent(style.effectiveDim))，保证文字和霓虹边框清楚。")
            }
            sliderRow("不透明度", value: $settings.background.opacity, in: IslandBackgroundStyle.opacityRange, display: percent)
            sliderRow("极光叠加", value: $settings.background.auroraOverlay, in: IslandBackgroundStyle.auroraOverlayRange, display: percent)
            caption("不透明度调低会透出毛玻璃；极光叠加把流动极光轻轻叠在背景上。")
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
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button(action: action) {
            shape
                .fill(fill)
                .frame(width: width, height: 16)
                .overlay {
                    shape.strokeBorder(
                        selected ? IslandChrome.neonCyan : Color.white.opacity(0.25),
                        lineWidth: selected ? 1.5 : 1
                    )
                }
                .shadow(color: IslandChrome.neonCyan.opacity(selected ? 0.7 : 0), radius: 3)
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
                .font(.caption2)
                .frame(width: 50, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(display(value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
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
