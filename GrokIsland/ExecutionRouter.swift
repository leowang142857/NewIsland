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

    func isRunning(runID: UUID) -> Bool {
        tasks[runID] != nil
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
        tasks[runID] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await worker.run(request) { progress in
                    await MainActor.run {
                        self.journal.apply(progress: progress, to: runID)
                    }
                }
                await MainActor.run {
                    if Task.isCancelled {
                        self.journal.cancel(id: runID)
                    } else {
                        self.journal.succeed(id: runID, result: result)
                    }
                    self.tasks[runID] = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.journal.cancel(id: runID)
                    self.tasks[runID] = nil
                }
            } catch let error as IslandError {
                await MainActor.run {
                    self.journal.fail(id: runID, message: error.localizedDescription)
                    self.tasks[runID] = nil
                }
            } catch {
                await MainActor.run {
                    self.journal.fail(id: runID, message: error.localizedDescription)
                    self.tasks[runID] = nil
                }
            }
        }
    }
}
