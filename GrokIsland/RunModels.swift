import Foundation

enum RunPhase: String, Codable, Equatable, Sendable {
    case queued
    case awaitingConfirmation
    case running
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .awaitingConfirmation, .running: false
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .awaitingConfirmation, .running: true
        case .succeeded, .failed, .cancelled: false
        }
    }
}

/// What started a run, so the journal can tell module runs from Grok questions.
enum RunOrigin: String, Codable, Equatable, Sendable {
    case module
    case quickAction
    case quickAsk
    /// Combined result of a split task. The activity rail shows the subtasks, not this row.
    case splitTask
    /// One parallel subtask of a split. Each one gets its own activity light.
    case splitSubtask
}

struct RunRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var moduleID: UUID?
    var moduleName: String
    var executor: ExecutorKind
    var resources: [ResourceItem]
    var extraPrompt: String?
    var phase: RunPhase
    var progress: Double
    var message: String
    var resultSummary: String?
    var createdAt: Date
    var updatedAt: Date
    /// Where the run can be followed outside the island (e.g. the Cloud Agent page).
    var link: String? = nil
    var origin: RunOrigin = .module
    /// What the user typed into 问 Grok, shown above the answer.
    var question: String? = nil
    /// Set on a split subtask so cancelling the parent can find its children.
    var parentRunID: UUID? = nil

    var isActive: Bool { phase.isActive }
    var isGrokAnswer: Bool { executor == .grokBot }
    /// The split parent is the combined result. Its subtasks are the lights.
    var showsActivityLight: Bool { origin != .splitTask }
}

extension RunRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, moduleID, moduleName, executor, resources, extraPrompt, phase, progress
        case message, resultSummary, createdAt, updatedAt, link, origin, question, parentRunID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        moduleID = try c.decodeIfPresent(UUID.self, forKey: .moduleID)
        moduleName = try c.decode(String.self, forKey: .moduleName)
        executor = try c.decode(ExecutorKind.self, forKey: .executor)
        resources = try c.decodeIfPresent([ResourceItem].self, forKey: .resources) ?? []
        extraPrompt = try c.decodeIfPresent(String.self, forKey: .extraPrompt)
        phase = try c.decode(RunPhase.self, forKey: .phase)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        link = try c.decodeIfPresent(String.self, forKey: .link)
        origin = try c.decodeIfPresent(RunOrigin.self, forKey: .origin) ?? .module
        question = try c.decodeIfPresent(String.self, forKey: .question)
        parentRunID = try c.decodeIfPresent(UUID.self, forKey: .parentRunID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(moduleID, forKey: .moduleID)
        try c.encode(moduleName, forKey: .moduleName)
        try c.encode(executor, forKey: .executor)
        try c.encode(resources, forKey: .resources)
        try c.encodeIfPresent(extraPrompt, forKey: .extraPrompt)
        try c.encode(phase, forKey: .phase)
        try c.encode(progress, forKey: .progress)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(resultSummary, forKey: .resultSummary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encodeIfPresent(parentRunID, forKey: .parentRunID)
    }
}

struct ExecutionProgress: Equatable, Sendable {
    var fraction: Double
    var message: String
    var link: String?

    init(fraction: Double, message: String, link: String? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
        self.link = link
    }
}

struct ExecutionResult: Equatable, Sendable {
    var summary: String
    var detail: String?
    var link: String? = nil
}

/// Image bytes sent alongside a prompt (screenshots, dropped pictures).
struct PromptImage: Equatable, Sendable {
    var data: Data
    var mimeType: String
}

struct LocalExecutionOptions: Equatable, Sendable {
    var openAttachedFiles: Bool
    var confirmedShellCommand: String?

    init(openAttachedFiles: Bool = true, confirmedShellCommand: String? = nil) {
        self.openAttachedFiles = openAttachedFiles
        self.confirmedShellCommand = confirmedShellCommand
    }

    var hasWork: Bool {
        openAttachedFiles || !(confirmedShellCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct ExecutionRequest: Sendable {
    var module: FunctionModule
    var resources: [ResourceItem]
    var extraPrompt: String?
    var local: LocalExecutionOptions?
    var images: [PromptImage] = []
}
