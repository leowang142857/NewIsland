import Foundation
import Combine

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
    func clearFinishedRuns()
}

/// Public facade the UI should call. Owns module CRUD, the drop inbox, and execution.
///
///     createModule / updateModule / renameModule / deleteModule / loadDemoModules
///     ingestDroppedURLs / ingestDroppedStrings / ingestDropProviders
///     removeInboxItem / clearInbox
///     assignInbox(to:) / runModule
///     confirmPendingLocal / cancelPendingLocal / cancelRun
///     quickAskGrok
///     clearFinishedRuns
@MainActor
final class IslandEngine: ObservableObject, IslandEngineAPI {
    let moduleStore: ModuleStore
    let inbox: ResourceInbox
    let journal: RunJournal
    let router: ExecutionRouter

    @Published var pendingLocal: PendingLocalRun?
    @Published var lastError: String?

    init(
        moduleStore: ModuleStore? = nil,
        inbox: ResourceInbox? = nil,
        journal: RunJournal? = nil,
        grokBot: ModuleExecuting = GrokBotExecutor(),
        local: ModuleExecuting = LocalExecutor()
    ) {
        let store = moduleStore ?? ModuleStore()
        let inbox = inbox ?? ResourceInbox()
        let journal = journal ?? RunJournal()
        self.moduleStore = store
        self.inbox = inbox
        self.journal = journal
        self.router = ExecutionRouter(journal: journal, grokBot: grokBot, local: local)
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
#endif

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
        router.cancel(runID: id)
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
            name: ephemeral.name,
            executor: .grokBot,
            resources: payload,
            extraPrompt: prompt,
            phase: .queued
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

    func clearFinishedRuns() {
        journal.clearFinished()
    }

    func reportError(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
