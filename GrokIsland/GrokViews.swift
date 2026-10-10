import AppKit
import SwiftUI

/// Three shortcut buttons plus a free-form question, all about the frontmost page.
struct GrokQuickBar: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var settings: IslandSettings
    let onStarted: (UUID) -> Void

    @State private var question = ""
    @State private var splitDraft = ""
    @State private var capturing = false
    /// Which shortcut tile is taking the screenshot; nil while the question field is.
    @State private var capturingShortcut: Int?
    @State private var splitting = false
    @State private var splitTargeted = false
    @State private var note: String?

    private var shortcuts: [ResolvedIslandShortcut] {
        settings.shortcutButtons.resolved()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fixed vertically so a two-line custom title grows all three tiles together.
            HStack(spacing: 6) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    ShortcutButton(
                        shortcut: shortcuts[index],
                        busy: capturing && capturingShortcut == index,
                        disabled: capturing
                    ) {
                        fire(shortcuts[index], at: index)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                inputRow(
                    "问问 Grok · 会带上当前页面",
                    text: $question,
                    busy: capturing && capturingShortcut == nil,
                    symbol: "arrow.up",
                    help: "发送",
                    submit: fireAsk
                )

                inputRow(
                    "大任务拆开做 · 也能拖文件进来",
                    text: $splitDraft,
                    busy: splitting,
                    symbol: "arrow.triangle.branch",
                    help: "拆成 2–4 个子任务一起做，做完汇总成一条",
                    highlighted: splitTargeted,
                    submit: { fireSplit() }
                )
                .onDrop(of: ShellView.dropTypes, isTargeted: $splitTargeted) { providers in
                    fireSplitDrop(providers)
                    return true
                }
            }

            if splitTargeted {
                caption("松手就拆成 2–4 个子任务，各自做完再汇总", color: .secondary)
            }

            if let note {
                caption(note, color: IslandChrome.ember)
            }
        }
    }

    /// Lines up with the text inside the capsule fields.
    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }

    /// Spotlight-like capsule with its action tucked inside the trailing end. The 22 pt button
    /// sits 4 pt in from the 30 pt capsule, so the two curves stay concentric.
    private func inputRow(
        _ placeholder: String,
        text: Binding<String>,
        busy: Bool,
        symbol: String,
        help: String,
        highlighted: Bool = false,
        submit: @escaping () -> Void
    ) -> some View {
        let empty = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TextField(placeholder, text: text)
            .onSubmit(submit)
            .padding(.trailing, 20)
            .islandCapsuleField(highlighted: highlighted)
            .overlay(alignment: .trailing) {
                Group {
                    if busy {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 22, height: 22)
                    } else {
                        Button(action: submit) {
                            Image(systemName: symbol)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(empty ? Color.white.opacity(0.32) : IslandChrome.ink)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(empty ? Color.clear : Color.white.opacity(0.9)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.islandPress)
                        .disabled(empty)
                        .help(help)
                    }
                }
                .padding(.trailing, 4)
                .animation(IslandChrome.hoverFade, value: empty)
            }
    }

    private func fire(_ shortcut: ResolvedIslandShortcut, at index: Int) {
        guard !capturing, shortcut.isReady else { return }
        capturing = true
        capturingShortcut = index
        note = nil
        Task { @MainActor in
            let page = await PageCapture.snapshot()
            capturing = false
            capturingShortcut = nil
            note = page.captureNote
            do {
                let record = try engine.runShortcut(title: shortcut.title, prompt: shortcut.prompt, page: page)
                onStarted(record.id)
            } catch {
                engine.reportError(error)
            }
        }
    }

    private func fireAsk() {
        guard !capturing else { return }
        capturing = true
        capturingShortcut = nil
        note = nil
        let asked = question
        Task { @MainActor in
            let page = await PageCapture.snapshot()
            capturing = false
            note = page.captureNote
            do {
                let record = try engine.runQuickAction(.askAboutPage, page: page, question: asked)
                question = ""
                onStarted(record.id)
            } catch {
                engine.reportError(error)
            }
        }
    }

    private func fireSplit(resources: [ResourceItem] = []) {
        do {
            let record = try engine.splitTask(splitDraft, resources: resources)
            splitDraft = ""
            onStarted(record.id)
        } catch {
            engine.reportError(error)
        }
    }

    private func fireSplitDrop(_ providers: [NSItemProvider]) {
        guard !splitting else { return }
        splitting = true
        note = nil
        Task { @MainActor in
            let items = await ResourceIntake.loadItems(from: providers)
            splitting = false
            if items.isEmpty && splitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.reportError(IslandError.dropEmpty)
                return
            }
            fireSplit(resources: items)
        }
    }
}

