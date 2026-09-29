import Foundation

enum ResourceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case file
    case folder
    case url

    var symbolName: String {
        switch self {
        case .file: "doc"
        case .folder: "folder"
        case .url: "link"
        }
    }
}

/// A reference to something the user dropped — path/URL metadata only, never file bytes.
struct ResourceItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ResourceKind
    var name: String
    /// Absolute file path, or a URL string for web links.
    var location: String
    var uti: String?
    var fileSize: Int64?
    var bookmarkData: Data?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ResourceKind,
        name: String,
        location: String,
        uti: String? = nil,
        fileSize: Int64? = nil,
        bookmarkData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.location = location
        self.uti = uti
        self.fileSize = fileSize
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }

    var url: URL? {
        switch kind {
        case .url:
            return URL(string: location)
        case .file, .folder:
            return URL(fileURLWithPath: location)
        }
    }
}

enum ExecutorKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case grokBot
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grokBot: "Grok Bot"
        case .local: "Local"
        }
    }
}

/// User-created functional capability (a named skill/action), persisted locally.
struct FunctionModule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Short prompt / config the executor should follow.
    var prompt: String
    var executor: ExecutorKind
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        executor: ExecutorKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.executor = executor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled module" : trimmed
    }
}

/// Local runs must pass through this confirmation payload before any Process / NSWorkspace work.
struct PendingLocalRun: Identifiable, Equatable, Sendable {
    var id: UUID
    var runID: UUID
    var module: FunctionModule
    var resources: [ResourceItem]
    var extraPrompt: String?
    var openAttachedFiles: Bool
    var confirmedShellCommand: String

    init(
        id: UUID = UUID(),
        runID: UUID,
        module: FunctionModule,
        resources: [ResourceItem],
        extraPrompt: String? = nil,
        openAttachedFiles: Bool = true,
        confirmedShellCommand: String = ""
    ) {
        self.id = id
        self.runID = runID
        self.module = module
        self.resources = resources
        self.extraPrompt = extraPrompt
        self.openAttachedFiles = openAttachedFiles
        self.confirmedShellCommand = confirmedShellCommand
    }
}

/// Chrome states for a future island frontend. Unused by the backend.
/// TODO(frontend): Drive NSPanel size / hover / drop highlight from this.
enum IslandState: String, Equatable, Sendable {
    case compact
    case hover
    case dropTarget
    case expanded
}

/// Result of dropping resources onto a module tile, used for the tile's success / fail light.
enum DropOutcome: Equatable, Sendable {
    case started(runID: UUID, itemCount: Int)
    case rejected(String)
}

enum IslandError: Error, LocalizedError, Equatable {
    case moduleNameEmpty
    case emptyInput
    case moduleNotFound
    case inboxEmpty
    case dropEmpty
    case deadlineTitleEmpty
    case deadlineNotFound
    case runNotFound
    case localConfirmationRequired
    case cancelled
    case pageCaptureFailed(String)
    case persistenceFailed(String)
    case executorFailed(String)

    var errorDescription: String? {
        switch self {
        case .moduleNameEmpty:
            return "Module name cannot be empty."
        case .emptyInput:
            return "Enter some text first."
        case .moduleNotFound:
            return "Function module was not found."
        case .inboxEmpty:
            return "Drop or select resources before running a module."
        case .dropEmpty:
            return "没读到可用的文件或链接，换一个再拖进来。"
        case .deadlineTitleEmpty:
            return "先写上 DDL 的内容。"
        case .deadlineNotFound:
            return "这条日程已经不在了。"
        case .runNotFound:
            return "Run was not found."
        case .localConfirmationRequired:
            return "Local executor requires an explicit confirmation."
        case .cancelled:
            return "Run was cancelled."
        case .pageCaptureFailed(let message):
            return message
        case .persistenceFailed(let message):
            return "Could not save modules: \(message)"
        case .executorFailed(let message):
            return message
        }
    }
}
