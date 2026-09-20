import Foundation
import Combine

/// Picks Grok Bot vs Local and drives `RunJournal` through the run state machine.
@MainActor
final class ExecutionRouter: ObservableObject {
    private let journal: RunJournal
    private let grokBot: ModuleExecuting
    private let local: ModuleExecuting
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        journal: RunJournal,
        grokBot: ModuleExecuting = GrokBotExecutor(),
        local: ModuleExecuting = LocalExecutor()
    ) {
        self.journal = journal
        self.grokBot = grokBot
        self.local = local
    }

    func executor(for kind: ExecutorKind) -> ModuleExecuting {
        switch kind {
        case .grokBot: grokBot
        case .local: local
        }
    }

    /// Starts a Grok Bot run immediately. Local runs must go through `confirmLocal`.
    func start(_ request: ExecutionRequest, runID: UUID) throws {
        switch request.module.executor {
        case .local:
            guard request.local != nil else { throw IslandError.localConfirmationRequired }
            launch(request, runID: runID)
        case .grokBot:
            launch(request, runID: runID)
        }
    }

    func confirmLocal(_ request: ExecutionRequest, runID: UUID) throws {
        guard request.module.executor == .local else {
            launch(request, runID: runID)
            return
        }
        guard request.local != nil else { throw IslandError.localConfirmationRequired }
        launch(request, runID: runID)
    }

    func cancel(runID: UUID) {
        tasks[runID]?.cancel()
        tasks[runID] = nil
        journal.cancel(id: runID)
    }

    private func launch(_ request: ExecutionRequest, runID: UUID) {
        tasks[runID]?.cancel()
        journal.transition(id: runID, phase: .running, progress: 0.02, message: "Starting")

        let worker = executor(for: request.module.executor)
        tasks[runID] = Task { @MainActor [journal] in
            do {
                let result = try await worker.run(request) { progress in
                    Task { @MainActor in
                        journal.apply(progress: progress, to: runID)
                    }
                }
                if Task.isCancelled {
                    journal.cancel(id: runID)
                    return
                }
                journal.succeed(id: runID, result: result)
            } catch is CancellationError {
                journal.cancel(id: runID)
            } catch let error as IslandError {
                journal.fail(id: runID, message: error.localizedDescription)
            } catch {
                journal.fail(id: runID, message: error.localizedDescription)
            }
            tasks[runID] = nil
        }
    }
}
