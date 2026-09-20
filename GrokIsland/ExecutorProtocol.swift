import Foundation

/// Pluggable backend for a `FunctionModule`.
///
/// UI should never call an executor directly — go through `ExecutionRouter` / `IslandEngine`.
protocol ModuleExecuting: Sendable {
    var kind: ExecutorKind { get }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) -> Void
    ) async throws -> ExecutionResult
}