/// A Control Center–style tile: the glyph over a short label. The tapped tile shows the
/// spinner while the page is captured.
private struct ShortcutButton: View {
    let shortcut: ResolvedIslandShortcut
    var busy = false
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    private var lit: Bool { hovering && !disabled && shortcut.isReady }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandChrome.platterRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: shortcut.symbolName)
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(height: 18)
                Text(shortcut.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: .infinity)
            .background(shape.fill(lit ? IslandChrome.surfaceRaised : IslandChrome.surface))
            .overlay {
                shape
                    .strokeBorder(IslandChrome.hairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.islandPress)
        .onHover { hovering = $0 }
        .animation(IslandChrome.hoverFade, value: hovering)
        .disabled(disabled || !shortcut.isReady)
        .opacity(shortcut.isReady ? 1 : 0.45)
        .help(shortcut.isReady
            ? "把最前面的页面截下来，交给 Grok：\(shortcut.title)"
            : "这个按钮还没写要做什么 · 到设置里补上")
    }
}

/// Full answer for one run, with copy / open-in-Cursor / delete. Answers stay in the journal.
struct RunDetailView: View {
    let run: RunRecord
    @ObservedObject var engine: IslandEngine
    var onDeleted: () -> Void = {}

    @State private var copied = false

    private var state: TaskLightState { TaskLightBoard.state(for: run.phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if run.isActive {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: run.progress)
                        .controlSize(.small)
                    Text(run.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let question = run.question {
                        quote(question)
                    }
                    answer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            TaskLightDot(state: state, size: 6)
            Text(state.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.stamp(run.createdAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if run.isActive {
                    Button("取消") { engine.cancelRun(id: run.id) }
                        .buttonStyle(.islandPill(compact: true))
                        .padding(.trailing, 4)
                }
                if let answer = run.resultSummary, !run.isActive {
                    Button {
                        copy(answer)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.islandIcon(tint: copied ? IslandChrome.positive : nil))
                    .help(copied ? "拷好了" : "拷贝回答")
                }
                if let link = run.link, let url = URL(string: link) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.islandIcon())
                    .help("在 Cursor 里打开这个 Cloud Agent，可以接着问")
                }
                Button {
                    engine.deleteRuns(ids: [run.id])
                    onDeleted()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.islandIcon())
                .help(run.isActive ? "取消并删掉这条记录" : "删掉这条记录")
            }
        }
        .frame(minHeight: IslandChrome.iconTarget)
    }

    /// What was asked, set off by a thin bar the way Mail quotes a reply.
    private func quote(_ question: String) -> some View {
        Text(question)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 2)
            }
    }

    @ViewBuilder
    private var answer: some View {
        if let answer = run.resultSummary, !run.isActive {
            MarkdownLite(text: answer)
        } else if run.isActive {
            Text(run.origin == .splitTask
                ? "正在拆开同时做。每个子任务都有自己的灯，全做完会汇总到这里。"
                : "答好了就显示在这里。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Text(run.phase == .cancelled ? "取消了，这次没有结果。" : run.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func copy(_ answer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }

    /// Just the time for today, with the date before that, so a run's header or journal row
    /// stays on one line.
    static func stamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Headings, bullet lists, fenced code, and inline Markdown — enough for Grok answers.
struct MarkdownLite: View {
    let text: String

    private enum Block: Hashable {
        case heading(String)
        case paragraph(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line):
                    inline(line)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 5)
                case .paragraph(let line):
                    inline(line)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                case .code(let code):
                    Text(code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IslandChrome.surface)
                        .clipShape(RoundedRectangle(cornerRadius: IslandChrome.fieldRadius, style: .continuous))
                }
            }
        }
    }

    private func inline(_ line: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: line, options: options) {
            return Text(attributed)
        }
        return Text(line)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]?
        for raw in text.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                result.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.paragraph("• " + line.dropFirst(2)))
            } else {
                result.append(.paragraph(line))
            }
        }
        if let lines = code {
            result.append(.code(lines.joined(separator: "\n")))
        }
        return result
    }
}

/// The three home-screen shortcut buttons. Each one is a built-in action or a custom prompt.
struct IslandShortcutSection: View {
    @ObservedObject var settings: IslandSettings

    private static let customChoice = "custom"

