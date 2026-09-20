import Foundation

/// Transport placeholders for a future real Grok client. No secrets live here.
enum GrokBotTransport {
    /// TODO: Register and handle this URL scheme in the real Grok host app.
    static let urlScheme = "grok-island"

    /// TODO: Replace with the real local/remote endpoint when wiring Grok.
    static let localHTTPPlaceholder = URL(string: "http://127.0.0.1:8787/v1/run")!

    static func urlSchemeURL(moduleID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "run"
        components.queryItems = [URLQueryItem(name: "module", value: moduleID.uuidString)]
        return components.url
    }
}

/// JSON body to POST when a real client is wired. No tokens / API keys.
struct GrokBotWireRequest: Codable, Equatable, Sendable {
    var moduleId: UUID
    var name: String
    var prompt: String
    var extraPrompt: String?
    var resources: [GrokBotWireResource]
}

struct GrokBotWireResource: Codable, Equatable, Sendable {
    var kind: ResourceKind
    var name: String
    var location: String
}

extension ExecutionRequest {
    func grokWirePayload() -> GrokBotWireRequest {
        GrokBotWireRequest(
            moduleId: module.id,
            name: module.displayName,
            prompt: module.prompt,
            extraPrompt: extraPrompt,
            resources: resources.map {
                GrokBotWireResource(kind: $0.kind, name: $0.name, location: $0.location)
            }
        )
    }
}

/// Swap this when wiring a real Grok backend. `GrokBotExecutor` only forwards here.
protocol GrokBotClient: Sendable {
    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult
}

/// Demo client so the island is usable without a Grok backend.
struct DemoGrokBotClient: GrokBotClient {
    /// When true, skip sleeps so tests can finish immediately.
    var instant: Bool

    init(instant: Bool = false) {
        self.instant = instant
    }

    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        let steps: [(Double, String)] = [
            (0.15, "Queued for Grok Bot (stub)"),
            (0.45, "Packaging \(request.resources.count) resource(s)"),
            (0.75, "Waiting on placeholder transport"),
            (1.0, "Demo response ready")
        ]

        for (fraction, message) in steps {
            try Task.checkCancellation()
            await progress(ExecutionProgress(fraction: fraction, message: message))
            if !instant {
                try await Task.sleep(for: .milliseconds(350))
            }
        }

        let resourceList = request.resources.map(\.name).joined(separator: ", ")
        let extra = request.extraPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wire = request.grokWirePayload()

        // TODO: Replace this body with the real Grok response (see HTTPGrokBotClient).
        let detail = [
            "executor: grokBot (stub)",
            "module: \(wire.name)",
            "prompt: \(wire.prompt)",
            "resources: \(resourceList.isEmpty ? "(none)" : resourceList)",
            extra.isEmpty ? nil : "extra: \(extra)",
            "transport: \(GrokBotTransport.localHTTPPlaceholder.absoluteString)",
            "urlScheme: \(GrokBotTransport.urlSchemeURL(moduleID: wire.moduleId)?.absoluteString ?? GrokBotTransport.urlScheme)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        return ExecutionResult(
            summary: "Grok Bot demo finished for “\(wire.name)”.",
            detail: detail
        )
    }
}

/// TODO: POST `request.grokWirePayload()` to `endpoint`. Do not add API keys in this target.
struct HTTPGrokBotClient: GrokBotClient {
    var endpoint: URL

    init(endpoint: URL = GrokBotTransport.localHTTPPlaceholder) {
        self.endpoint = endpoint
    }

    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        await progress(ExecutionProgress(fraction: 0.1, message: "Grok HTTP client is not wired"))
        throw IslandError.executorFailed(
            "Grok HTTP client is not wired. POST \(endpoint.absoluteString) — no API keys in this target."
        )
    }
}

/// Facade executor. Default client is the demo stub; inject `HTTPGrokBotClient` later.
struct GrokBotExecutor: ModuleExecuting {
    var kind: ExecutorKind { .grokBot }
    var client: any GrokBotClient

    init(client: any GrokBotClient = DemoGrokBotClient()) {
        self.client = client
    }

    init(instant: Bool) {
        self.client = DemoGrokBotClient(instant: instant)
    }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        try await client.execute(request, progress: progress)
    }
}
