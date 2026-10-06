import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Surface the thin UI should depend on. All methods hop through `IslandEngine`.
@MainActor
protocol IslandEngineAPI: AnyObject {
    var modules: [FunctionModule] { get }
    var inboxItems: [ResourceItem] { get }
    var runs: [RunRecord] { get }
    var pendingLocal: PendingLocalRun? { get }
    var lastError: String? { get }
    var activeRunCount: Int { get }

    func createModule(name: String, prompt: String, executor: ExecutorKind) throws -> FunctionModule
    func updateModule(_ module: FunctionModule) throws -> FunctionModule
    func renameModule(id: UUID, to name: String) throws -> FunctionModule
    func deleteModule(id: UUID) throws
    func loadDemoModules(overwrite: Bool)

    func ingest(_ items: [ResourceItem])
    func ingestDroppedURLs(_ urls: [URL])
    func ingestDroppedStrings(_ strings: [String])
    func removeInboxItem(id: UUID)
    func clearInbox()

    func runModule(id: UUID, extraPrompt: String?, resources: [ResourceItem]?, clearInboxOnStart: Bool) throws -> RunRecord
    func assignInbox(to moduleID: UUID, extraPrompt: String?, clearInboxOnStart: Bool) throws -> RunRecord
    func confirmPendingLocal(openAttachedFiles: Bool, shellCommand: String) throws
    func cancelPendingLocal()
    func cancelRun(id: UUID)
    func quickAskGrok(_ text: String) throws -> RunRecord
    func runQuickAction(_ action: GrokQuickAction, page: PageSnapshot, question: String?) throws -> RunRecord
    func runShortcut(title: String, prompt: String, page: PageSnapshot, question: String?) throws -> RunRecord
    func splitTask(_ text: String, resources: [ResourceItem], images: [PromptImage]) throws -> RunRecord
    func clearFinishedRuns() -> Int
    func deleteRuns(ids: Set<UUID>) -> Int
}

/// Public facade the UI should call. Owns module CRUD, the drop inbox, and execution.
///
///     createModule / updateModule / renameModule / deleteModule / loadDemoModules
///     ingestDroppedURLs / ingestDroppedStrings / ingestDropProviders
///     removeInboxItem / clearInbox
///     assignInbox(to:) / runModule
///     confirmPendingLocal / cancelPendingLocal / cancelRun
///     quickAskGrok / runQuickAction / runShortcut
///     splitTask
///     clearFinishedRuns / deleteRuns
@MainActor
final class IslandEngine: ObservableObject, IslandEngineAPI {
    let moduleStore: ModuleStore
    let inbox: ResourceInbox
    let journal: RunJournal
    let router: ExecutionRouter
    private let collaborator: (any SplitTaskCollaborating)?

    @Published var pendingLocal: PendingLocalRun?
    @Published var lastError: String?

    private var splitTasks: [UUID: Task<Void, Never>] = [:]
    private var splitChildren: [UUID: [UUID]] = [:]

    init(
        moduleStore: ModuleStore? = nil,
        inbox: ResourceInbox? = nil,
        journal: RunJournal? = nil,
        grokBot: ModuleExecuting = GrokBotExecutor(),
        local: ModuleExecuting = LocalExecutor(),
        collaborator: (any SplitTaskCollaborating)? = nil
    ) {
        let store = moduleStore ?? ModuleStore()
        let inbox = inbox ?? ResourceInbox()
        let journal = journal ?? RunJournal()
        self.moduleStore = store
        self.inbox = inbox
        self.journal = journal
        self.router = ExecutionRouter(journal: journal, grokBot: grokBot, local: local)
        self.collaborator = collaborator
        bindChildren()
    }

    var modules: [FunctionModule] { moduleStore.modules }
    var inboxItems: [ResourceItem] { inbox.items }
    var runs: [RunRecord] { journal.runs }
    var activeRunCount: Int { journal.activeRuns.count }

    // MARK: - Modules

    @discardableResult
    func createModule(name: String, prompt: String, executor: ExecutorKind) throws -> FunctionModule {
        lastError = nil
        return try moduleStore.create(name: name, prompt: prompt, executor: executor)
    }