    var body: some View {
        IslandGroup("快捷按钮") {
            ForEach(0..<IslandShortcutButtons.count, id: \.self) { index in
                if index > 0 { IslandHairline() }
                slotEditor(index)
            }
            Text("点一下就截下最前面的页面，交给 Grok。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } accessory: {
            if settings.shortcutButtons != .default {
                Button("恢复默认") { settings.shortcutButtons = .default }
                    .buttonStyle(.islandPill(.quiet, compact: true))
                    .help("三个按钮回到整理错题、解答题目、检查代码。")
            }
        }
    }

    private func slotEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("按钮 \(index + 1)")
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Picker("", selection: choiceBinding(index)) {
                    ForEach(GrokQuickAction.buttons) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                    Text("自定义").tag(Self.customChoice)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if isCustom(index) {
                TextField("按钮上的字", text: stringBinding(index, \.customTitle))
                    .islandField()
                TextField("想让 Grok 做什么", text: stringBinding(index, \.customPrompt), axis: .vertical)
                    .lineLimit(2...4)
                    .islandField()
                HStack(spacing: 6) {
                    Text("图标")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Picker("", selection: stringBinding(index, \.customSymbol)) {
                        ForEach(IslandShortcutSlot.symbolAllowlist, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    private func isCustom(_ index: Int) -> Bool {
        guard settings.shortcutButtons.slots.indices.contains(index) else { return false }
        return settings.shortcutButtons.slots[index].kind == .custom
    }

    private func choiceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard settings.shortcutButtons.slots.indices.contains(index) else {
                    return GrokQuickAction.buttons[index].rawValue
                }
                let slot = settings.shortcutButtons.slots[index]
                guard slot.kind == .builtin else { return Self.customChoice }
                if GrokQuickAction.buttons.contains(where: { $0.rawValue == slot.actionRaw }) {
                    return slot.actionRaw
                }
                return GrokQuickAction.buttons[index].rawValue
            },
            set: { raw in
                var buttons = settings.shortcutButtons
                while buttons.slots.count < IslandShortcutButtons.count {
                    buttons.slots.append(IslandShortcutButtons.default.slots[buttons.slots.count])
                }
                guard buttons.slots.indices.contains(index) else { return }
                if raw == Self.customChoice {
                    buttons.slots[index].kind = .custom
                    if !IslandShortcutSlot.symbolAllowlist.contains(buttons.slots[index].customSymbol) {
                        buttons.slots[index].customSymbol = IslandShortcutSlot.fallbackSymbol
                    }
                } else if let action = GrokQuickAction(rawValue: raw), GrokQuickAction.buttons.contains(action) {
                    buttons.slots[index].kind = .builtin
                    buttons.slots[index].actionRaw = action.rawValue
                }
                settings.shortcutButtons = buttons
            }
        )
    }

    private func stringBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<IslandShortcutSlot, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard settings.shortcutButtons.slots.indices.contains(index) else { return "" }
                return settings.shortcutButtons.slots[index][keyPath: keyPath]
            },
            set: { newValue in
                var buttons = settings.shortcutButtons
                guard buttons.slots.indices.contains(index) else { return }
                buttons.slots[index][keyPath: keyPath] = newValue
                settings.shortcutButtons = buttons
            }
        )
    }
}

