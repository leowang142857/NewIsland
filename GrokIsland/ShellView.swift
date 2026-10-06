import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Expanded island on the aurora glass. Calls `IslandEngine` only.
///
/// Home is layered top → bottom: per-task status lights → DDL energy bar →
/// Grok function strips → modules / records. Detail screens sit one level deeper.
struct ShellView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings
    @ObservedObject var deadlines: DeadlineStore

    static let dropTypes: [UTType] = [.fileURL, .url, .plainText]

    private enum Route: Equatable {
        case home
        case editor(UUID?)
        case run(UUID)
        case activity
        case settings
    }

    private enum HomeTab: String, CaseIterable, Identifiable {
        case modules
        case records

        var id: String { rawValue }

        var title: String {
            switch self {
            case .modules: "功能模块"
            case .records: "运行记录"
            }
        }
    }

    @State private var route: Route = .home
    @State private var homeTab: HomeTab = .modules
    @State private var draftName = ""
    @State private var draftPrompt = ""
    @State private var draftExecutor: ExecutorKind = .grokBot
    @State private var confirmOpenFiles = true
    @State private var confirmCommand = ""
    @State private var shortcutNote: String?
    @State private var shellDragActive = false
    @State private var dropTargetModuleID: UUID?
    @State private var dropMissNote: String?

    private var isDragging: Bool {
        shellDragActive || presence.isDropTargeted || dropTargetModuleID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            switch route {
            case .home:
                home
            case .editor(let id):
                editor(editingID: id)
            case .run(let id):
                if let run = engine.runs.first(where: { $0.id == id }) {
                    RunDetailView(run: run, engine: engine) {
                        route = .home
                        homeTab = .records
                    }
                } else {
                    home
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
            glow: 0.85,
            emphasized: isDragging,
            background: settings.background,
            imageURL: settings.backgroundImageURL
        )
        .islandFlash(
            RoundedRectangle(cornerRadius: IslandChrome.cornerRadius, style: .continuous),
            trigger: monitor.flashCount
        )
        .onHover { hovering in
            presence.isHoveringPanel = hovering
        }
        // Drops that miss every module tile land here: reject them and say why.
        .onDrop(of: Self.dropTypes, isTargeted: $shellDragActive) { _ in
            showDropMiss()
            return false
        }
        // The peek strip is gone once the island expands mid-drag, so it never reports the
        // drag ending; clear its flag here or the island would stay held open.
        .onChange(of: shellDragActive) {
            if !shellDragActive { presence.isDropTargeted = false }
        }
        .onChange(of: dropTargetModuleID) {
            if dropTargetModuleID == nil, !shellDragActive { presence.isDropTargeted = false }
        }
        .onChange(of: isDragging) {
            guard isDragging else { return }
            withAnimation(IslandChrome.expandSpring) {
                route = .home
                homeTab = .modules
            }
        }
        .onAppear { monitor.refreshSoon() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if case .home = route {
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
                        route = .home
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    Text(routeTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer()

                if engine.activeRunCount > 0 {
                    Button("\(engine.activeRunCount) 运行中") {
                        route = .home
                        homeTab = .records
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else if monitor.snapshot.isBusy, route == .home {
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
                    route = route == .settings ? .home : .settings
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
        case .home: "grok岛"
        case .editor(let id): id == nil ? "新建模块" : "编辑模块"
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

    // MARK: - Home layers

    private var home: some View {
        VStack(alignment: .leading, spacing: 7) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                TaskLightRail(
                    lights: TaskLightBoard.lights(runs: engine.runs, snapshot: monitor.snapshot, now: context.date),
                    onSelect: openLight
                )
            }

            DeadlineEnergyBar(store: deadlines) { error in
                engine.reportError(error)
            }

            GrokQuickBar(engine: engine, settings: settings) { id in route = .run(id) }
            lastAnswerStrip

            layerRule
            layerTabs

            switch homeTab {
            case .modules:
                moduleLayer
            case .records:
                RunJournalList(engine: engine) { id in route = .run(id) }
            }
        }
    }

    private var layerRule: some View {
        Rectangle()
            .fill(IslandChrome.layerRule)
            .frame(height: 1)
            .allowsHitTesting(false)
    }

    /// Latest Grok answer, one tap from the home screen even after the island retracted.
    @ViewBuilder
    private var lastAnswerStrip: some View {
        if let last = engine.runs.first(where: { $0.origin != .module && $0.origin != .splitSubtask }) {
            Button {
                route = .run(last.id)
            } label: {
                HStack(spacing: 5) {
                    TaskLightDot(state: TaskLightBoard.state(for: last.phase), size: 5)
                    Text("上次：\(last.question ?? last.moduleName)")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Text(last.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重新打开这条 Grok 回答")
        }
    }

    private var layerTabs: some View {
        HStack(spacing: 10) {
            ForEach(HomeTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { homeTab = tab }
                } label: {
                    HStack(spacing: 3) {
                        Text(tab.title)
                        if tab == .records, !engine.runs.isEmpty {
                            Text("\(engine.runs.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(homeTab == tab ? .semibold : .regular))
                    .foregroundStyle(homeTab == tab ? IslandChrome.neonCyan : Color.secondary)
                    .padding(.bottom, 3)
                    .overlay(alignment: .bottom) {
                        if homeTab == tab {
                            Capsule()
                                .fill(IslandChrome.neonCyan)
                                .frame(height: 1.5)
                                .shadow(color: IslandChrome.neonCyan.opacity(0.8), radius: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if homeTab == .modules {
                Button {
                    beginCreate()
                } label: {
                    Label("新建模块", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var moduleLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isDragging || dropMissNote != nil {
                dropBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(engine.modules) { module in
                            ModuleTile(
                                module: module,
                                engine: engine,
                                onOpen: { beginEdit(module) },
                                onTargetChange: { targeted in updateDropTarget(module.id, targeted: targeted) }
                            )
                        }
                    }
                    .padding(2)
                }
                if !isDragging {
                    Text("把文件 / 链接拖到方块上，松手即用该模块执行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .animation(IslandChrome.expandSpring, value: isDragging)
    }

    /// Tells the user where a drag will go before they let go.
    private var dropBanner: some View {
        let target = dropTargetModuleID.flatMap { id in engine.modules.first { $0.id == id } }
        let missed = dropMissNote != nil && !isDragging
        let tint = missed ? IslandChrome.alertRed : (target == nil ? IslandChrome.neonCyan : IslandChrome.electricGreen)
        return HStack(spacing: 6) {
            Image(systemName: missed ? "xmark.octagon.fill" : (target == nil ? "hand.point.down.fill" : "tray.and.arrow.down.fill"))
                .font(.caption)
            if missed, let dropMissNote {
                Text(dropMissNote)
                    .font(.caption2.weight(.semibold))
            } else if let target {
                Text("松手发送到「\(target.displayName)」")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Text(target.executor == .grokBot ? "→ Grok 解答" : "→ 本机执行（需确认）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("拖到下面的模块方块上，松手即执行")
                    .font(.caption2.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: target == nil ? [4, 3] : []))
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
                            route = .home
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

    private func openLight(_ light: TaskLight) {
        if let runID = light.runID, engine.runs.contains(where: { $0.id == runID }) {
            route = .run(runID)
        } else if let link = light.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        } else {
            route = .activity
        }
    }

    private func updateDropTarget(_ moduleID: UUID, targeted: Bool) {
        if targeted {
            dropTargetModuleID = moduleID
            dropMissNote = nil
        } else if dropTargetModuleID == moduleID {
            dropTargetModuleID = nil
        }
    }

    private func showDropMiss() {
        let note = "没放到模块方块上，这次没有发送"
        withAnimation { dropMissNote = note }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if dropMissNote == note {
                withAnimation { dropMissNote = nil }
            }
        }
    }

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
            route = .home
        } catch {
            engine.reportError(error)
        }
    }
}

/// Square module tile. Click opens the editor; dropping resources runs the module.
///
/// While a drag hovers it the tile lifts and says where the drop goes; after the drop it
/// shows reading → sent / rejected, then the module's latest run light.
struct ModuleTile: View {
    let module: FunctionModule
    @ObservedObject var engine: IslandEngine
    let onOpen: () -> Void
    var onTargetChange: (Bool) -> Void = { _ in }

    private enum DropFeedback: Equatable {
        case idle
        case loading
        case sent(Int)
        case rejected(String)
    }

    @State private var targeted = false
    @State private var feedback: DropFeedback = .idle

    private var latestRun: RunRecord? {
        guard let run = engine.runs.first(where: { $0.moduleID == module.id }) else { return nil }
        if run.isActive || Date().timeIntervalSince(run.updatedAt) < TaskLightBoard.recentWindow {
            return run
        }
        return nil
    }

    private var borderColor: Color {
        if targeted { return IslandChrome.neonCyan }
        switch feedback {
        case .loading: return IslandChrome.neonCyan
        case .sent: return IslandChrome.electricGreen
        case .rejected: return IslandChrome.alertRed
        case .idle: return IslandChrome.neonCyan.opacity(0.28)
        }
    }

    var body: some View {
        Button(action: onOpen) {
            tileContent
        }
        .buttonStyle(.plain)
        .scaleEffect(targeted ? 1.05 : 1)
        .shadow(color: borderColor.opacity(targeted || feedback != .idle ? 0.8 : 0), radius: targeted ? 8 : 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
        .animation(.easeInOut(duration: 0.2), value: feedback)
        .help(module.executor == .grokBot ? "点击编辑 · 拖入文件 / 链接交给 Grok" : "点击编辑 · 拖入文件在本机执行（需确认）")
        .onDrop(of: ShellView.dropTypes, isTargeted: $targeted) { providers in
            feedback = .loading
            engine.ingestDropProviders(providers, assignTo: module.id) { outcome in
                switch outcome {
                case .started(_, let count):
                    show(.sent(count))
                case .rejected(let message):
                    show(.rejected(message))
                }
            }
            return true
        }
        .onChange(of: targeted) {
            onTargetChange(targeted)
        }
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: module.executor == .grokBot ? "sparkles" : "desktopcomputer")
                    .font(.caption2)
                Text(module.executor.title)
                    .font(.caption2)
                Spacer(minLength: 0)
                if let latestRun {
                    TaskLightDot(state: TaskLightBoard.state(for: latestRun.phase), size: 6)
                        .help("最近一次：\(latestRun.message)")
                }
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
        .overlay {
            if targeted {
                dropPrompt
            } else if feedback != .idle {
                feedbackBadge
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: targeted || feedback != .idle ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var dropPrompt: some View {
        VStack(spacing: 3) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title3)
            Text(module.executor == .grokBot ? "松手发给 Grok" : "松手本机执行")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(IslandChrome.neonCyan)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        switch feedback {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("读取中…")
            }
            .modifier(TileBadgeStyle(tint: IslandChrome.neonCyan))
        case .sent(let count):
            Label("已发送 \(count) 项", systemImage: "checkmark.circle.fill")
                .modifier(TileBadgeStyle(tint: IslandChrome.electricGreen))
        case .rejected(let message):
            Label("没发出去", systemImage: "xmark.octagon.fill")
                .modifier(TileBadgeStyle(tint: IslandChrome.alertRed))
                .help(message)
        }
    }

    private func show(_ next: DropFeedback) {
        feedback = next
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if feedback == next {
                feedback = .idle
            }
        }
    }
}

private struct TileBadgeStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.8), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 6)
    }
}
