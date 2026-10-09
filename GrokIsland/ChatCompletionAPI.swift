import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI-compatible `POST /chat/completions` client.
///
/// Images go out as `image_url` data URLs. A model that cannot take them fails with a
/// readable error — the screenshot is never dropped and then treated as a text-only question.
struct ChatCompletionClient: Sendable {
    var kind: ModelProviderKind
    var apiKey: String
    var model: String
    var baseURL: URL
    var transport: any HTTPTransport = URLSessionTransport()
    var timeout: TimeInterval = 600

    func complete(prompt: String, images: [PromptImage]) async throws -> String {
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw IslandError.executorFailed("先在设置里填写模型名。")
        }
        let attached = Array(images.prefix(GrokPromptBuilder.maxImages))
        if !attached.isEmpty, let reason = ModelImageInput.unsupportedReason(kind: kind, model: modelName) {
            throw IslandError.executorFailed(reason)
        }

        var request = URLRequest(url: Self.endpoint(base: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: modelName, prompt: prompt, images: attached))

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpError(status: response.statusCode, data: data, model: modelName, hadImages: !attached.isEmpty, apiKey: token)
        }
        return try ChatCompletionParser.assistantText(from: data)
    }

    static func endpoint(base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") {
            return URL(string: text) ?? base
        }
        return URL(string: text + "/chat/completions") ?? base
    }

    static func body(model: String, prompt: String, images: [PromptImage]) -> [String: Any] {
        let content: Any
        if images.isEmpty {
            content = prompt
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                let url = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            content = parts
        }
        return [
            "model": model,
            "messages": [["role": "user", "content": content]]
        ]
    }

    static func httpError(status: Int, data: Data, model: String, hadImages: Bool, apiKey: String) -> Error {
        let safe = redact(errorMessage(from: data), key: apiKey)
        if hadImages, let vision = ModelImageInput.apiRejectionMessage(status: status, body: safe, model: model) {
            return IslandError.executorFailed(vision)
        }
        let message: String
        switch status {
        case 401, 403:
            message = "API key 无效或没有权限（\(status)）。在设置里检查当前模型服务的密钥。"
        case 429:
            message = "模型服务请求太频繁，稍后再试。"
        default:
            message = safe.isEmpty ? "模型服务错误 \(status)" : "模型服务错误 \(status)：\(safe)"
        }
        return IslandError.executorFailed(message)
    }

    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
        }
        if let message = object["error"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return ""
    }

    /// Server bodies sometimes echo the token. It must not surface in the island.
    static func redact(_ text: String, key: String) -> String {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 4 else { return text }
        return text.replacingOccurrences(of: token, with: "[redacted]")
    }
}

enum ChatCompletionParser {
    static func assistantText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw IslandError.executorFailed("模型返回了无法识别的响应。")
        }
        if let text = textContent(message["content"]) {
            return text
        }
        if let reasoning = message["reasoning_content"] as? String {
            let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw IslandError.executorFailed("模型没有返回文字。")
    }

    private static func textContent(_ content: Any?) -> String? {
        if let string = content as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = content as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

/// Ask Grok and the shortcut buttons, through the provider's own message API.
struct ChatCompletionGrokClient: GrokBotClient {
    var configuration: ModelProviderConfiguration
    var transport: any HTTPTransport = URLSessionTransport()

    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        let payload = GrokPromptBuilder.build(request)
        let label = configuration.model.isEmpty ? configuration.kind.settingsTitle : configuration.model
        await progress(ExecutionProgress(fraction: 0.2, message: "正在请求 \(label)…"))
        let text = try await HostedModelAPI.complete(
            configuration: configuration,
            prompt: payload.text,
            images: payload.images,
            transport: transport
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await progress(ExecutionProgress(fraction: 1, message: "已收到回复"))
        return ExecutionResult(
            summary: GrokPromptBuilder.headline(of: trimmed) ?? "已完成",
            detail: trimmed.isEmpty ? "模型没有返回文字。" : trimmed
        )
    }
}

/// One prompt on the selected hosted model. Cursor Cloud Agents stays on its own client.
enum HostedModelAPI {
    static func complete(
        configuration: ModelProviderConfiguration,
        prompt: String,
        images: [PromptImage],
        transport: any HTTPTransport
    ) async throws -> String {
        switch configuration.kind {
        case .anthropic:
            return try await AnthropicMessagesClient(
                apiKey: configuration.apiKey,
                model: configuration.model,
                baseURL: configuration.baseURL,
                transport: transport
            ).complete(prompt: prompt, images: images)
        case .xai, .openai, .deepseek, .ollama, .compatible:
            return try await ChatCompletionClient(
                kind: configuration.kind,
                apiKey: configuration.apiKey,
                model: configuration.model,
                baseURL: configuration.baseURL,
                transport: transport
            ).complete(prompt: prompt, images: images)
        case .cursor:
            throw IslandError.executorFailed(ModelProviderMessages.notReady(.cursor))
        }
    }
}

/// Picks Cursor Cloud Agents or a hosted model API from the saved provider.
struct RoutedGrokClient: GrokBotClient {
    var resolve: @Sendable () -> ModelProviderResolution
    var transport: any HTTPTransport = URLSessionTransport()
    var pollInterval: Duration = .seconds(2)
    var timeout: TimeInterval = 20 * 60

    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        let resolution = resolve()
        guard let configuration = resolution.configuration else {
            throw IslandError.executorFailed(resolution.notReadyMessage)
        }
        if configuration.kind == .cursor {
            let cursor = CursorAgentGrokClient(
                credentials: { CursorCredentials(apiKey: configuration.apiKey, modelID: configuration.model) },
                transport: transport,
                pollInterval: pollInterval,
                timeout: timeout
            )
            return try await cursor.execute(request, progress: progress)
        }
        return try await ChatCompletionGrokClient(configuration: configuration, transport: transport)
            .execute(request, progress: progress)
    }
}

