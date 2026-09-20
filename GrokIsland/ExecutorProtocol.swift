import Foundation

/// Pluggable backend for a `FunctionModule`.
///
/// UI should never call an executor directly — go through `ExecutionRouter` / `IslandEngine`.
///
/// `progress` is async so updates are applied in order before the next step (no stale hops after success).
protocol ModuleExecuting: Sendable {
    var kind: ExecutorKind { get }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult
}
