import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages API (`POST /v1/messages`).
///
/// This is not OpenAI chat completions. The key is sent as `x-api-key` with
/// `anthropic-version`, and screenshots are base64 image blocks. Adaptive
/// thinking may prepend non-text blocks; only `type: text` is shown.
struct AnthropicMessagesClient: Sendable {
    static let apiVersion = "2023-06-01"
    /// Covers adaptive thinking plus the visible answer. Thinking tokens count toward this cap.
    static let maxTokens = 16_384

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
        if !attached.isEmpty, let reason = ModelImageInput.unsupportedReason(kind: .anthropic, model: modelName) {
            throw IslandError.executorFailed(reason)
        }

        var request = URLRequest(url: Self.endpoint(base: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.body(model: modelName, prompt: prompt, images: attached)
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ChatCompletionClient.httpError(
                status: response.statusCode,
                data: data,
                model: modelName,
                hadImages: !attached.isEmpty,
                apiKey: token
            )
        }
        return try AnthropicMessagesParser.assistantText(from: data)
    }

    /// `https://api.anthropic.com` becomes `https://api.anthropic.com/v1/messages`.
    static func endpoint(base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1/messages") {
            return URL(string: text) ?? base
        }
        if text.hasSuffix("/v1") {
            return URL(string: text + "/messages") ?? base
        }
        return URL(string: text + "/v1/messages") ?? base
    }

    /// Images come first, then the prompt, matching Anthropic's vision guidance.
    static func body(model: String, prompt: String, images: [PromptImage]) -> [String: Any] {
        var content: [[String: Any]] = []
        for image in images {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text", "text": prompt])
        return [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]]
        ]
    }
}

enum AnthropicMessagesParser {
    /// Joins `type: text` blocks. Thinking and other blocks are skipped.
    static func assistantText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]]
        else {
            throw IslandError.executorFailed("模型返回了无法识别的响应。")
        }
        let joined = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String
            else { return nil }
            return text
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw IslandError.executorFailed("模型没有返回文字。")
        }
        return joined
    }
}
