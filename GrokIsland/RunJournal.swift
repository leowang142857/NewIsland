import Foundation
import Combine

/// In-memory notification / progress log for module runs.
///
/// State machine: `queued` → (`awaitingConfirmation` for Local) → `running`
/// → `succeeded` | `failed` | `cancelled`.
/// Terminal phases are sticky: later progress / success cannot resurrect a cancelled run.
@MainActor
final class RunJournal: ObservableObject {
    @Published private(set) var runs: [RunRecord] = []

    var activeRuns: [RunRecord] {
        runs.filter(\.isActive)
    }

    func record(id: UUID) -> RunRecord? {
        runs.first { $0.id == id }
    }

    @discardableResult
    func enqueue(
        module: FunctionModule?,
        name: String,
        executor: ExecutorKind,
        resources: [ResourceItem],
        extraPrompt: String?,
        phase: RunPhase = .queued,
        id: UUID = UUID()
    ) -> RunRecord {
        let now = Date()
        let record = RunRecord(
            id: id,
            moduleID: module?.id,
            moduleName: name,
            executor: executor,
            resources: resources,
            extraPrompt: extraPrompt,
            phase: phase,
            progress: 0,
            message: phase == .awaitingConfirmation ? "Waiting for local confirmation" : "Queued",
            resultSummary: nil,
            createdAt: now,
            updatedAt: now
        )
        runs.insert(record, at: 0)
        return record
    }

    func transition(
        id: UUID,
        phase: RunPhase,
        progress: Double? = nil,
        message: String? = nil,
        resultSummary: String? = nil
    ) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var record = runs[index]
        if record.phase.isTerminal { return }
        record.phase = phase
        if let progress {
            record.progress = min(max(progress, 0), 1)
        }
        if let message {
            record.message = message
        }
        if let resultSummary {
            record.resultSummary = resultSummary
        }
        record.updatedAt = Date()
        runs[index] = record
    }

    func apply(progress: ExecutionProgress, to id: UUID) {
        guard let record = record(id: id) else { return }
        guard record.phase == .running || record.phase == .queued else { return }
        transition(id: id, phase: .running, progress: progress.fraction, message: progress.message)
    }

    func fail(id: UUID, message: String) {
        transition(id: id, phase: .failed, progress: 1, message: message, resultSummary: message)
    }

    func succeed(id: UUID, result: ExecutionResult) {
        transition(
            id: id,
            phase: .succeeded,
            progress: 1,
            message: result.summary,
            resultSummary: result.detail ?? result.summary
        )
    }

    func cancel(id: UUID) {
        guard let record = record(id: id), record.isActive else { return }
        transition(id: id, phase: .cancelled, message: "Cancelled")
    }

    func clearFinished() {
        runs.removeAll { $0.phase.isTerminal }
    }
}
