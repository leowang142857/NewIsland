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

/// Demo / scaffold executor. Simulates progress and returns a canned result.
///
/// TODO: POST `ExecutionRequest` JSON to `GrokBotTransport.localHTTPPlaceholder`
/// TODO: or hand off via `GrokBotTransport.urlScheme` — do not add API keys in this target.
struct GrokBotExecutor: ModuleExecuting {
    var kind: ExecutorKind { .grokBot }

    /// When true, skip sleeps so tests / previews can finish immediately.
    var instant: Bool

    init(instant: Bool = false) {
        self.instant = instant
    }

    func run(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) -> Void
    ) async throws -> ExecutionResult {
        let steps: [(Double, String)] = [
            (0.15, "Queued for Grok Bot (stub)"),
            (0.45, "Packaging \(request.resources.count) resource(s)"),
            (0.75, "Waiting on placeholder transport"),
            (1.0, "Demo response ready")
        ]

        for (fraction, message) in steps {
            try Task.checkCancellation()
            progress(ExecutionProgress(fraction: fraction, message: message))
            if !instant {
                try await Task.sleep(for: .milliseconds(350))
            }
        }

        let resourceList = request.resources.map(\.name).joined(separator: ", ")
        let extra = request.extraPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // TODO: Replace this body with the real Grok response.
        // Suggested payload (do not send secrets):
        // {
        //   "moduleId": "...",
        //   "name": "...",
        //   "prompt": "...",
        //   "resources": [{ "kind", "name", "location" }],
        //   "extraPrompt": "..."
        // }
        let detail = [
            "executor: grokBot (stub)",
            "module: \(request.module.displayName)",
            "prompt: \(request.module.prompt)",
            "resources: \(resourceList.isEmpty ? "(none)" : resourceList)",
            extra.isEmpty ? nil : "extra: \(extra)",
            "transport: \(GrokBotTransport.localHTTPPlaceholder.absoluteString)",
            "urlScheme: \(GrokBotTransport.urlSchemeURL(moduleID: request.module.id)?.absoluteString ?? GrokBotTransport.urlScheme)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        return ExecutionResult(
            summary: "Grok Bot demo finished for “\(request.module.displayName)”.",
            detail: detail
        )
    }
}