/// Model provider, API key, PR repo, permissions, shortcut buttons, the island background, and
/// the desktop shortcut, each as one grouped platter.
struct SettingsPane: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var engine: IslandEngine

    @State private var keyDraft = ""
    @State private var screenAccess = PageCapture.hasScreenRecordingAccess
    @State private var shortcutNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !settings.isModelReady {
                    Text(ModelProviderMessages.settingsHint)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .islandPlatter(tint: IslandChrome.ember)
                }

                IslandGroup("模型") {
                    HStack(spacing: 6) {
                        Text("服务")
                            .font(.system(size: 12))
                        Spacer(minLength: 4)
                        Picker("模型服务", selection: $settings.providerKind) {
                            ForEach(ModelProviderKind.allCases) { kind in
                                Text(kind.settingsTitle).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    .onChange(of: settings.providerKind) { keyDraft = "" }

                    IslandHairline()
                    providerKeySection
                    IslandHairline()
                    providerModelSection

                    if settings.providerKind == .cursor {
                        note("问 Grok、快捷按钮和拆分任务都走 Cursor Cloud Agent。Key 只存在这台 Mac 的 Application Support/GrokIsland 里。")
                    } else {
                        note("问 Grok、三个快捷按钮和拆分任务都用这个服务。截图会一起发过去；模型看不了图片时会直接告诉你，不会偷偷丢掉。")
                        note("想看 Cloud Agent，可以在上面选 Cursor（高级）。没有 Cursor 账号就不用管它。")
                    }
                }

                IslandGroup("PR 仓库") {
                    TextField(IslandSettingsStorage.defaultPRRepo, text: $settings.prRepo)
                        .islandField()
                        .onSubmit { monitor.refreshSoon(minimumAge: 0) }
                    note("用这台 Mac 上已登录的 origin CLI 读取还开着的 PR。")
                }

                IslandGroup("权限") {
                    HStack(spacing: 6) {
                        Text("屏幕录制")
                            .font(.system(size: 12))
                        Spacer(minLength: 4)
                        Text(screenAccess ? "已开启" : "未开启")
                            .font(.system(size: 11))
                            .foregroundStyle(screenAccess ? IslandChrome.positive : IslandChrome.ember)
                    }
                    if !screenAccess {
                        note("快捷按钮要截当前页面。在系统设置里勾选 \(IslandChrome.name)，再重开 app。")
                        Button("打开系统设置") {
                            _ = CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(PageCapture.screenRecordingSettingsURL)
                        }
                        .buttonStyle(.islandPill(compact: true))
                    }
                }

                IslandShortcutSection(settings: settings)

                IslandBackgroundSection(settings: settings)

                IslandGroup("其他") {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("桌面快捷方式")
                                .font(.system(size: 12))
                            Text(shortcutNote ?? "在桌面放一个替身，双击就能打开 \(IslandChrome.name)。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button("放到桌面", action: installDesktopShortcut)
                            .buttonStyle(.islandPill(compact: true))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { screenAccess = PageCapture.hasScreenRecordingAccess }
    }

    private var providerKeySection: some View {
        let kind = settings.providerKind
        let saved = settings.hasSelectedAPIKey
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(kind.keySectionTitle)
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Text(keyStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(keyStatusColor)
            }
            HStack(spacing: 6) {
                SecureField(saved ? "输入新的 key 来替换" : kind.keyPlaceholder, text: $keyDraft)
                    .islandField()
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .buttonStyle(.islandPill(.prominent, compact: true))
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if kind.docsURL != nil || saved {
                HStack(spacing: 4) {
                    if let url = kind.docsURL {
                        Button(kind.docsLinkTitle) { NSWorkspace.shared.open(url) }
                            .buttonStyle(.islandPill(.quiet, compact: true))
                    }
                    Spacer(minLength: 0)
                    if saved {
                        Button("清除") {
                            do { try settings.clearProviderKey() } catch { engine.reportError(error) }
                            monitor.refreshSoon(minimumAge: 0)
                        }
                        .buttonStyle(.islandPill(.destructive, compact: true))
                    }
                }
            }
            if kind == .ollama {
                note("本地 Ollama 一般不用 key。先在这台 Mac 上跑起来，再填下面的模型名。")
            }
        }
    }

    private var keyStatusText: String {
        if settings.providerKind == .ollama {
            return settings.hasSelectedAPIKey ? "已保存" : "可以不填"
        }
        return settings.hasSelectedAPIKey ? "已保存" : "还没填"
    }

    private var keyStatusColor: Color {
        if settings.hasSelectedAPIKey { return IslandChrome.positive }
        if settings.providerKind == .ollama { return Color.secondary }
        return IslandChrome.ember
    }

    private var providerModelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.providerKind.allowsCustomBaseURL {
                Text(settings.providerKind == .ollama ? "Ollama 地址" : "接口地址")
                    .font(.system(size: 12))
                TextField(settings.providerKind.defaultBaseURL, text: $settings.endpointBaseURL)
                    .islandField()
            }
            Text(settings.providerKind == .cursor ? "Grok 模型 ID" : "模型")
                .font(.system(size: 12))
            TextField(settings.providerKind.modelPlaceholder, text: modelBinding)
                .islandField()
        }
    }

    private var modelBinding: Binding<String> {
        if settings.providerKind == .cursor {
            return $settings.grokModelID
        }
        return $settings.providerModelID
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try settings.saveProviderKey(key)
            keyDraft = ""
            monitor.refreshSoon(minimumAge: 0)
        } catch {
            engine.reportError(error)
        }
    }

    private func installDesktopShortcut() {
        do {
            _ = try DesktopShortcut.install()
            shortcutNote = "已经放到桌面：\(DesktopShortcut.aliasName)"
        } catch {
            shortcutNote = error.localizedDescription
            engine.reportError(error)
        }
    }
}
