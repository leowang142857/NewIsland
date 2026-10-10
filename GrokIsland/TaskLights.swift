import Foundation

enum TaskLightKind: String, Equatable, Sendable {
    case grok
    case local
    case cloudAgent
    case pullRequest

    var label: String {
        switch self {
        case .grok: "Grok"
        case .local: "本地"
        case .cloudAgent: "Agent"
        case .pullRequest: "PR"
        }
    }
}

enum TaskLightState: String, Equatable, Sendable {
    case queued
    case waiting
    case running
    case succeeded
    case failed
    case cancelled
    /// A PR waiting to merge with no CI running.
    case idle

    var isAnimated: Bool {
        switch self {
        case .queued, .waiting, .running: true
        case .succeeded, .failed, .cancelled, .idle: false
        }
    }

    var label: String {
        switch self {
        case .queued: "排队中"
        case .waiting: "等你确认"
        case .running: "运行中"
        case .succeeded: "已完成"
        case .failed: "没成功"
        case .cancelled: "已取消"
        case .idle: "待合并"
        }
    }
}

/// One lamp on the island: a local run, a Cloud Agent, or a PR.
struct TaskLight: Identifiable, Equatable, Sendable {
    var id: String
    var kind: TaskLightKind
    var title: String
    var state: TaskLightState
    var progress: Double?
    var runID: UUID?
    var link: String?
}

/// Builds the per-task lights from the journal and the Cloud Agent / PR snapshot.
enum TaskLightBoard {
    /// Finished local runs keep a solid success / fail lamp this long.
    static let recentWindow: TimeInterval = 90

    static func lights(
        runs: [RunRecord],
        snapshot: CloudActivitySnapshot,
        now: Date = Date(),
        recentWindow: TimeInterval = recentWindow
    ) -> [TaskLight] {
        let boardRuns = runs.filter(\.showsActivityLight)
        let active = boardRuns.filter(\.isActive).map(light(for:))
        let recent = boardRuns
            .filter { $0.phase.isTerminal && now.timeIntervalSince($0.updatedAt) < recentWindow }
            .map(light(for:))
        let localLinks = Set(runs.compactMap(\.link))

        let agents = snapshot.agents
            .filter { agent in agent.url.map { !localLinks.contains($0) } ?? true }
            .map { agent in
                TaskLight(
                    id: "agent:\(agent.id)",
                    kind: .cloudAgent,
                    title: agent.displayName,
                    state: .running,
                    link: agent.url
                )
            }

        let prs = snapshot.pullRequests.map { pr in
            TaskLight(
                id: "pr:\(pr.number)",
                kind: .pullRequest,
                title: "#\(pr.number) \(pr.title)",
                state: state(for: pr.checks),
                link: pr.url
            )
        }

        return active + recent + agents + prs
    }

    static func light(for run: RunRecord) -> TaskLight {
        TaskLight(
            id: "run:\(run.id.uuidString)",
            kind: run.executor == .local ? .local : .grok,
            title: run.question.map { "\(run.moduleName)：\($0)" } ?? run.moduleName,
            state: state(for: run.phase),
            progress: run.phase == .running ? run.progress : nil,
            runID: run.id,
            link: run.link
        )
    }

    static func state(for phase: RunPhase) -> TaskLightState {
        switch phase {
        case .queued: .queued
        case .awaitingConfirmation: .waiting
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    static func state(for checks: CheckState) -> TaskLightState {
        switch checks {
        case .running: .running
        case .failed: .failed
        case .passed: .succeeded
        case .none: .idle
        }
    }
}