/// Split-task when the provider is a plain model API: planner, parallel subtasks, then a summary.
/// Each step is one model call. Worker failures stay in the journal the same way cloud agents do.
struct ChatSplitTaskOrchestrator: SplitTaskCollaborating {
    var configuration: ModelProviderConfiguration
    var transport: any HTTPTransport = URLSessionTransport()

    func collaborate(
        _ request: SplitTaskRequest,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitCollaborationResult {
        var images = Array(request.images.prefix(GrokPromptBuilder.maxImages))
        let attachment = GrokPromptBuilder.resourceSection(resources: request.resources, images: &images)
        let plan = try await plan(task: request.task, attachment: attachment, images: images, callbacks: callbacks)
        await callbacks.onPlan(plan)
        let outcomes = try await runWorkers(
            plan: plan,
            task: request.task,
            attachment: attachment,
            images: images,
            callbacks: callbacks
        )
        let narrative = try await summarize(task: request.task, outcomes: outcomes, callbacks: callbacks)
        return SplitTaskSummary.result(
            task: request.task,
            outcomes: outcomes,
            narrative: narrative,
            link: nil
        )
    }

    private func plan(
        task: String,
        attachment: String,
        images: [PromptImage],
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitPlan {
        let text = try await complete(
            prompt: SplitTaskPrompts.planner(task: task, attachment: attachment),
            images: images,
            activity: "正在拆分任务",
            progress: callbacks.onPlannerProgress
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IslandError.executorFailed("规划没有返回可执行的子任务。")
        }
        return try SplitPlanParser.parse(trimmed)
    }

    private func runWorkers(
        plan: SplitPlan,
        task: String,
        attachment: String,
        images: [PromptImage],
        callbacks: SplitTaskCallbacks
    ) async throws -> [SplitSubtaskOutcome] {
        try await withThrowingTaskGroup(of: (Int, SplitSubtaskOutcome).self) { group in
            for (index, subtask) in plan.subtasks.enumerated() {
                let siblings = plan.subtasks.enumerated().compactMap { offset, other in
                    offset == index ? nil : other.title
                }
                group.addTask {
                    let outcome = try await self.runWorker(
                        index: index,
                        subtask: subtask,
                        siblings: siblings,
                        task: task,
                        attachment: attachment,
                        images: images,
                        callbacks: callbacks
                    )
                    await callbacks.onSubtaskFinished(index, outcome)
                    return (index, outcome)
                }
            }
            var pairs: [(Int, SplitSubtaskOutcome)] = []
            for try await pair in group {
                pairs.append(pair)
            }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func runWorker(
        index: Int,
        subtask: SplitSubtask,
        siblings: [String],
        task: String,
        attachment: String,
        images: [PromptImage],
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitSubtaskOutcome {
        try Task.checkCancellation()
        let prompt = SplitTaskPrompts.worker(
            task: task,
            subtask: subtask,
            siblings: siblings,
            attachment: attachment
        )
        do {
            let text = try await complete(
                prompt: prompt,
                images: images,
                activity: subtask.title,
                progress: { progress in
                    await callbacks.onSubtaskProgress(index, progress)
                }
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SplitSubtaskOutcome(
                title: subtask.title,
                prompt: subtask.prompt,
                succeeded: true,
                text: trimmed.isEmpty ? "（没有文字结果）" : trimmed,
                link: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SplitSubtaskOutcome(
                title: subtask.title,
                prompt: subtask.prompt,
                succeeded: false,
                text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                link: nil
            )
        }
    }

    /// A failed summary still leaves every worker result in the combined markdown.
    private func summarize(
        task: String,
        outcomes: [SplitSubtaskOutcome],
        callbacks: SplitTaskCallbacks
    ) async throws -> String? {
        do {
            let text = try await complete(
                prompt: SplitTaskPrompts.summarizer(task: task, outcomes: outcomes),
                images: [],
                activity: "正在汇总",
                progress: callbacks.onSummaryProgress
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func complete(
        prompt: String,
        images: [PromptImage],
        activity: String,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> String {
        await progress(ExecutionProgress(fraction: 0.2, message: activity))
        let text = try await HostedModelAPI.complete(
            configuration: configuration,
            prompt: prompt,
            images: images,
            transport: transport
        )
        await progress(ExecutionProgress(fraction: 1, message: activity))
        return text
    }
}

/// Split-task router. Cursor keeps the cloud-agent orchestrator; other providers use their model API.
struct RoutedSplitTaskOrchestrator: SplitTaskCollaborating {
    var resolve: @Sendable () -> ModelProviderResolution
    var transport: any HTTPTransport = URLSessionTransport()
    var pollInterval: Duration = .seconds(2)
    var timeout: TimeInterval = 20 * 60

    func collaborate(
        _ request: SplitTaskRequest,
        callbacks: SplitTaskCallbacks
    ) async throws -> SplitCollaborationResult {
        let resolution = resolve()
        guard let configuration = resolution.configuration else {
            throw IslandError.executorFailed(resolution.notReadyMessage)
        }
        if configuration.kind == .cursor {
            let cursor = CursorSplitTaskOrchestrator(
                credentials: { CursorCredentials(apiKey: configuration.apiKey, modelID: configuration.model) },
                transport: transport,
                pollInterval: pollInterval,
                timeout: timeout
            )
            return try await cursor.collaborate(request, callbacks: callbacks)
        }
        return try await ChatSplitTaskOrchestrator(configuration: configuration, transport: transport)
            .collaborate(request, callbacks: callbacks)
    }
}
