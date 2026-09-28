import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

enum CheckState: String, Equatable, Sendable {
    case none
    case running
    case passed
    case failed
}

struct PullRequestActivity: Identifiable, Equatable, Sendable {
    var number: Int
    var title: String
    var url: String?
    var headRef: String?
    var checks: CheckState
    /// Open, but `main` already contains every change (`nothing-to-merge`).
    var isStale: Bool

    var id: Int { number }
}

/// Parses `origin pr list --json number,title,url,headRef,ciState,mergeability`.
enum OriginPRParser {
    static let jsonFields = "number,title,url,headRef,ciState,mergeability"

    static func parse(_ data: Data) throws -> [PullRequestActivity] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CursorAPIError.invalidResponse
        }
        return items.compactMap { item in
            guard let number = item["number"] as? Int else { return nil }
            return PullRequestActivity(
                number: number,
                title: item["title"] as? String ?? "#\(number)",
                url: item["url"] as? String,
                headRef: item["headRef"] as? String,
                checks: checkState(item["ciState"]),
                isStale: blockerKinds(item["mergeability"]).contains("nothing-to-merge")
            )
        }
    }

    static func checkState(_ ciState: Any?) -> CheckState {
        let groups = (ciState as? [String: Any])?["checkRunGroups"] as? [[String: Any]] ?? []
        let runs = groups.flatMap { $0["checkRuns"] as? [[String: Any]] ?? [] }
        guard !runs.isEmpty else { return .none }
        if runs.contains(where: { ($0["status"] as? String)?.lowercased() != "completed" }) {
            return .running
        }
        let failing: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        if runs.contains(where: { failing.contains(($0["conclusion"] as? String)?.lowercased() ?? "") }) {
            return .failed
        }
        return .passed
    }

    private static func blockerKinds(_ mergeability: Any?) -> Set<String> {
        let outer = mergeability as? [String: Any]
        let inner = outer?["mergeability"] as? [String: Any]
        let blockers = (inner?["blockers"] ?? outer?["blockers"]) as? [[String: Any]] ?? []
        return Set(blockers.compactMap { $0["kind"] as? String })
    }
}

/// Runs the signed-in `origin` CLI (Cursor-hosted repos) as a child process.
enum OriginCLI {
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/origin",
            "/opt/homebrew/bin/origin",
            "/usr/local/bin/origin"
        ]
    }

    static func executableURL() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func listOpenPRs(repo: String) async throws -> [PullRequestActivity] {
        guard let executable = executableURL() else {
            throw IslandError.executorFailed("没找到 origin CLI（~/.local/bin/origin），PR 状态不可用。")
        }
        let output = try await run(executable, arguments: [
            "pr", "list", "-R", repo, "--state", "open", "--limit", "30",
            "--json", OriginPRParser.jsonFields, "--color", "never"
        ])
        return try OriginPRParser.parse(output)
    }

    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 25) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: IslandError.executorFailed(
                        message.isEmpty ? "origin 退出码 \(process.terminationStatus)" : String(message.prefix(200))
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

struct CloudActivitySnapshot: Equatable, Sendable {
    /// Cloud Agents with a turn in flight.
    var agents: [CloudAgentSummary] = []
    /// Open PRs that still have something to merge.
    var pullRequests: [PullRequestActivity] = []
    var stalePullRequests: [PullRequestActivity] = []
    var agentNote: String?
    var prNote: String?
    var updatedAt: Date?

    var busyCount: Int { agents.count + pullRequests.count }
    var isBusy: Bool { busyCount > 0 }
    var hasFailingChecks: Bool { pullRequests.contains { $0.checks == .failed } }

    /// Changes whenever something starts, finishes, or flips CI state.
    var signature: [String] {
        agents.map(\.id).sorted() + pullRequests.map { "pr\($0.number):\($0.checks.rawValue)" }
    }
}

/// Polls Cloud Agents (Cursor API) and open PRs (origin CLI) for the island light.
@MainActor
final class CloudActivityMonitor: ObservableObject {
    typealias AgentFetcher = @Sendable (CursorCredentials) async throws -> [CloudAgentSummary]
    typealias PRFetcher = @Sendable (String) async throws -> [PullRequestActivity]

    @Published private(set) var snapshot = CloudActivitySnapshot()
    /// Bumps each time `snapshot.signature` changes, so the island can blink once.
    @Published private(set) var flashCount = 0
    @Published private(set) var isRefreshing = false

    static let busyInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 60

    private let storage: IslandSettingsStorage
    private let fetchAgents: AgentFetcher
    private let fetchPRs: PRFetcher
    private var loop: Task<Void, Never>?
    /// Set when settings change mid-fetch; the in-flight fetch read the old key / repo.
    private var rerunRequested = false

    init(
        storage: IslandSettingsStorage = IslandSettingsStorage(),
        fetchAgents: @escaping AgentFetcher = { credentials in
            try await CursorCloudAPI(apiKey: credentials.apiKey).listAgents()
        },
        fetchPRs: @escaping PRFetcher = { repo in
            try await OriginCLI.listOpenPRs(repo: repo)
        }
    ) {
        self.storage = storage
        self.fetchAgents = fetchAgents
        self.fetchPRs = fetchPRs
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.snapshot.isBusy ? Self.busyInterval : Self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Refresh unless the last fetch is only a few seconds old. `minimumAge: 0` means
    /// settings changed, so a fetch already in flight is followed by a fresh one.
    func refreshSoon(minimumAge: TimeInterval = 8) {
        if isRefreshing {
            if minimumAge <= 0 { rerunRequested = true }
            return
        }
        if let updated = snapshot.updatedAt, Date().timeIntervalSince(updated) < minimumAge { return }
        Task { await refresh() }
    }

    func refresh() async {
        if isRefreshing {
            rerunRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            rerunRequested = false
            await fetchOnce()
        } while rerunRequested
    }

    private func fetchOnce() async {
        let credentials = storage.credentials()
        let repo = storage.prRepo
        let fetchAgents = fetchAgents
        let fetchPRs = fetchPRs

        async let agentResult = Self.capture {
            guard let credentials else { return [CloudAgentSummary]?.none }
            return try await fetchAgents(credentials)
        }
        async let prResult = Self.capture { try await fetchPRs(repo) }

        var next = CloudActivitySnapshot(updatedAt: Date())
        switch await agentResult {
        case .success(let agents?):
            next.agents = agents.filter(\.isActive)
        case .success(nil):
            next.agentNote = "未设置 Cursor API key"
        case .failure(let error):
            next.agents = snapshot.agents
            next.agentNote = Self.describe(error)
        }
        switch await prResult {
        case .success(let prs):
            next.pullRequests = prs.filter { !$0.isStale }
            next.stalePullRequests = prs.filter(\.isStale)
        case .failure(let error):
            next.pullRequests = snapshot.pullRequests
            next.stalePullRequests = snapshot.stalePullRequests
            next.prNote = Self.describe(error)
        }
        apply(next)
    }

    /// Blink without a snapshot change (e.g. a local Grok run started or finished).
    func flash() {
        flashCount += 1
    }

    func apply(_ next: CloudActivitySnapshot) {
        let changed = next.signature != snapshot.signature
        snapshot = next
        if changed {
            flashCount += 1
        }
    }

    private static func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