    @discardableResult
    func updateModule(_ module: FunctionModule) throws -> FunctionModule {
        lastError = nil
        return try moduleStore.update(module)
    }

    @discardableResult
    func renameModule(id: UUID, to name: String) throws -> FunctionModule {
        lastError = nil
        return try moduleStore.rename(id: id, to: name)
    }

    func deleteModule(id: UUID) throws {
        lastError = nil
        if pendingLocal?.module.id == id {
            cancelPendingLocal()
        }
        try moduleStore.delete(id: id)
    }

    func loadDemoModules(overwrite: Bool = false) {
        lastError = nil
        do {
            if overwrite || moduleStore.modules.isEmpty {
                try moduleStore.replaceAll(ModuleStore.demoModules())
            }
        } catch {
            reportError(error)
        }
    }

    // MARK: - Inbox / drop intake

    func ingest(_ items: [ResourceItem]) {
        inbox.ingest(items)
    }

    func ingestDroppedURLs(_ urls: [URL]) {
        inbox.ingest(ResourceIntake.items(from: urls))
    }

    func ingestDroppedStrings(_ strings: [String]) {
        inbox.ingest(ResourceIntake.items(fromStrings: strings))
    }

#if canImport(AppKit)
    func ingestDropProviders(_ providers: [NSItemProvider]) {
        Task { [weak self] in
            let items = await ResourceIntake.loadItems(from: providers)
            self?.inbox.ingest(items)
        }
    }

    /// Drop straight onto a module tile: resolve the providers, then run that module on them.
    func ingestDropProviders(
        _ providers: [NSItemProvider],
        assignTo moduleID: UUID,
        completion: (@MainActor (DropOutcome) -> Void)? = nil
    ) {
        Task { [weak self] in
            guard let self else { return }
            let items = await ResourceIntake.loadItems(from: providers)
            completion?(self.runDropped(items, on: moduleID))
        }
    }
#endif

    /// Runs a module on freshly dropped resources and reports what happened for the tile.
    @discardableResult
    func runDropped(_ items: [ResourceItem], on moduleID: UUID) -> DropOutcome {
        guard !items.isEmpty else {
            lastError = IslandError.dropEmpty.localizedDescription
            return .rejected(IslandError.dropEmpty.localizedDescription)
        }
        do {
            let record = try runModule(id: moduleID, resources: items)
            return .started(runID: record.id, itemCount: items.count)
        } catch {
            reportError(error)
            return .rejected(lastError ?? error.localizedDescription)
        }
    }

    func removeInboxItem(id: UUID) {
        inbox.remove(id: id)
    }

    func clearInbox() {
        inbox.clear()
    }

    // MARK: - Run

    /// Lower-level start. Empty resource lists are allowed (prompt-only modules).
    @discardableResult
    func runModule(
        id: UUID,
        extraPrompt: String? = nil,
        resources: [ResourceItem]? = nil,
        clearInboxOnStart: Bool = false
    ) throws -> RunRecord {
        lastError = nil
        guard let module = moduleStore.module(id: id) else {
            lastError = IslandError.moduleNotFound.localizedDescription
            throw IslandError.moduleNotFound
        }
        let payload = resources ?? inbox.snapshot()
        return try start(module: module, resources: payload, extraPrompt: extraPrompt, clearInboxOnStart: clearInboxOnStart)
    }

    /// Assigns the current inbox to a user-defined module and starts it.
    /// Requires at least one dropped resource. Local modules pause on `pendingLocal`.
    @discardableResult
    func assignInbox(
        to moduleID: UUID,
        extraPrompt: String? = nil,
        clearInboxOnStart: Bool = true
    ) throws -> RunRecord {
        lastError = nil
        guard !inbox.isEmpty else {
            lastError = IslandError.inboxEmpty.localizedDescription
            throw IslandError.inboxEmpty
        }
        return try runModule(
            id: moduleID,
            extraPrompt: extraPrompt,
            resources: inbox.snapshot(),
            clearInboxOnStart: clearInboxOnStart
        )
    }

