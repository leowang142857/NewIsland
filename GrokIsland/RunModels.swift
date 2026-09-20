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

    var isActive: Bool { phase.isActive }
}

struct ExecutionProgress: Equatable, Sendable {
    var fraction: Double
    var message: String

    init(fraction: Double, message: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

struct ExecutionResult: Equatable, Sendable {
    var summary: String
    var detail: String?
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
}
