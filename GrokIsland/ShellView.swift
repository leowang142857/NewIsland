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
    @ObservedObject var tray: FileTray

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
        case tray
        case records

        var id: String { rawValue }

        var title: String {
            switch self {
            case .modules: "功能模块"
            case .tray: TrayPath.rootTitle
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
    @State private var trayDragActive = false
    @State private var traySlotTargeted = false
    @State private var trayTabTargeted = false

    private var isDragging: Bool {
        shellDragActive || presence.isDropTargeted || dropTargetModuleID != nil
            || trayDragActive || traySlotTargeted || trayTabTargeted
    }

    /// Something from outside is being dragged in. Dragging files out of the tray does not count.
    private var isReceivingFiles: Bool {
        isDragging && !tray.isDraggingOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
                    .font(.system(size: 11))
                    .foregroundStyle(IslandChrome.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .islandChrome(
            RoundedRectangle(cornerRadius: IslandChrome.cornerRadius, style: .continuous),
            glow: 0.85,
            emphasized: isReceivingFiles,
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
        // Drops that miss every module tile (or the tray) land here: reject them and say why.
        .onDrop(of: Self.dropTypes, isTargeted: $shellDragActive) { _ in
            if tray.isDraggingOut {
                return false
            }
            if homeTab == .tray, route == .home {
                tray.post("没落在暂存区里，这次什么也没放进来", problem: true)
            } else {
                showDropMiss()
            }
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
        // A drag brings up something that takes files: the modules, or the tray if it is open.
        .onChange(of: isReceivingFiles) {
            guard isReceivingFiles else { return }
            withAnimation(IslandChrome.expandSpring) {
                route = .home
                if homeTab == .records { homeTab = .modules }
            }
        }
        // Spring-loaded like a Finder folder: hold a drag on 暂存 and the tray opens.
        .onChange(of: trayTabTargeted) {
            guard trayTabTargeted, homeTab != .tray else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if trayTabTargeted, homeTab != .tray {
                    withAnimation(.easeInOut(duration: 0.15)) { homeTab = .tray }
                }
            }
        }
        .onAppear {
            monitor.refreshSoon()
            tray.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if case .home = route {
                    Button {
                        route = .activity
                    } label: {
                        HStack(spacing: 6) {
                            ActivityLight(
                                busy: monitor.snapshot.isBusy || engine.activeRunCount > 0,
                                warning: monitor.snapshot.hasFailingChecks,
                                size: 6
                            )
                            Text(IslandChrome.name)
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(activityHelp)
                } else {
                    Button {
                        route = .home
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text(routeTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("返回")
                }

                Spacer()

                if engine.activeRunCount > 0 {
                    Button("\(engine.activeRunCount) 个在跑") {
                        route = .home
                        homeTab = .records
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandChrome.positive)
                } else if monitor.snapshot.isBusy, route == .home {
                    Button {
                        route = .activity
                    } label: {
                        Text(cloudBadge)
                            .font(.system(size: 11).monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    headerIcon(
                        settings.isModelReady ? "gearshape" : "gearshape.fill",
                        tint: settings.isModelReady ? nil : IslandChrome.ember,
                        help: settings.isModelReady ? "设置" : ModelProviderMessages.gearHelp
                    ) {
                        route = route == .settings ? .home : .settings
                    }
                    headerIcon(
                        presence.isPinned ? "pin.fill" : "pin",
                        tint: presence.isPinned ? .primary : nil,
                        help: presence.isPinned ? "取消钉住" : "钉住，不自动收起"
                    ) {
                        presence.isPinned.toggle()
                    }
                    headerIcon("menubar.arrow.up.rectangle", help: "在桌面创建快捷方式", action: installDesktopShortcut)
                }
            }
            if let shortcutNote {
                Text(shortcutNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: shortcutNote == nil ? 24 : nil)
    }

    private func headerIcon(
        _ symbol: String,
        tint: Color? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var routeTitle: String {
        switch route {
        case .home: IslandChrome.name
        case .editor(let id): id == nil ? "新建模块" : "编辑模块"
        case .run(let id): engine.runs.first(where: { $0.id == id })?.moduleName ?? "运行结果"
        case .activity: "Cloud Agent · PR"
        case .settings: "设置"
        }
    }

    private var cloudBadge: String {
        let snapshot = monitor.snapshot
        return [
            snapshot.agents.isEmpty ? nil : "Agent \(snapshot.agents.count)",
            snapshot.pullRequests.isEmpty ? nil : "PR \(snapshot.pullRequests.count)"
        ]
        .compactMap { $0 }
        .joined(separator: "  ")
    }

    private var activityHelp: String {
        let snapshot = monitor.snapshot
        guard snapshot.isBusy || engine.activeRunCount > 0 else { return "没有在跑的 Agent / PR，点开看详情" }
        return "Cloud Agent \(snapshot.agents.count) · PR \(snapshot.pullRequests.count) · 本地 \(engine.activeRunCount)"
    }

    // MARK: - Home layers

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                TaskLightRail(
                    lights: TaskLightBoard.lights(runs: engine.runs, snapshot: monitor.snapshot, now: context.date),
                    onSelect: openLight
                )
            }

            DeadlineEnergyBar(store: deadlines) { error in
                engine.reportError(error)
            }

            VStack(alignment: .leading, spacing: 6) {
                GrokQuickBar(engine: engine, settings: settings) { id in route = .run(id) }
                lastAnswerStrip
            }

            IslandHairline()
            layerTabs

            switch homeTab {
            case .modules:
                moduleLayer
            case .tray:
                FileTrayLayer(tray: tray, dragActive: $trayDragActive)
            case .records:
                RunJournalList(engine: engine) { id in route = .run(id) }
            }
        }
    }

    /// Latest Grok answer, one tap from the home screen even after the island retracted.
    @ViewBuilder
    private var lastAnswerStrip: some View {
        if let last = engine.runs.first(where: { $0.origin != .module && $0.origin != .splitSubtask }) {
            Button {
                route = .run(last.id)
            } label: {
                HStack(spacing: 6) {
                    TaskLightDot(state: TaskLightBoard.state(for: last.phase), size: 5)
                    Text("上次")
                        .foregroundStyle(.tertiary)
                    Text(last.question ?? last.moduleName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重新打开这条 Grok 回答")
        }
    }

    private var layerTabs: some View {
        HStack(spacing: 14) {
            ForEach(HomeTab.allCases) { tab in
                if tab == .tray {
                    tabButton(tab)
                        .onDrop(of: TrayDrop.types, delegate: TrayDropTarget(
                            targeted: $trayTabTargeted,
                            operation: { TrayDrop.proposal(into: "", tray: tray) },
                            perform: { providers in
                                showTray()
                                return TrayDrop.accept(providers, into: "", tray: tray)
                            }
                        ))
                        .help("拖进来先放着，要用时再拖回桌面")
                } else {
                    tabButton(tab)
                }
            }
            Spacer()
            if homeTab == .modules {
                Button {
                    beginCreate()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("新建")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建模块")
            }
        }
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        let selected = homeTab == tab
        let targeted = tab == .tray && trayTabTargeted
        let count: Int? = switch tab {
        case .modules: nil
        case .tray: tray.rootCount
        case .records: engine.runs.count
        }
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { homeTab = tab }
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
                    .foregroundStyle(targeted ? IslandChrome.accent : (selected ? Color.primary : Color.secondary))
                if let count, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showTray() {
        tray.open("")
        withAnimation(.easeInOut(duration: 0.15)) { homeTab = .tray }
    }

    private var moduleLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isDragging || dropMissNote != nil {
                dropBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if engine.modules.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有模块。模块是一段固定的提示词，把文件拖上去就按它来处理。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("新建模块") { beginCreate() }
                            .controlSize(.small)
                        Button("先放几个示例") { engine.loadDemoModules(overwrite: false) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(IslandChrome.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)
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
            }

            if isReceivingFiles {
                TrayDropSlot(tray: tray, targeted: $traySlotTargeted, onDropped: showTray)
                    .transition(.opacity)
            } else if !engine.modules.isEmpty {
                Text("把文件或链接拖到模块上就会执行")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(IslandChrome.expandSpring, value: isDragging)
    }

    /// Tells the user where a drag will go before they let go.
    private var dropBanner: some View {
        let target = dropTargetModuleID.flatMap { id in engine.modules.first { $0.id == id } }
        let missed = dropMissNote != nil && !isDragging
        let tint = missed ? IslandChrome.danger : (target == nil ? Color.secondary : IslandChrome.accent)
        return HStack(spacing: 6) {
            if missed, let dropMissNote {
                Text(dropMissNote)
                    .foregroundStyle(tint)
            } else if let target {
                Text("松手交给「\(target.displayName)」")
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(target.executor == .grokBot ? "由 Grok 处理" : "在本机执行，需确认")
                    .foregroundStyle(.secondary)
            } else {
                Text("拖到下面某个模块上再松手")
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
                .fill(missed ? IslandChrome.danger.opacity(0.10) : IslandChrome.surface)
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
        .padding(10)
        .background(IslandChrome.caution.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous))
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
        let note = "没落在模块上，这次什么也没发"
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
            shortcutNote = "已放到桌面：\(DesktopShortcut.aliasName)"
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
    @State private var hovering = false
    @State private var feedback: DropFeedback = .idle

    private var latestRun: RunRecord? {
        guard let run = engine.runs.first(where: { $0.moduleID == module.id }) else { return nil }
        if run.isActive || Date().timeIntervalSince(run.updatedAt) < TaskLightBoard.recentWindow {
            return run
        }
        return nil
    }

    /// Clear at rest: the fill alone defines the tile. An edge appears only to say something.
    private var borderColor: Color {
        if targeted { return IslandChrome.accent }
        switch feedback {
        case .loading: return IslandChrome.accent.opacity(0.6)
        case .sent: return IslandChrome.positive
        case .rejected: return IslandChrome.danger
        case .idle: return .clear
        }
    }

    var body: some View {
        Button(action: onOpen) {
            tileContent
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
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
        let shape = RoundedRectangle(cornerRadius: IslandChrome.innerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(module.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let latestRun {
                    TaskLightDot(state: TaskLightBoard.state(for: latestRun.phase), size: 6)
                        .help("最近一次：\(latestRun.message)")
                }
            }

            if !module.prompt.isEmpty {
                Text(module.prompt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(module.executor == .grokBot ? "Grok" : "本机")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(height: 80)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            shape.fill(
                targeted ? IslandChrome.accent.opacity(0.14)
                    : (hovering ? IslandChrome.surfaceRaised : IslandChrome.surface)
            )
        )
        .overlay {
            if targeted {
                dropPrompt
            } else if feedback != .idle {
                feedbackBadge
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: 1)
        }
        .contentShape(shape)
    }

    private var dropPrompt: some View {
        Text(module.executor == .grokBot ? "松手交给 Grok" : "松手在本机执行")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IslandChrome.ink.opacity(0.7))
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        switch feedback {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("读取中")
            }
            .modifier(TileBadgeStyle(tint: .primary))
        case .sent(let count):
            Text("已发送 \(count) 项")
                .modifier(TileBadgeStyle(tint: IslandChrome.positive))
        case .rejected(let message):
            Text("没发出去")
                .modifier(TileBadgeStyle(tint: IslandChrome.danger))
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
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(IslandChrome.ink.opacity(0.85)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(8)
    }
}