    func confirmPendingLocal(openAttachedFiles: Bool, shellCommand: String) throws {
        lastError = nil
        guard let pending = pendingLocal else { throw IslandError.runNotFound }
        let command = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = LocalExecutionOptions(
            openAttachedFiles: openAttachedFiles,
            confirmedShellCommand: command.isEmpty ? nil : command
        )
        let request = ExecutionRequest(
            module: pending.module,
            resources: pending.resources,
            extraPrompt: pending.extraPrompt,
            local: options
        )
        try router.confirmLocal(request, runID: pending.runID)
        pendingLocal = nil
    }

    func cancelPendingLocal() {
        if let pending = pendingLocal {
            router.cancel(runID: pending.runID)
        }
        pendingLocal = nil
    }

    func cancelRun(id: UUID) {
        if pendingLocal?.runID == id {
            cancelPendingLocal()
            return
        }
        if cancelSplit(id: id) { return }
        router.cancel(runID: id)
    }

    /// Drops or types one task. A planner agent splits it; each piece runs as its own cloud agent.
    /// The returned record is the combined result. Subtask records carry the activity lights.
    @discardableResult
    func splitTask(
        _ text: String,
        resources: [ResourceItem] = [],
        images: [PromptImage] = []
    ) throws -> RunRecord {
        lastError = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !resources.isEmpty || !images.isEmpty else {
            lastError = IslandError.emptyInput.localizedDescription
            throw IslandError.emptyInput
        }
        guard let collaborator else {
            let error = IslandError.executorFailed("拆分任务还没有接上 Cursor Cloud Agent。")
            lastError = error.localizedDescription
            throw error
        }
        let task = trimmed.isEmpty ? "根据附件完成任务" : trimmed
        let parent = journal.enqueue(
            module: nil,
            name: "拆分任务",
            executor: .grokBot,
            resources: resources,
            extraPrompt: nil,
            phase: .queued,
            origin: .splitTask,
            question: task
        )
        journal.transition(id: parent.id, phase: .running, progress: 0.05, message: "正在拆分任务…")
        let parentID = parent.id
        let request = SplitTaskRequest(task: task, resources: resources, images: images)
        splitTasks[parentID] = Task { [weak self] in
            guard let self else { return }
            let callbacks = SplitTaskCallbacks(
                onPlannerProgress: { [weak self] progress in
                    let engine = self
                    await MainActor.run {
                        engine?.journal.apply(progress: progress, to: parentID)
                    }
                },
                onPlan: { [weak self] plan in
                    let engine = self
                    await MainActor.run {
                        engine?.adoptSplitPlan(parentID, plan, resources: resources)
                    }
                },
                onSubtaskProgress: { [weak self] index, progress in
                    let engine = self
                    await MainActor.run {
                        engine?.noteSplitProgress(parentID, index: index, progress: progress)
                    }
                },
                onSubtaskFinished: { [weak self] index, outcome in
                    let engine = self
                    await MainActor.run {
                        engine?.closeSplitSubtask(parentID, index: index, outcome: outcome)
                    }
                },
                onSummaryProgress: { [weak self] progress in
                    let engine = self
                    await MainActor.run {
                        engine?.journal.transition(
                            id: parentID,
                            phase: .running,
                            progress: max(progress.fraction, 0.9),
                            message: "正在汇总…",
                            link: progress.link
                        )
                    }
                }
            )
            do {
                let result = try await collaborator.collaborate(request, callbacks: callbacks)
                if Task.isCancelled || self.journal.record(id: parentID)?.phase.isTerminal == true {
                    self.markSplitCancelled(parentID)
                } else {
                    self.finishSplit(parentID, result)
                }
            } catch is CancellationError {
                self.markSplitCancelled(parentID)
            } catch {
                if Task.isCancelled {
                    self.markSplitCancelled(parentID)
                } else {
                    self.failSplit(parentID, error)
                    self.reportError(error)
                }
            }
        }
        return parent
    }

