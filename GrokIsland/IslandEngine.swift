import Foundation
import Combine

#if canImport(AppKit)
import AppKit
#endif

/// Public facade the UI should call. Owns module CRUD, the drop inbox, and execution.
///
///     createModule / updateModule / deleteModule / loadDemoModules
///     ingestDroppedURLs / ingestDroppedStrings / ingestDropProviders
///     removeInboxItem / clearInbox
///     runModule / confirmPendingLocal / cancelPendingLocal / cancelRun
///     quickAskGrok
///     clearFinishedRuns
@MainActor
final class IslandEngine: ObservableObject {
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

    func deleteModule(id: UUID) throws {
        lastError = nil
        if pendingLocal?.module.id == id {
            cancelPendingLocal()
        }
        try moduleStore.delete(id: id)
    }

    func loadDemoModules(overwrite: Bool = false) {
        lastError = nil
        if overwrite || moduleStore.modules.isEmpty {
            moduleStore.replaceAll(ModuleStore.demoModules())
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

    /// Assigns the current inbox to a user-defined module and starts it.
    /// Local modules pause on `pendingLocal` until `confirmPendingLocal`.
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

        switch module.executor {
        case .local:
            let record = journal.enqueue(
                module: module,
                name: module.displayName,
                executor: .local,
                resources: payload,
                extraPrompt: extraPrompt,
                phase: .awaitingConfirmation
            )
            pendingLocal = PendingLocalRun(
                runID: record.id,
                module: module,
                resources: payload,
                extraPrompt: extraPrompt
            )
            if clearInboxOnStart { inbox.clear() }
            return record

        case .grokBot:
            let record = journal.enqueue(
                module: module,
                name: module.displayName,
                executor: .grokBot,
                resources: payload,
                extraPrompt: extraPrompt,
                phase: .queued
            )
            let request = ExecutionRequest(
                module: module,
                resources: payload,
                extraPrompt: extraPrompt,
                local: nil
            )
            try router.start(request, runID: record.id)
            if clearInboxOnStart { inbox.clear() }
            return record
        }
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
        let record = journal.enqueue(
            module: ephemeral,
            name: ephemeral.name,
            executor: .grokBot,
            resources: inbox.snapshot(),
            extraPrompt: prompt,
            phase: .queued
        )
        let request = ExecutionRequest(
            module: ephemeral,
            resources: inbox.snapshot(),
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
