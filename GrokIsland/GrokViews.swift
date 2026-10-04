import AppKit
import SwiftUI

/// Three shortcut buttons plus a free-form question, all about the frontmost page.
struct GrokQuickBar: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var settings: IslandSettings
    let onStarted: (UUID) -> Void

    @State private var question = ""
    @State private var capturing = false
    @State private var note: String?

    private var shortcuts: [ResolvedIslandShortcut] {
        settings.shortcutButtons.resolved()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ForEach(shortcuts.indices, id: \.self) { index in
                    shortcutButton(shortcuts[index])
                }
            }

            HStack(spacing: 4) {
                TextField("问 Grok（附当前页截图）", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { fireAsk() }
                if capturing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        fireAsk()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    private func shortcutButton(_ shortcut: ResolvedIslandShortcut) -> some View {
        Button {
            fire(shortcut)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: shortcut.symbolName)
                    .font(.caption)
                Text(shortcut.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(IslandChrome.neonCyan.opacity(0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(IslandChrome.neonCyan.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(capturing || !shortcut.isReady)
        .help("截当前最前面的页面，交给 Grok \(shortcut.title)")
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
                HStack(alignment: .top, spacing: 5) {
                    Text("问")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(IslandChrome.neonCyan)
                    Text(question)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(IslandChrome.neonCyan.opacity(0.08))
                }
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
                        Text("Grok 答完后结果会显示在这里。云端 Agent 启动一般要几十秒。")
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line):
                    inline(line)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(IslandChrome.neonCyan)
                        .padding(.top, 2)
                case .paragraph(let line):
                    inline(line)
                        .font(.caption)
                case .code(let code):
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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

/// Cursor API key, Grok model, PR repo, permissions, shortcut buttons, and the island background.
struct SettingsPane: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var engine: IslandEngine

    @State private var keyDraft = ""
    @State private var screenAccess = PageCapture.hasScreenRecordingAccess

    private static let apiKeysURL = URL(string: "https://cursor.com/dashboard/api")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Cursor API key")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(settings.hasAPIKey ? "已保存" : "未设置")
                            .font(.caption2)
                            .foregroundStyle(settings.hasAPIKey ? IslandChrome.electricGreen : .orange)
                    }
                    HStack(spacing: 4) {
                        SecureField(settings.hasAPIKey ? "输入新 key 替换" : "crsr_…", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit(saveKey)
                        Button("保存", action: saveKey)
                            .controlSize(.small)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack {
                        Button("获取 API key") { NSWorkspace.shared.open(Self.apiKeysURL) }
                            .buttonStyle(.borderless)
                        if settings.hasAPIKey {
                            Button("清除", role: .destructive) {
                                do { try settings.clearAPIKey() } catch { engine.reportError(error) }
                                monitor.refreshSoon(minimumAge: 0)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.caption2)
                    note("用来看 Cloud Agent 进度，也用来让 Grok 解答。只存在本机 Application Support/GrokIsland。")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Grok 模型 ID")
                        .font(.caption.weight(.semibold))
                    TextField("留空：自动选一个 Grok 模型", text: $settings.grokModelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
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
                            .foregroundStyle(screenAccess ? IslandChrome.electricGreen : .orange)
                    }
                    if !screenAccess {
                        Button("打开系统设置") {
                            _ = CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(PageCapture.screenRecordingSettingsURL)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        note("快捷按钮要截当前页面。勾选 grok岛 后重开 app。")
                    }
                }

                Rectangle()
                    .fill(IslandChrome.layerRule)
                    .frame(height: 1)

                IslandShortcutSection(settings: settings)

                Rectangle()
                    .fill(IslandChrome.layerRule)
                    .frame(height: 1)

                IslandBackgroundSection(settings: settings)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { screenAccess = PageCapture.hasScreenRecordingAccess }
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
            try settings.saveAPIKey(key)
            keyDraft = ""
            monitor.refreshSoon(minimumAge: 0)
        } catch {
            engine.reportError(error)
        }
    }
}
