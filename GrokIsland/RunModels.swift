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
    /// Where the run can be followed outside the island (e.g. the Cloud Agent page).
    var link: String? = nil

    var isActive: Bool { phase.isActive }
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
