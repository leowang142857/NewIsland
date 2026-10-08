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
    @State private var splitting = false
    @State private var splitTargeted = false
    @State private var note: String?

    private var shortcuts: [ResolvedIslandShortcut] {
        settings.shortcutButtons.resolved()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    ShortcutButton(shortcut: shortcuts[index], disabled: capturing) {
                        fire(shortcuts[index])
                    }
                }
            }

            inputRow(
                "问 Grok，会附上当前页面截图",
                text: $question,
                busy: capturing,
                symbol: "arrow.up",
                help: "发送",
                submit: fireAsk
            )

            inputRow(
                "拆分一个大任务，也可以把文件拖进来",
                text: $splitDraft,
                busy: splitting,
                symbol: "arrow.triangle.branch",
                help: "拆成 2–4 个子任务并行执行，完成后汇总成一条结果",
                highlighted: splitTargeted,
                submit: { fireSplit() }
            )
            .onDrop(of: ShellView.dropTypes, isTargeted: $splitTargeted) { providers in
                fireSplitDrop(providers)
                return true
            }

            if splitTargeted {
                Text("松手后拆成 2–4 个子任务，各自跑完再汇总")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandChrome.ember)
                    .lineLimit(3)
            }
        }
    }

    /// Text field with its action tucked inside the trailing edge.
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
            .padding(.trailing, 22)
            .islandField(highlighted: highlighted)
            .overlay(alignment: .trailing) {
                Group {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(action: submit) {
                            Image(systemName: symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(empty ? Color.white.opacity(0.3) : IslandChrome.ink)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(empty ? Color.clear : Color.white.opacity(0.9)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(empty)
                        .help(help)
                    }
                }
                .padding(.trailing, 4)
            }
    }

    private func fire(_ shortcut: ResolvedIslandShortcut) {
        guard !capturing, shortcut.isReady else { return }
        capturing = true
        note = nil
        Task { @MainActor in
            let page = await PageCapture.snapshot()
            capturing = false
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

private struct ShortcutButton: View {
    let shortcut: ResolvedIslandShortcut
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: shortcut.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(shortcut.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? IslandChrome.surfaceRaised : IslandChrome.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(disabled || !shortcut.isReady)
        .opacity(shortcut.isReady ? 1 : 0.45)
        .help("截当前最前面的页面，交给 Grok \(shortcut.title)")
    }
}

/// Full answer for one run, with copy / open-in-Cursor / delete. Answers stay in the journal.
struct RunDetailView: View {
    let run: RunRecord
    @ObservedObject var engine: IslandEngine
    var onDeleted: () -> Void = {}

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TaskLightDot(state: TaskLightBoard.state(for: run.phase), size: 6)
                Text(phaseTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(run.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if run.isActive {
                    Button("取消") { engine.cancelRun(id: run.id) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                if let answer = run.resultSummary, !run.isActive {
                    Button(copied ? "已拷贝" : "拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
                if let link = run.link, let url = URL(string: link) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Cursor 打开这个 Cloud Agent，可继续追问")
                }
                Button {
                    engine.deleteRuns(ids: [run.id])
                    onDeleted()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(run.isActive ? "取消并删除这条记录" : "删除这条记录")
            }

            if let question = run.question {
                Text(question)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 2)
                    }
                    .padding(.vertical, 2)
            }

            if run.isActive {
                ProgressView(value: run.progress)
                Text(run.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Group {
                    if let answer = run.resultSummary, !run.isActive {
                        MarkdownLite(text: answer)
                    } else if run.isActive {
                        Text(run.origin == .splitTask
                            ? "正在把任务拆开并行执行。每个子任务有自己的任务灯，全部结束后汇总显示在这里。"
                            : "答完后结果会显示在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(run.phase == .cancelled ? "已取消，没有结果。" : run.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private var phaseTitle: String {
        switch run.phase {
        case .queued: "排队中"
        case .awaitingConfirmation: "等待确认"
        case .running: "运行中"
        case .succeeded: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line):
                    inline(line)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 4)
                case .paragraph(let line):
                    inline(line)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                case .code(let code):
                    Text(code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IslandChrome.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("快捷按钮")
                    .font(.caption.weight(.semibold))
                Spacer()
                if settings.shortcutButtons != .default {
                    Button("重置") { settings.shortcutButtons = .default }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .help("三个按钮回到整理错题、解答题目、检查代码。")
                }
            }

            ForEach(0..<IslandShortcutButtons.count, id: \.self) { index in
                slotEditor(index)
            }

            Text("点按钮仍会截当前最前面的页面交给 Grok。没改过就还是整理错题、解答题目、检查代码。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slotEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("按钮 \(index + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("", selection: choiceBinding(index)) {
                    ForEach(GrokQuickAction.buttons) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                    Text("自定义").tag(Self.customChoice)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                Spacer(minLength: 0)
            }

            if isCustom(index) {
                TextField("按钮名称", text: stringBinding(index, \.customTitle))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                TextField("交给 Grok 的提示词", text: stringBinding(index, \.customPrompt), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(2...4)
                HStack(spacing: 6) {
                    Text("图标")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("", selection: stringBinding(index, \.customSymbol)) {
                        ForEach(IslandShortcutSlot.symbolAllowlist, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer(minLength: 0)
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

/// Model provider, API key, PR repo, permissions, shortcut buttons, and the island background.
struct SettingsPane: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var engine: IslandEngine

    @State private var keyDraft = ""
    @State private var screenAccess = PageCapture.hasScreenRecordingAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !settings.isModelReady {
                    note(ModelProviderMessages.settingsHint)
                }

                HStack {
                    Text("模型服务")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker("模型服务", selection: $settings.providerKind) {
                        ForEach(ModelProviderKind.allCases) { kind in
                            Text(kind.settingsTitle).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.caption)
                }
                .onChange(of: settings.providerKind) { keyDraft = "" }

                providerKeySection
                providerModelSection

                if settings.providerKind == .cursor {
                    note("问 Grok、快捷按钮和拆分任务走 Cursor Cloud Agent。Key 只存在本机 Application Support/GrokIsland。")
                } else {
                    note("问 Grok、三个快捷按钮和拆分任务都走这里。截图会一并送出；模型若不支持图片，会明确失败，不会悄悄丢掉。")
                    note("Cursor（高级）仍可在上面的菜单里选，用来看 Cloud Agent。没有 Cursor 账号可以不用。")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("PR 仓库")
                        .font(.caption.weight(.semibold))
                    TextField(IslandSettingsStorage.defaultPRRepo, text: $settings.prRepo)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { monitor.refreshSoon(minimumAge: 0) }
                    note("通过本机已登录的 origin CLI 读取开着的 PR。")
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("屏幕录制权限")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(screenAccess ? "已开启" : "未开启")
                            .font(.caption2)
                            .foregroundStyle(screenAccess ? IslandChrome.positive : IslandChrome.ember)
                    }
                    if !screenAccess {
                        Button("打开系统设置") {
                            _ = CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(PageCapture.screenRecordingSettingsURL)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        note("快捷按钮要截当前页面。勾选 \(IslandChrome.name) 后重开 app。")
                    }
                }

                IslandHairline()
                    .padding(.vertical, 2)

                IslandShortcutSection(settings: settings)

                IslandHairline()
                    .padding(.vertical, 2)

                IslandBackgroundSection(settings: settings)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { screenAccess = PageCapture.hasScreenRecordingAccess }
    }

    private var providerKeySection: some View {
        let kind = settings.providerKind
        let saved = settings.hasSelectedAPIKey
        let optional = kind == .ollama
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kind.keySectionTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(keyStatusText)
                    .font(.caption2)
                    .foregroundStyle(keyStatusColor)
            }
            HStack(spacing: 4) {
                SecureField(saved ? "输入新 key 替换" : kind.keyPlaceholder, text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if let url = kind.docsURL {
                    Button(kind.docsLinkTitle) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                }
                if saved {
                    Button("清除", role: .destructive) {
                        do { try settings.clearProviderKey() } catch { engine.reportError(error) }
                        monitor.refreshSoon(minimumAge: 0)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption2)
            if optional {
                note("本地 Ollama 通常不需要 key。先在本机跑起来，再填写下面的模型名。")
            }
        }
    }

    private var keyStatusText: String {
        if settings.providerKind == .ollama {
            return settings.hasSelectedAPIKey ? "已保存" : "可不填"
        }
        return settings.hasSelectedAPIKey ? "已保存" : "未设置"
    }

    private var keyStatusColor: Color {
        if settings.hasSelectedAPIKey { return IslandChrome.positive }
        if settings.providerKind == .ollama { return Color.secondary }
        return IslandChrome.ember
    }

    private var providerModelSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if settings.providerKind.allowsCustomBaseURL {
                Text(settings.providerKind == .ollama ? "Ollama 地址" : "接口地址")
                    .font(.caption.weight(.semibold))
                TextField(settings.providerKind.defaultBaseURL, text: $settings.endpointBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text(settings.providerKind == .cursor ? "Grok 模型 ID" : "模型")
                .font(.caption.weight(.semibold))
            TextField(settings.providerKind.modelPlaceholder, text: modelBinding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
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
            .font(.caption2)
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
}
