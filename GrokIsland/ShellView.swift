import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Expanded island on the aurora glass. Calls `IslandEngine` only.
///
/// Home is layered top → bottom: per-task status lights → DDL energy bar → Grok shortcuts and
/// fields → modules / tray / records under one segmented control. Detail screens sit one level deeper.
struct ShellView: View {
    @ObservedObject var engine: IslandEngine
    @ObservedObject var presence: IslandPresence
    @ObservedObject var monitor: CloudActivityMonitor
    @ObservedObject var settings: IslandSettings
    @ObservedObject var deadlines: DeadlineStore
    @ObservedObject var tray: FileTray

    static let dropTypes: [UTType] = [.fileURL, .url, .plainText]

    private static let shape = RoundedRectangle(cornerRadius: IslandChrome.cornerRadius, style: .continuous)

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
            case .modules: "模块"
            case .tray: TrayPath.rootTitle
            case .records: "记录"
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
    @State private var shellDragActive = false
    @State private var dropTargetModuleID: UUID?
    @State private var dropMissNote: String?
    @State private var trayDragActive = false
    @State private var traySlotTargeted = false
    @State private var trayTabTargeted = false
    @Namespace private var tabThumb
    @Namespace private var executorThumb

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
                errorBanner(error)
            }
        }
        .padding(IslandChrome.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .islandChrome(
            Self.shape,
            glow: 0.85,
            emphasized: isReceivingFiles,
            background: settings.background,
            imageURL: settings.backgroundImageURL
        )
        .islandFlash(Self.shape, trigger: monitor.flashCount)
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
                    withAnimation(IslandChrome.selectSpring) { homeTab = .tray }
                }
            }
        }
        .onAppear {
            monitor.refreshSoon()
            tray.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if case .home = route {
                Button {
                    route = .activity
                } label: {
                    HStack(spacing: 7) {
                        ActivityLight(
                            busy: monitor.snapshot.isBusy || engine.activeRunCount > 0,
                            warning: monitor.snapshot.hasFailingChecks,
                            size: 7
                        )
                        Text(IslandChrome.name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.islandPress)
                .help(activityHelp)
            } else {
                Button {
                    route = .home
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(IslandChrome.surface))
                        Text(routeTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.islandPress)
                .help("回到主页")
            }

            Spacer(minLength: 4)

            headerStatus

            HStack(spacing: 2) {
                Button {
                    route = route == .settings ? .home : .settings
                } label: {
                    Image(systemName: settings.isModelReady ? "gearshape" : "gearshape.fill")
                }
                .buttonStyle(.islandIcon(
                    tint: settings.isModelReady ? nil : IslandChrome.ember,
                    active: route == .settings
                ))
                .help(settings.isModelReady ? "设置" : ModelProviderMessages.gearHelp)

                Button {
                    presence.isPinned.toggle()
                } label: {
                    Image(systemName: presence.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.islandIcon(active: presence.isPinned))
                .help(presence.isPinned ? "取消钉住，移开就收起" : "钉住，移开也不收起")
            }
        }
        .frame(height: IslandChrome.iconTarget + 2)
    }

    /// What's running, if anything; otherwise the time.
    @ViewBuilder
    private var headerStatus: some View {
        if engine.activeRunCount > 0 {
            Button {
                route = .home
                homeTab = .records
            } label: {
                Text("\(engine.activeRunCount) 个在跑")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandChrome.positive)
                    .lineLimit(1)
            }
            .buttonStyle(.islandPress)
            .help("看看在跑的记录")
        } else if monitor.snapshot.isBusy, route == .home {
            Button {
                route = .activity
            } label: {
                Text(cloudBadge)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.islandPress)
            .help(activityHelp)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, style: .time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var routeTitle: String {
        switch route {
        case .home: IslandChrome.name
        case .editor(let id): id == nil ? "新建模块" : "编辑模块"
        case .run(let id): engine.runs.first(where: { $0.id == id })?.moduleName ?? "结果"
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
        .joined(separator: " · ")
    }

    private var activityHelp: String {
        let snapshot = monitor.snapshot
        guard snapshot.isBusy || engine.activeRunCount > 0 else { return "现在没有在跑的 Agent 或 PR · 点开看看" }
        return "Cloud Agent \(snapshot.agents.count) · PR \(snapshot.pullRequests.count) · 本机 \(engine.activeRunCount)"
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
                .padding(.horizontal, 12)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandPress)
            .help("再看一眼这条回答")
        }
    }

    private var layerTabs: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases) { tab in
                if tab == .tray {
                    tabSegment(tab)
                        .onDrop(of: TrayDrop.types, delegate: TrayDropTarget(
                            targeted: $trayTabTargeted,
                            operation: { TrayDrop.proposal(into: "", tray: tray) },
                            perform: { providers in
                                showTray()
                                return TrayDrop.accept(providers, into: "", tray: tray)
                            }
                        ))
                        .help("拖到这里先放着，要用时再拖回桌面")
                } else {
                    tabSegment(tab)
                }
            }
        }
        .islandSegmentTrack()
    }

    private func tabSegment(_ tab: HomeTab) -> some View {
        let count: Int? = switch tab {
        case .modules: nil
        case .tray: tray.rootCount
        case .records: engine.runs.count
        }
        return IslandSegment(
            title: tab.title,
            count: count,
            selected: homeTab == tab,
            targeted: tab == .tray && trayTabTargeted,
            namespace: tabThumb
        ) {
            withAnimation(IslandChrome.selectSpring) { homeTab = tab }
        }
    }

    private func showTray() {
        tray.open("")
        withAnimation(IslandChrome.selectSpring) { homeTab = .tray }
    }

    private var moduleLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDragging || dropMissNote != nil {
                dropBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if engine.modules.isEmpty {
                emptyModules
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
                        if !isReceivingFiles {
                            NewModuleTile(action: beginCreate)
                        }
                    }
                    .padding(2)
                }
            }

            if isReceivingFiles {
                TrayDropSlot(tray: tray, targeted: $traySlotTargeted, onDropped: showTray)
                    .transition(.opacity)
            } else if !engine.modules.isEmpty {
                Text("把文件或链接拖到模块上，就开始处理")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .animation(IslandChrome.expandSpring, value: isDragging)
    }

    private var emptyModules: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("还没有模块")
                    .font(.system(size: 13, weight: .semibold))
                Text("模块是一段固定的提示词。把文件拖到模块上，它就照这段话来处理。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("新建模块", action: beginCreate)
                    .buttonStyle(.islandPill(.prominent))
                Button("先放几个示例") { engine.loadDemoModules(overwrite: false) }
                    .buttonStyle(.islandPill(.quiet))
            }
        }
        .islandPlatter(inset: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .layoutPriority(1)
                Text(target.executor == .grokBot ? "Grok 来处理" : "在本机运行，会先问你")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("拖到下面的模块上再松手")
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background {
            Capsule(style: .continuous)
                .fill(missed ? IslandChrome.danger.opacity(0.12) : (target == nil ? IslandChrome.surface : IslandChrome.accent.opacity(0.14)))
        }
    }

    // MARK: - Editor

    private func editor(editingID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("名称")
                    .islandSectionLabel()
                    .padding(.horizontal, 4)
                TextField("比如：翻译、整理笔记、跑脚本", text: $draftName)
                    .islandField()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("提示词")
                    .islandSectionLabel()
                    .padding(.horizontal, 4)
                TextField("拖进来的东西要怎么处理", text: $draftPrompt, axis: .vertical)
                    .lineLimit(3...8)
                    .islandField()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("交给谁")
                    .islandSectionLabel()
                    .padding(.horizontal, 4)
                HStack(spacing: 0) {
                    ForEach(ExecutorKind.allCases) { kind in
                        IslandSegment(
                            title: kind.title,
                            selected: draftExecutor == kind,
                            namespace: executorThumb
                        ) {
                            withAnimation(IslandChrome.selectSpring) { draftExecutor = kind }
                        }
                    }
                }
                .islandSegmentTrack()
                Text(draftExecutor == .grokBot ? "交给 Grok，答案回到岛上。" : "在这台 Mac 上运行，每次都先问过你。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 6) {
                Button(editingID == nil ? "创建" : "保存") {
                    saveDraft(editingID: editingID)
                }
                .buttonStyle(.islandPill(.prominent))
                .keyboardShortcut(.defaultAction)

                if let editingID {
                    Button("删除", role: .destructive) {
                        do {
                            try engine.deleteModule(id: editingID)
                            route = .home
                        } catch {
                            engine.reportError(error)
                        }
                    }
                    .buttonStyle(.islandPill(.destructive))
                }
                Spacer()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Confirmation and errors

    private var localConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = engine.pendingLocal {
                VStack(alignment: .leading, spacing: 3) {
                    Text("在本机运行「\(pending.module.displayName)」？")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text("提示词不会被当成命令。只有下面填好、你确认过的命令才会运行。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("用默认应用打开拖进来的文件", isOn: $confirmOpenFiles)
                    .font(.system(size: 11))
                    .controlSize(.small)
                TextField("要运行的 zsh 命令，可以不填", text: $confirmCommand)
                    .islandField()
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button("取消") {
                        engine.cancelPendingLocal()
                        confirmCommand = ""
                    }
                    .buttonStyle(.islandPill(compact: true))
                    Button("运行") {
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
                    .buttonStyle(.islandPill(.prominent, compact: true))
                }
            }
        }
        .islandPlatter(inset: 12, tint: IslandChrome.caution)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(IslandChrome.danger)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                engine.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IslandIconButtonStyle(size: 18))
            .help("知道了")
        }
        .islandPlatter(inset: 10, tint: IslandChrome.danger)
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

/// Module tile. Click opens the editor; dropping resources runs the module.
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

    /// A hairline at rest; the edge takes a color only to say something.
    private var borderColor: Color {
        if targeted { return IslandChrome.accent }
        switch feedback {
        case .loading: return IslandChrome.accent.opacity(0.6)
        case .sent: return IslandChrome.positive
        case .rejected: return IslandChrome.danger
        case .idle: return IslandChrome.hairline
        }
    }

    var body: some View {
        Button(action: onOpen) {
            tileContent
        }
        .buttonStyle(.islandPress)
        .onHover { hovering = $0 }
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
        .animation(.easeInOut(duration: 0.2), value: feedback)
        .animation(IslandChrome.hoverFade, value: hovering)
        .help(module.executor == .grokBot ? "点一下编辑 · 把文件或链接拖上来交给 Grok" : "点一下编辑 · 拖上来在本机运行（会先问你）")
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
        let shape = RoundedRectangle(cornerRadius: IslandChrome.platterRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
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
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(module.executor.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(height: 84)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            shape.fill(
                targeted ? IslandChrome.accent.opacity(0.16)
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
            shape.strokeBorder(borderColor, lineWidth: targeted || feedback != .idle ? 1 : 0.5)
        }
        .contentShape(shape)
    }

    private var dropPrompt: some View {
        Text(module.executor == .grokBot ? "松手交给 Grok" : "松手在本机运行")
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
                Text("正在读")
            }
            .modifier(TileBadgeStyle(tint: .primary))
        case .sent(let count):
            Text("交出去了 \(count) 项")
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

/// The grid's last tile: a dashed outline that opens the editor for a new module.
private struct NewModuleTile: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandChrome.platterRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                Text("新建模块")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(shape.fill(hovering ? IslandChrome.surface : Color.clear))
            .overlay {
                shape.strokeBorder(
                    Color.white.opacity(hovering ? 0.24 : 0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.islandPress)
        .onHover { hovering = $0 }
        .animation(IslandChrome.hoverFade, value: hovering)
        .help("新建一个模块")
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
