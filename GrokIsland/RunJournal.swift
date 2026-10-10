import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Notification / progress log for module runs, optionally persisted as JSON.
///
/// State machine: `queued` → (`awaitingConfirmation` for Local) → `running`
/// → `succeeded` | `failed` | `cancelled`.
/// Terminal phases are sticky: later progress / success cannot resurrect a cancelled run.
///
/// With a `fileURL`, every phase change / removal is written to disk so Grok answers
/// survive a relaunch. Runs still active when the app quit come back as cancelled.
@MainActor
final class RunJournal: ObservableObject {
    @Published private(set) var runs: [RunRecord] = []

    /// Oldest records beyond this are dropped when saving.
    static let maxStoredRuns = 80
    static let interruptedMessage = "NewIsland 退出时还在运行，已中断"

    private let fileURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `nil` keeps the journal in memory only (tests, previews).
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        runs = loadFromDisk()
    }

    static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("GrokIsland", isDirectory: true)
            .appendingPathComponent("run-journal.json")
    }

    var activeRuns: [RunRecord] {
        runs.filter(\.isActive)
    }

    var finishedCount: Int {
        runs.filter { $0.phase.isTerminal }.count
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
        origin: RunOrigin = .module,
        question: String? = nil,
        parentRunID: UUID? = nil,
        id: UUID = UUID()
    ) -> RunRecord {
        let now = Date()
        let record = RunRecord(
            id: id,
            moduleID: origin == .module ? module?.id : nil,
            moduleName: name,
            executor: executor,
            resources: resources,
            extraPrompt: extraPrompt,
            phase: phase,
            progress: 0,
            message: phase == .awaitingConfirmation ? "等你确认后在本机运行" : "排队中",
            resultSummary: nil,
            createdAt: now,
            updatedAt: now,
            origin: origin,
            question: question,
            parentRunID: parentRunID
        )
        runs.insert(record, at: 0)
        persist()
        return record
    }

    func transition(
        id: UUID,
        phase: RunPhase,
        progress: Double? = nil,
        message: String? = nil,
        resultSummary: String? = nil,
        link: String? = nil
    ) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var record = runs[index]
        if record.phase.isTerminal { return }
        let phaseChanged = record.phase != phase
        let linkChanged = link != nil && record.link != link
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
        if let link {
            record.link = link
        }
        record.updatedAt = Date()
        runs[index] = record
        if phaseChanged || linkChanged || resultSummary != nil {
            persist()
        }
    }

    func apply(progress: ExecutionProgress, to id: UUID) {
        guard let record = record(id: id) else { return }
        guard record.phase == .running || record.phase == .queued else { return }
        transition(
            id: id,
            phase: .running,
            progress: progress.fraction,
            message: progress.message,
            link: progress.link
        )
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
            resultSummary: result.detail ?? result.summary,
            link: result.link
        )
    }

    func cancel(id: UUID) {
        guard let record = record(id: id), record.isActive else { return }
        transition(id: id, phase: .cancelled, message: "已取消")
    }

    /// Removes the given records. Callers cancel active ones first.
    @discardableResult
    func remove(ids: Set<UUID>) -> Int {
        let before = runs.count
        runs.removeAll { ids.contains($0.id) }
        let removed = before - runs.count
        if removed > 0 { persist() }
        return removed
    }

    @discardableResult
    func clearFinished() -> Int {
        let before = runs.count
        runs.removeAll { $0.phase.isTerminal }
        let removed = before - runs.count
        if removed > 0 { persist() }
        return removed
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let data = try encoder.encode(Array(runs.prefix(Self.maxStoredRuns)))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("GrokIsland RunJournal: save failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() -> [RunRecord] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([RunRecord].self, from: data).map { record in
                guard record.isActive else { return record }
                var interrupted = record
                interrupted.phase = .cancelled
                interrupted.message = Self.interruptedMessage
                return interrupted
            }
        } catch {
            NSLog("GrokIsland RunJournal: load failed: \(error.localizedDescription)")
            return []
        }
    }
}
