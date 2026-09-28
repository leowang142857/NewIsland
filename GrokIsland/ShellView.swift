import SwiftUI
import UniformTypeIdentifiers

/// Functional shell on the aurora glass. Calls `IslandEngine` only.
struct ShellView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings

    private enum Route: Equatable {
        case modules
        case editor(UUID?)
        case runs
        case run(UUID)
        case activity
        case settings
    }

    @State private var route: Route = .modules
    @State private var draftName = ""
    @State private var draftPrompt = ""
    @State private var draftExecutor: ExecutorKind = .grokBot
    @State private var confirmOpenFiles = true
    @State private var confirmCommand = ""
    @State private var shortcutNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            switch route {
            case .modules:
                moduleGrid
            case .editor(let id):
                editor(editingID: id)
            case .runs:
                runsList
            case .run(let id):
                if let run = engine.runs.first(where: { $0.id == id }) {
                    RunDetailView(run: run, engine: engine)
                } else {
                    runsList
                }
            case .activity:
                ActivityListView(monitor: monitor) { route = .settings }
            case .settings:
                SettingsPane(settings: settings, monitor: monitor, engine: engine)
            }
            if engine.pendingLocal != nil {
                localConfirm
            }
            if let error = engine.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .islandChrome(
            RoundedRectangle(cornerRadius: IslandChrome.cornerRadius, style: .continuous),
            glow: 0.85
        )
        .islandFlash(
            RoundedRectangle(cornerRadius: IslandChrome.cornerRadius, style: .continuous),
            trigger: monitor.flashCount
        )
        .onHover { hovering in
            presence.isHoveringPanel = hovering
        }
        .onAppear { monitor.refreshSoon() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if case .modules = route {
                    Button {
                        route = .activity
                    } label: {
                        HStack(spacing: 5) {
                            ActivityLight(
                                busy: monitor.snapshot.isBusy || engine.activeRunCount > 0,
                                warning: monitor.snapshot.hasFailingChecks
                            )
                            Text("grok岛")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(activityHelp)
                } else {
                    Button {
                        route = .modules
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    Text(routeTitle)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                if engine.activeRunCount > 0 {
                    Button("\(engine.activeRunCount) 运行中") { route = .runs }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if monitor.snapshot.isBusy, route == .modules {
                    Button {
                        route = .activity
                    } label: {
                        Text(cloudBadge)
                            .font(.caption2.monospacedDigit())
                    }
                    .buttonStyle(.borderless)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    route = route == .settings ? .modules : .settings
                } label: {
                    Image(systemName: settings.hasAPIKey ? "gearshape" : "gearshape.fill")
                        .foregroundStyle(settings.hasAPIKey ? Color.primary : Color.orange)
                }
                .buttonStyle(.borderless)
                .help(settings.hasAPIKey ? "设置" : "设置：还没填 Cursor API key")
                Button {
                    presence.isPinned.toggle()
                } label: {
                    Image(systemName: presence.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(presence.isPinned ? "取消钉住" : "钉住，不自动收起")
                Button(action: installDesktopShortcut) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                }
                .buttonStyle(.borderless)
                .help("在桌面创建快捷方式")
            }
            if let shortcutNote {
                Text(shortcutNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Slight extra side inset so the top-row middle stays away from the notch column.
        .padding(.horizontal, 6)
    }

    private var routeTitle: String {
        switch route {
        case .modules: "grok岛"
        case .editor(let id): id == nil ? "新建模块" : "编辑模块"
        case .runs: "运行状态"
        case .run(let id): engine.runs.first(where: { $0.id == id })?.moduleName ?? "运行结果"
        case .activity: "Cloud Agent · PR"
        case .settings: "设置"
        }
    }

    private var cloudBadge: String {
        let snapshot = monitor.snapshot
        return [
            snapshot.agents.isEmpty ? nil : "☁︎\(snapshot.agents.count)",
            snapshot.pullRequests.isEmpty ? nil : "PR\(snapshot.pullRequests.count)"
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private var activityHelp: String {
        let snapshot = monitor.snapshot
        guard snapshot.isBusy || engine.activeRunCount > 0 else { return "没有在跑的 Agent / PR，点开看详情" }
        return "Cloud Agent \(snapshot.agents.count) · PR \(snapshot.pullRequests.count) · 本地 \(engine.activeRunCount)"
    }

    // MARK: - Modules

    private var moduleGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            GrokQuickBar(engine: engine) { id in route = .run(id) }
            Divider()
            HStack {
                Text("功能模块")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    beginCreate()
                } label: {
                    Label("新建模块", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if engine.modules.isEmpty {
                VStack(spacing: 6) {
                    Text("创建你的第一个功能模块")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("新建模块") { beginCreate() }
                        .controlSize(.small)
                    Button("载入示例") { engine.loadDemoModules(overwrite: false) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(engine.modules) { module in
                            ModuleTile(
                                module: module,
                                engine: engine,
                                onOpen: { beginEdit(module) }
                            )
                        }
                    }
                }
                Text("把文件拖到方块上即可用该模块执行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !engine.runs.isEmpty {
                Button("查看运行状态") { route = .runs }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    // MARK: - Editor

    private func editor(editingID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("名称（翻译 / 整理笔记 / 跑脚本）", text: $draftName)
                .textFieldStyle(.roundedBorder)
            TextField("提示词 / 配置", text: $draftPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            Picker("", selection: $draftExecutor) {
                ForEach(ExecutorKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Button(editingID == nil ? "创建" : "保存") {
                    saveDraft(editingID: editingID)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)

                if let editingID {
                    Button("删除", role: .destructive) {
                        do {
                            try engine.deleteModule(id: editingID)
                            route = .modules
                        } catch {
                            engine.reportError(error)
                        }
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Runs

    private var runsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button("清理已完成") { engine.clearFinishedRuns() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if engine.runs.isEmpty {
                Text("暂无运行记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.runs.prefix(12)) { run in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(run.moduleName)
                                        .font(.caption.weight(.medium))
                                    Text(run.phase.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if run.isActive {
                                        Button("取消") { engine.cancelRun(id: run.id) }
                                            .buttonStyle(.borderless)
                                            .font(.caption2)
                                    }
                                }
                                if run.phase == .running {
                                    ProgressView(value: run.progress)
                                }
                                Text(run.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { route = .run(run.id) }
                            .help("点开看完整结果")
                        }
                    }
                }
            }
        }
    }

    private var localConfirm: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pending = engine.pendingLocal {
                Text("确认本地执行：\(pending.module.displayName)")
                    .font(.caption.weight(.semibold))
                Text("提示词不会当作命令执行；只有下面填写并确认的命令才会运行。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("用默认应用打开附加文件", isOn: $confirmOpenFiles)
                    .font(.caption)
                TextField("可选：确认执行的 zsh 命令（留空则不执行命令）", text: $confirmCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                HStack {
                    Button("取消") {
                        engine.cancelPendingLocal()
                        confirmCommand = ""
                    }
                    .controlSize(.small)
                    Button("确认执行") {
                        do {
                            try engine.confirmPendingLocal(
                                openAttachedFiles: confirmOpenFiles,
                                shellCommand: confirmCommand
                            )
                            confirmCommand = ""
                        } catch {
                            engine.reportError(error)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Actions

    private func beginCreate() {
        draftName = ""
        draftPrompt = ""
        draftExecutor = .grokBot
        route = .editor(nil)
    }

    private func beginEdit(_ module: FunctionModule) {
        draftName = module.name
        draftPrompt = module.prompt
        draftExecutor = module.executor
        route = .editor(module.id)
    }

    private func installDesktopShortcut() {
        do {
            _ = try DesktopShortcut.install()
            shortcutNote = "已放到桌面：grok岛"
        } catch {
            shortcutNote = error.localizedDescription
            engine.reportError(error)
        }
    }

    private func saveDraft(editingID: UUID?) {
        do {
            if let editingID, var existing = engine.modules.first(where: { $0.id == editingID }) {
                existing.name = draftName
                existing.prompt = draftPrompt
                existing.executor = draftExecutor
                _ = try engine.updateModule(existing)
            } else {
                _ = try engine.createModule(
                    name: draftName,
                    prompt: draftPrompt,
                    executor: draftExecutor
                )
            }
            route = .modules
        } catch {
            engine.reportError(error)
        }
    }
}

/// Square module tile. Click opens the editor; dropping resources runs the module.
struct ModuleTile: View {
    let module: FunctionModule
    @ObservedObject var engine: IslandEngine
    let onOpen: () -> Void

    @State private var targeted = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: module.executor == .grokBot ? "sparkles" : "desktopcomputer")
                        .font(.caption2)
                    Text(module.executor.title)
                        .font(.caption2)
                    Spacer()
                }
                .foregroundStyle(.secondary)

                Text(module.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                if !module.prompt.isEmpty {
                    Text(module.prompt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(7)
            .frame(height: 78)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(targeted ? IslandChrome.neonCyan.opacity(0.16) : Color.white.opacity(0.05))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        targeted ? IslandChrome.neonCyan : IslandChrome.neonCyan.opacity(0.28),
                        lineWidth: targeted ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help("点击编辑 · 拖入资源以执行")
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: $targeted) { providers in
            engine.ingestDropProviders(providers, assignTo: module.id)
            return true
        }
    }
}