    /// Scaffold for the island's "quick ask Grok" field — no module required.
    @discardableResult
    func quickAskGrok(_ text: String) throws -> RunRecord {
        lastError = nil
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw IslandError.emptyInput }
        let ephemeral = FunctionModule(
            name: "Quick Ask",
            prompt: prompt,
            executor: .grokBot
        )
        let payload = inbox.snapshot()
        let record = journal.enqueue(
            module: ephemeral,
            name: GrokQuickAction.askAboutPage.title,
            executor: .grokBot,
            resources: payload,
            extraPrompt: prompt,
            phase: .queued,
            origin: .quickAsk,
            question: prompt
        )
        let request = ExecutionRequest(
            module: ephemeral,
            resources: payload,
            extraPrompt: prompt,
            local: nil
        )
        try router.start(request, runID: record.id)
        return record
    }

    /// Sends the captured frontmost page to Grok with one of the preset jobs.
    @discardableResult
    func runQuickAction(
        _ action: GrokQuickAction,
        page: PageSnapshot,
        question: String? = nil
    ) throws -> RunRecord {
        try runPagePrompt(
            title: action.title,
            prompt: action.prompt,
            page: page,
            question: question,
            origin: action == .askAboutPage ? .quickAsk : .quickAction,
            requireQuestion: action == .askAboutPage
        )
    }

    /// Sends the captured frontmost page to Grok for one shortcut button, built-in or custom.
    @discardableResult
    func runShortcut(
        title: String,
        prompt: String,
        page: PageSnapshot,
        question: String? = nil
    ) throws -> RunRecord {
        try runPagePrompt(
            title: title,
            prompt: prompt,
            page: page,
            question: question,
            origin: .quickAction,
            requireQuestion: false
        )
    }

    private func runPagePrompt(
        title: String,
        prompt: String,
        page: PageSnapshot,
        question: String?,
        origin: RunOrigin,
        requireQuestion: Bool
    ) throws -> RunRecord {
        lastError = nil
        let question = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requireQuestion, question.isEmpty {
            lastError = IslandError.emptyInput.localizedDescription
            throw IslandError.emptyInput
        }
        guard page.hasContent || !question.isEmpty else {
            let error = IslandError.pageCaptureFailed(page.captureNote ?? "没有截到当前页面。")
            lastError = error.localizedDescription
            throw error
        }
        let module = FunctionModule(name: title, prompt: prompt, executor: .grokBot)
        let extra = [page.contextDescription, question.isEmpty ? nil : "我的问题：\(question)"]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let record = journal.enqueue(
            module: module,
            name: title,
            executor: .grokBot,
            resources: [],
            extraPrompt: extra,
            phase: .queued,
            origin: origin,
            question: question.isEmpty ? nil : question
        )
        let request = ExecutionRequest(
            module: module,
            resources: [],
            extraPrompt: extra,
            local: nil,
            images: page.screenshot.map { [$0] } ?? []
        )
        try router.start(request, runID: record.id)
        return record
    }

    /// One-click cleanup: drops every succeeded / failed / cancelled record.
    @discardableResult
    func clearFinishedRuns() -> Int {
        journal.clearFinished()
    }

    /// Deletes the selected records. Active ones are cancelled first so no task is orphaned.
    @discardableResult
    func deleteRuns(ids: Set<UUID>) -> Int {
        for id in ids where journal.record(id: id)?.isActive == true {
            cancelRun(id: id)
        }
        return journal.remove(ids: ids)
    }

    func reportError(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func adoptSplitPlan(_ parentID: UUID, _ plan: SplitPlan, resources: [ResourceItem]) {
        guard journal.record(id: parentID)?.isActive == true else { return }
        var ids: [UUID] = []
        for subtask in plan.subtasks {
            let child = journal.enqueue(
                module: nil,
                name: subtask.title,
                executor: .grokBot,
                resources: resources,
                extraPrompt: subtask.prompt,
                phase: .queued,
                origin: .splitSubtask,
                question: nil,
                parentRunID: parentID
            )
            journal.transition(id: child.id, phase: .running, progress: 0.05, message: "子任务启动中")
            ids.append(child.id)
        }
        splitChildren[parentID] = ids
        journal.transition(
            id: parentID,
            phase: .running,
            progress: 0.15,
            message: "已拆成 \(plan.subtasks.count) 个子任务，并行执行"
        )
    }

    private func noteSplitProgress(_ parentID: UUID, index: Int, progress: ExecutionProgress) {
        guard let childID = splitChildID(parentID, index: index) else { return }
        journal.apply(progress: progress, to: childID)
    }

    private func closeSplitSubtask(_ parentID: UUID, index: Int, outcome: SplitSubtaskOutcome) {
        guard let childID = splitChildID(parentID, index: index) else { return }
        guard journal.record(id: childID)?.isActive == true else { return }
        if outcome.succeeded {
            let summary = GrokPromptBuilder.headline(of: outcome.text) ?? outcome.title
            journal.succeed(
                id: childID,
                result: ExecutionResult(summary: summary, detail: outcome.text, link: outcome.link)
            )
        } else {
            journal.transition(
                id: childID,
                phase: .failed,
                progress: 1,
                message: outcome.text,
                resultSummary: outcome.text,
                link: outcome.link
            )
        }
        let children = splitChildren[parentID] ?? []
        let finished = children.filter { journal.record(id: $0)?.phase.isTerminal == true }.count
        guard journal.record(id: parentID)?.isActive == true else { return }
        let fraction = children.isEmpty ? 0.9 : 0.15 + 0.7 * Double(finished) / Double(children.count)
        journal.transition(
            id: parentID,
            phase: .running,
            progress: fraction,
            message: "\(finished)/\(children.count) 个子任务已结束"
        )
    }

    private func finishSplit(_ parentID: UUID, _ result: SplitCollaborationResult) {
        guard journal.record(id: parentID)?.isActive == true else { return }
        journal.transition(
            id: parentID,
            phase: result.anySucceeded ? .succeeded : .failed,
            progress: 1,
            message: result.headline,
            resultSummary: result.markdown,
            link: result.link
        )
        splitTasks[parentID] = nil
        splitChildren[parentID] = nil
    }

    private func failSplit(_ parentID: UUID, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        journal.fail(id: parentID, message: message)
        for child in splitChildren[parentID] ?? [] where journal.record(id: child)?.isActive == true {
            journal.fail(id: child, message: message)
        }
        splitTasks[parentID] = nil
        splitChildren[parentID] = nil
    }

    private func markSplitCancelled(_ parentID: UUID) {
        journal.cancel(id: parentID)
        for child in splitChildren[parentID] ?? [] {
            journal.cancel(id: child)
        }
        splitTasks[parentID] = nil
        splitChildren[parentID] = nil
    }

    private func splitChildID(_ parentID: UUID, index: Int) -> UUID? {
        guard let ids = splitChildren[parentID], ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    /// Cancels the whole split when the parent or any of its subtasks is cancelled.
    private func cancelSplit(id: UUID) -> Bool {
        let parentID: UUID
        if splitTasks[id] != nil || splitChildren[id] != nil || journal.record(id: id)?.origin == .splitTask {
            parentID = id
        } else if let parent = splitChildren.first(where: { $0.value.contains(id) })?.key {
            parentID = parent
        } else if journal.record(id: id)?.origin == .splitSubtask {
            journal.cancel(id: id)
            return true
        } else {
            return false
        }
        splitTasks[parentID]?.cancel()
        markSplitCancelled(parentID)
        return true
    }

    private func start(
        module: FunctionModule,
        resources: [ResourceItem],
        extraPrompt: String?,
        clearInboxOnStart: Bool
    ) throws -> RunRecord {
        switch module.executor {
        case .local:
            let record = journal.enqueue(
                module: module,
                name: module.displayName,
                executor: .local,
                resources: resources,
                extraPrompt: extraPrompt,
                phase: .awaitingConfirmation
            )
            pendingLocal = PendingLocalRun(
                runID: record.id,
                module: module,
                resources: resources,
                extraPrompt: extraPrompt
            )
            if clearInboxOnStart { inbox.clear() }
            return record

        case .grokBot:
            let record = journal.enqueue(
                module: module,
                name: module.displayName,
                executor: .grokBot,
                resources: resources,
                extraPrompt: extraPrompt,
                phase: .queued
            )
            let request = ExecutionRequest(
                module: module,
                resources: resources,
                extraPrompt: extraPrompt,
                local: nil
            )
            try router.start(request, runID: record.id)
            if clearInboxOnStart { inbox.clear() }
            return record
        }
    }

    private func bindChildren() {
        moduleStore.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        inbox.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        journal.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []
}
