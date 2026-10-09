import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(GrokIslandCore)
@testable import GrokIslandCore
#else
@testable import GrokIsland
#endif

private final class ScriptedHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) -> (Int, String)
    private var stored: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, body) = handler(request)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func jsonObject(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

private func messageContent(_ body: [String: Any]) -> Any? {
    let messages = body["messages"] as? [[String: Any]]
    return messages?.first?["content"]
}

private func promptText(_ body: [String: Any]) -> String {
    let content = messageContent(body)
    if let text = content as? String { return text }
    let parts = content as? [[String: Any]] ?? []
    return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

private func imageURLs(_ body: [String: Any]) -> [String] {
    let parts = messageContent(body) as? [[String: Any]] ?? []
    return parts.compactMap { part in
        (part["image_url"] as? [String: Any])?["url"] as? String
    }
}

private func anthropicOK(_ text: String) -> (Int, String) {
    let object: [String: Any] = [
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "content": [
            ["type": "thinking", "thinking": "内部推理，不应展示"],
            ["type": "text", "text": text]
        ],
        "stop_reason": "end_turn"
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return (200, String(decoding: data, as: UTF8.self))
}

private func anthropicContent(_ body: [String: Any]) -> [[String: Any]] {
    let messages = body["messages"] as? [[String: Any]]
    return messages?.first?["content"] as? [[String: Any]] ?? []
}

private func chatOK(_ text: String) -> (Int, String) {
    let object: [String: Any] = [
        "choices": [["message": ["role": "assistant", "content": text]]]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return (200, String(decoding: data, as: UTF8.self))
}

private func temporaryStorage() -> (URL, IslandSettingsStorage) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("GrokIslandProvider-\(UUID().uuidString)", isDirectory: true)
    let storage = IslandSettingsStorage(folder: folder, defaultsSuite: "GrokIslandProvider-\(UUID().uuidString)")
    return (folder, storage)
}

private func sampleRequest(images: [PromptImage] = []) -> ExecutionRequest {
    let module = FunctionModule(name: "解答题目", prompt: "解答附图题目", executor: .grokBot)
    return ExecutionRequest(
        module: module,
        resources: [],
        extraPrompt: "网址：https://example.com",
        local: nil,
        images: images
    )
}

private func config(_ kind: ModelProviderKind, key: String, model: String, base: String) -> ModelProviderConfiguration {
    ModelProviderConfiguration(kind: kind, apiKey: key, model: model, baseURL: URL(string: base)!)
}

final class ModelProviderSettingsTests: XCTestCase {
    func testFreshInstallDoesNotAssumeCursor() {
        let (_, storage) = temporaryStorage()
        let resolution = storage.resolveProvider()
        XCTAssertEqual(resolution.kind, .xai)
        XCTAssertFalse(resolution.isExplicit)
        XCTAssertNil(resolution.configuration)
        XCTAssertNil(storage.credentials())
        XCTAssertTrue(resolution.notReadyMessage.contains("选一个服务"))
        XCTAssertTrue(resolution.notReadyMessage.contains("Anthropic（Claude）"))
        XCTAssertTrue(resolution.notReadyMessage.contains("Ollama"))
        XCTAssertFalse(resolution.notReadyMessage.contains("还没有 Cursor"))
    }

    func testExistingCursorKeyKeepsWorkingWithoutAProviderSetting() throws {
        let (_, storage) = temporaryStorage()
        try storage.saveAPIKey("  crsr_abc \n")
        storage.grokModelID = " grok-x "
        let resolution = storage.resolveProvider()
        XCTAssertEqual(resolution.kind, .cursor)
        XCTAssertFalse(resolution.isExplicit)
        XCTAssertEqual(resolution.configuration?.apiKey, "crsr_abc")
        XCTAssertEqual(resolution.configuration?.model, "grok-x")
        XCTAssertEqual(storage.credentials(), CursorCredentials(apiKey: "crsr_abc", modelID: "grok-x"))
        XCTAssertEqual(resolution.configuration?.baseURL.absoluteString, "https://api.cursor.com")
    }

    func testProviderKeysStayPrivateAndDoNotClobberCursor() throws {
        let (folder, storage) = temporaryStorage()
        try storage.saveAPIKey("crsr_keep")
        try storage.saveAPIKey("  xai-secret \n", for: .xai)
        storage.storedProviderKind = .xai

        let resolution = try XCTUnwrap(storage.resolveProvider().configuration)
        XCTAssertEqual(resolution.kind, .xai)
        XCTAssertEqual(resolution.apiKey, "xai-secret")
        XCTAssertEqual(resolution.model, "grok-4.6")
        XCTAssertEqual(resolution.baseURL.absoluteString, "https://api.x.ai/v1")
        XCTAssertEqual(storage.loadAPIKey(), "crsr_keep")
        XCTAssertEqual(storage.credentials()?.apiKey, "crsr_keep")

        let attributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("xai-api-key").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try storage.saveAPIKey(nil, for: .xai)
        XCTAssertNil(storage.loadAPIKey(for: .xai))
        XCTAssertEqual(storage.loadAPIKey(), "crsr_keep")
    }

    func testOllamaIsReadyWithoutAKeyAndCompatibleNeedsAllThreeFields() throws {
        let (_, storage) = temporaryStorage()
        storage.storedProviderKind = .ollama
        XCTAssertNil(storage.resolveProvider().configuration)
        storage.setModelID(" llava ", for: .ollama)
        let ollama = try XCTUnwrap(storage.resolveProvider().configuration)
        XCTAssertEqual(ollama.apiKey, "")
        XCTAssertEqual(ollama.model, "llava")
        XCTAssertEqual(ollama.baseURL.absoluteString, "http://127.0.0.1:11434/v1")

        storage.storedProviderKind = .compatible
        XCTAssertNil(storage.makeConfiguration(for: .compatible))
        storage.setBaseURLString("http://localhost:8080/v1/", for: .compatible)
        storage.setModelID("local-model", for: .compatible)
        XCTAssertNil(storage.makeConfiguration(for: .compatible))
        try storage.saveAPIKey("local-key", for: .compatible)
        let compatible = try XCTUnwrap(storage.makeConfiguration(for: .compatible))
        XCTAssertEqual(compatible.baseURL.absoluteString, "http://localhost:8080/v1")
        XCTAssertEqual(compatible.model, "local-model")
        XCTAssertEqual(compatible.apiKey, "local-key")

        storage.setBaseURLString("file:///tmp/nope", for: .compatible)
        XCTAssertNil(storage.makeConfiguration(for: .compatible))
    }

    func testAnthropicKeyIsSeparateAndUsesTheDefaultModel() throws {
        let (folder, storage) = temporaryStorage()
        try storage.saveAPIKey("crsr_keep")
        try storage.saveAPIKey("xai-keep", for: .xai)
        storage.storedProviderKind = .anthropic
        XCTAssertNil(storage.resolveProvider().configuration)
        XCTAssertTrue(storage.resolveProvider().notReadyMessage.contains("Anthropic（Claude）"))

        try storage.saveAPIKey("  sk-ant-secret \n", for: .anthropic)
        let resolution = try XCTUnwrap(storage.resolveProvider().configuration)
        XCTAssertEqual(resolution.kind, .anthropic)
        XCTAssertEqual(resolution.apiKey, "sk-ant-secret")
        XCTAssertEqual(resolution.model, ModelProviderKind.anthropic.defaultModel)
        XCTAssertEqual(resolution.baseURL.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(storage.loadAPIKey(), "crsr_keep")
        XCTAssertEqual(storage.loadAPIKey(for: .xai), "xai-keep")
        XCTAssertEqual(storage.modelID(for: .openai), "gpt-4o")

        let attributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("anthropic-api-key").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        storage.setModelID(" claude-haiku-5-5 ", for: .anthropic)
        XCTAssertEqual(storage.modelID(for: .anthropic), "claude-haiku-5-5")
        XCTAssertEqual(storage.modelID(for: .openai), "gpt-4o")
        XCTAssertEqual(storage.loadAPIKey(for: .openai), nil)

        try storage.saveAPIKey(nil, for: .anthropic)
        XCTAssertNil(storage.loadAPIKey(for: .anthropic))
        XCTAssertEqual(storage.loadAPIKey(), "crsr_keep")
        XCTAssertEqual(storage.loadAPIKey(for: .xai), "xai-keep")
    }

    func testAnthropicProviderMetadata() {
        let kind = ModelProviderKind.anthropic
        XCTAssertEqual(kind.settingsTitle, "Anthropic（Claude）")
        XCTAssertEqual(kind.defaultModel, "claude-sonnet-5-5")
        XCTAssertEqual(kind.defaultBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(kind.modelPlaceholder, "claude-sonnet-5-5")
        XCTAssertEqual(kind.keyPlaceholder, "sk-ant-…")
        XCTAssertEqual(kind.secretFileName, "anthropic-api-key")
        XCTAssertEqual(kind.docsURL, URL(string: "https://console.anthropic.com/settings/keys"))
        XCTAssertEqual(kind.docsLinkTitle, "获取 API key")
        XCTAssertEqual(kind.keySectionTitle, "API key")
        XCTAssertTrue(kind.requiresAPIKey)
        XCTAssertFalse(kind.allowsCustomBaseURL)
        XCTAssertTrue(ModelProviderKind.allCases.contains(.anthropic))
        XCTAssertTrue(ModelProviderMessages.settingsHint.contains("Anthropic（Claude）"))
    }

    func testExplicitCursorWithoutAKeyStillNamesCursor() {
        let (_, storage) = temporaryStorage()
        storage.storedProviderKind = .cursor
        let resolution = storage.resolveProvider()
        XCTAssertNil(resolution.configuration)
        XCTAssertTrue(resolution.notReadyMessage.contains("Cursor API key"))
    }
}

final class ChatCompletionClientTests: XCTestCase {
    func testEndpointsKeepTheProviderBasePath() {
        XCTAssertEqual(
            ChatCompletionClient.endpoint(base: URL(string: "https://api.x.ai/v1")!).absoluteString,
            "https://api.x.ai/v1/chat/completions"
        )
        XCTAssertEqual(
            ChatCompletionClient.endpoint(base: URL(string: "https://api.openai.com/v1")!).absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            ChatCompletionClient.endpoint(base: URL(string: "https://api.deepseek.com")!).absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            ChatCompletionClient.endpoint(base: URL(string: "http://127.0.0.1:11434/v1/")!).absoluteString,
            "http://127.0.0.1:11434/v1/chat/completions"
        )
    }

    func testEachHostedProviderSendsChatCompletionsWithTheImage() async throws {
        let png = PromptImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let cases: [(ModelProviderKind, String, String, String)] = [
            (.xai, "xai-test-key", "grok-4.6", "https://api.x.ai/v1"),
            (.openai, "sk-openai", "gpt-4o", "https://api.openai.com/v1"),
            (.deepseek, "sk-deepseek", "deepseek-flash", "https://api.deepseek.com")
        ]
        for (kind, key, model, base) in cases {
            let transport = ScriptedHTTP { _ in chatOK("### 第 1 题\n答案：42") }
            let client = ChatCompletionGrokClient(
                configuration: config(kind, key: key, model: model, base: base),
                transport: transport
            )
            let result = try await client.execute(sampleRequest(images: [png])) { _ in }
            XCTAssertEqual(result.summary, "第 1 题")
            XCTAssertEqual(result.detail, "### 第 1 题\n答案：42")
            let request = try XCTUnwrap(transport.snapshot().first)
            XCTAssertEqual(request.url?.absoluteString, ChatCompletionClient.endpoint(base: URL(string: base)!).absoluteString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
            let body = jsonObject(request)
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertFalse(promptText(body).contains(key))
            XCTAssertTrue(promptText(body).contains("解答附图题目"))
            XCTAssertTrue(promptText(body).contains("https://example.com"))
            XCTAssertEqual(imageURLs(body), ["data:image/png;base64,\(png.data.base64EncodedString())"])
            let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(raw.contains(key))
        }
    }

    func testOllamaOmitsTheAuthorizationHeaderWhenNoKeyIsSet() async throws {
        let transport = ScriptedHTTP { _ in chatOK("本地回答") }
        let client = ChatCompletionGrokClient(
            configuration: config(.ollama, key: "", model: "llava", base: "http://127.0.0.1:11434/v1"),
            transport: transport
        )
        let result = try await client.execute(sampleRequest()) { _ in }
        XCTAssertEqual(result.detail, "本地回答")
        let request = try XCTUnwrap(transport.snapshot().first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(jsonObject(request)["model"] as? String, "llava")
        XCTAssertTrue(messageContent(jsonObject(request)) is String)
    }

    func testTextOnlyModelsFailBeforeTheRequestWhenAnImageIsAttached() async {
        let transport = ScriptedHTTP { _ in
            (500, #"{"error":{"message":"should not be called"}}"#)
        }
        let client = ChatCompletionGrokClient(
            configuration: config(.deepseek, key: "sk-deep", model: "deepseek-v4-pro", base: "https://api.deepseek.com"),
            transport: transport
        )
        let png = PromptImage(data: Data([1, 2, 3]), mimeType: "image/png")
        do {
            _ = try await client.execute(sampleRequest(images: [png])) { _ in }
            XCTFail("expected a vision refusal")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("不能接收图片"))
            XCTAssertTrue(error.localizedDescription.contains("deepseek-v4-pro"))
            XCTAssertFalse(error.localizedDescription.contains("sk-deep"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(transport.snapshot().isEmpty)
    }

    func testAPIImageRejectionIsReadableAndDoesNotEchoTheKey() async {
        let secret = "sk-super-secret-value"
        let transport = ScriptedHTTP { _ in
            (400, #"{"error":{"message":"This model does not support image input for \#(secret)"}}"#)
        }
        let client = ChatCompletionClient(
            kind: .ollama,
            apiKey: secret,
            model: "llama3.2",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            transport: transport
        )
        let png = PromptImage(data: Data([9]), mimeType: "image/png")
        do {
            _ = try await client.complete(prompt: "看这张图", images: [png])
            XCTFail("expected the image rejection")
        } catch let error as IslandError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("不能接收图片"))
            XCTAssertTrue(text.contains("llama3.2"))
            XCTAssertFalse(text.contains(secret))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGenericHTTPErrorRedactsTheKey() async {
        let secret = "sk-super-secret-value"
        let transport = ScriptedHTTP { _ in
            (500, #"{"error":{"message":"upstream failed for \#(secret)"}}"#)
        }
        let client = ChatCompletionClient(
            kind: .openai,
            apiKey: secret,
            model: "gpt-4o",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            transport: transport
        )
        do {
            _ = try await client.complete(prompt: "hi", images: [])
            XCTFail("expected an HTTP error")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("[redacted]"))
            XCTAssertTrue(error.localizedDescription.contains("500"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnauthorizedDoesNotIncludeTheResponseBody() async {
        let secret = "sk-super-secret-value"
        let transport = ScriptedHTTP { _ in
            (401, #"{"error":{"message":"bad \#(secret)"}}"#)
        }
        let client = ChatCompletionClient(
            kind: .xai,
            apiKey: secret,
            model: "grok-4.6",
            baseURL: URL(string: "https://api.x.ai/v1")!,
            transport: transport
        )
        do {
            _ = try await client.complete(prompt: "hi", images: [])
            XCTFail("expected 401")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnthropicMessagesSendsImagesAsContentBlocks() async throws {
        let png = PromptImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let secret = "sk-ant-test-key"
        let transport = ScriptedHTTP { _ in anthropicOK("### 第 1 题\n答案：42") }
        let client = ChatCompletionGrokClient(
            configuration: config(.anthropic, key: secret, model: "claude-sonnet-5-5", base: "https://api.anthropic.com"),
            transport: transport
        )
        let result = try await client.execute(sampleRequest(images: [png])) { _ in }
        XCTAssertEqual(result.summary, "第 1 题")
        XCTAssertEqual(result.detail, "### 第 1 题\n答案：42")

        let request = try XCTUnwrap(transport.snapshot().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), secret)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), AnthropicMessagesClient.apiVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = jsonObject(request)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicMessagesClient.maxTokens)
        XCTAssertNil(body["temperature"])
        let content = anthropicContent(body)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, png.data.base64EncodedString())
        XCTAssertEqual(content[1]["type"] as? String, "text")
        let text = try XCTUnwrap(content[1]["text"] as? String)
        XCTAssertTrue(text.contains("解答附图题目"))
        XCTAssertTrue(text.contains("https://example.com"))
        XCTAssertFalse(text.contains(secret))
        let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains(secret))
        XCTAssertFalse(raw.contains("image_url"))
    }

    func testAnthropicEndpointAndParser() throws {
        XCTAssertEqual(
            AnthropicMessagesClient.endpoint(base: URL(string: "https://api.anthropic.com")!).absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AnthropicMessagesClient.endpoint(base: URL(string: "https://api.anthropic.com/")!).absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AnthropicMessagesClient.endpoint(base: URL(string: "https://api.anthropic.com/v1")!).absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AnthropicMessagesClient.endpoint(base: URL(string: "https://api.anthropic.com/v1/messages")!).absoluteString,
            "https://api.anthropic.com/v1/messages"
        )

        let mixed = try AnthropicMessagesParser.assistantText(from: Data(
            #"{"content":[{"type":"thinking","thinking":"先想想"},{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}]}"#.utf8
        ))
        XCTAssertEqual(mixed, "第一段\n第二段")
        XCTAssertThrowsError(try AnthropicMessagesParser.assistantText(from: Data(
            #"{"content":[{"type":"thinking","thinking":"只有推理"}]}"#.utf8
        )))
    }

    func testAnthropicHTTPErrorRedactsTheKey() async {
        let secret = "sk-ant-super-secret"
        let transport = ScriptedHTTP { _ in
            (401, #"{"type":"error","error":{"type":"authentication_error","message":"bad \#(secret)"}}"#)
        }
        let client = AnthropicMessagesClient(
            apiKey: secret,
            model: "claude-sonnet-5-5",
            baseURL: URL(string: "https://api.anthropic.com")!,
            transport: transport
        )
        do {
            _ = try await client.complete(prompt: "hi", images: [])
            XCTFail("expected 401")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnthropicImageRejectionIsReadable() async {
        let secret = "sk-ant-super-secret"
        let transport = ScriptedHTTP { _ in
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"This model does not support image input for \#(secret)"}}"#)
        }
        let client = AnthropicMessagesClient(
            apiKey: secret,
            model: "claude-sonnet-5-5",
            baseURL: URL(string: "https://api.anthropic.com")!,
            transport: transport
        )
        let png = PromptImage(data: Data([9]), mimeType: "image/png")
        do {
            _ = try await client.complete(prompt: "看这张图", images: [png])
            XCTFail("expected the image rejection")
        } catch let error as IslandError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("不能接收图片"))
            XCTAssertTrue(text.contains("claude-sonnet-5-5"))
            XCTAssertFalse(text.contains(secret))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testParserReadsStringAndPartContent() throws {
        let string = try ChatCompletionParser.assistantText(from: Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8))
        XCTAssertEqual(string, "你好")
        let parts = try ChatCompletionParser.assistantText(from: Data(
            #"{"choices":[{"message":{"content":[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}]}}]}"#.utf8
        ))
        XCTAssertEqual(parts, "第一段\n第二段")
        let reasoning = try ChatCompletionParser.assistantText(from: Data(
            #"{"choices":[{"message":{"content":null,"reasoning_content":"想过了"}}]}"#.utf8
        ))
        XCTAssertEqual(reasoning, "想过了")
    }
}

/// Canned chat completions for the model-API split orchestrator.
private final class ChatSplitHTTP: HTTPTransport, @unchecked Sendable {
    enum ReplyWire: Sendable {
        case chatCompletions
        case anthropicMessages
    }

    struct Script: Sendable {
        var planner: String
        var worker: @Sendable (String) -> (Int, String)
        var summaryStatus: Int = 200
        var summaryText: String = "汇总完成"
        var workerDelay: Duration = .milliseconds(1)
        var wire: ReplyWire = .chatCompletions
    }

    private let lock = NSLock()
    private let script: Script
    private var requests: [URLRequest] = []
    private var inFlightWorkers = 0
    private var maxInFlightWorkers = 0

    init(_ script: Script) { self.script = script }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = jsonObject(request)
        let prompt = promptText(body)
        let isWorker = prompt.contains("你的子任务")
        begin(request, isWorker: isWorker)
        if isWorker { try await Task.sleep(for: script.workerDelay) }
        let response = finish(prompt: prompt, isWorker: isWorker)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
        return (Data(response.1.utf8), http)
    }

    func snapshot() -> (requests: [URLRequest], maxInFlightWorkers: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, maxInFlightWorkers)
    }

    private func begin(_ request: URLRequest, isWorker: Bool) {
        lock.lock()
        requests.append(request)
        if isWorker {
            inFlightWorkers += 1
            maxInFlightWorkers = max(maxInFlightWorkers, inFlightWorkers)
        }
        lock.unlock()
    }

    private func finish(prompt: String, isWorker: Bool) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        if isWorker { inFlightWorkers -= 1 }
        if prompt.contains("你是规划 agent") { return ok(script.planner) }
        if prompt.contains("你是汇总 agent") {
            if script.summaryStatus != 200 {
                return (script.summaryStatus, #"{"error":{"message":"summary down"}}"#)
            }
            return ok(script.summaryText)
        }
        if isWorker {
            let (status, text) = script.worker(prompt)
            if status != 200 { return (status, #"{"error":{"message":"\#(text)"}}"#) }
            return ok(text)
        }
        return ok("快捷按钮的回答")
    }

    private func ok(_ text: String) -> (Int, String) {
        switch script.wire {
        case .chatCompletions: return chatOK(text)
        case .anthropicMessages: return anthropicOK(text)
        }
    }
}

private func planJSON(_ titles: [String]) -> String {
    let items = titles.map { #"{"title":"\#($0)","prompt":"做\#($0)"}"# }.joined(separator: ",")
    return """
    ```json
    {"subtasks":[\(items)]}
    ```
    """
}

final class ChatSplitOrchestratorTests: XCTestCase {
    func testWorkersRunInParallelAndPartialFailureStaysMarked() async throws {
        let api = ChatSplitHTTP(.init(
            planner: planJSON(["调研", "起草"]),
            worker: { prompt in
                if prompt.contains("你的子任务：起草") { return (500, "写挂了") }
                return (200, "发现 A")
            },
            summaryText: "调研可用，起草没有完成。",
            workerDelay: .milliseconds(80)
        ))
        let image = PromptImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let result = try await ChatSplitTaskOrchestrator(
            configuration: config(.openai, key: "sk-test", model: "gpt-4o", base: "https://api.openai.com/v1"),
            transport: api
        ).collaborate(
            SplitTaskRequest(task: "写报告", resources: [], images: [image]),
            callbacks: .ignore
        )

        XCTAssertGreaterThanOrEqual(api.snapshot().maxInFlightWorkers, 2)
        XCTAssertEqual(result.headline, "1/2 完成，1 个失败")
        XCTAssertTrue(result.anySucceeded)
        XCTAssertTrue(result.markdown.contains("发现 A"))
        XCTAssertTrue(result.markdown.contains("调研 \(SplitTaskSummary.doneMark)"))
        XCTAssertTrue(result.markdown.contains("起草 \(SplitTaskSummary.failedMark)"))
        XCTAssertTrue(result.markdown.contains("写挂了"))
        XCTAssertTrue(result.markdown.contains("调研可用，起草没有完成。"))

        let posts = api.snapshot().requests
        XCTAssertEqual(posts.count, 4)
        XCTAssertTrue(posts.allSatisfy { $0.url?.path == "/v1/chat/completions" })
        XCTAssertTrue(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test" })
        let workers = posts.filter { promptText(jsonObject($0)).contains("你的子任务") }
        XCTAssertEqual(workers.count, 2)
        for worker in workers {
            XCTAssertEqual(imageURLs(jsonObject(worker)).first, "data:image/png;base64,\(image.data.base64EncodedString())")
        }
        let summary = try XCTUnwrap(posts.first { promptText(jsonObject($0)).contains("你是汇总 agent") })
        let summaryPrompt = promptText(jsonObject(summary))
        XCTAssertTrue(summaryPrompt.contains("发现 A"))
        XCTAssertTrue(summaryPrompt.contains("写挂了"))
        XCTAssertTrue(imageURLs(jsonObject(summary)).isEmpty)
        XCTAssertTrue(messageContent(jsonObject(summary)) is String)
    }

    func testSummaryFailureStillKeepsWorkerResults() async throws {
        let api = ChatSplitHTTP(.init(
            planner: planJSON(["调研", "起草"]),
            worker: { _ in (200, "做好了") },
            summaryStatus: 503
        ))
        let result = try await ChatSplitTaskOrchestrator(
            configuration: config(.deepseek, key: "sk-ds", model: "deepseek-flash", base: "https://api.deepseek.com"),
            transport: api
        ).collaborate(
            SplitTaskRequest(task: "写报告", resources: [], images: []),
            callbacks: .ignore
        )
        XCTAssertEqual(result.headline, "已汇总 2 个子任务")
        XCTAssertTrue(result.markdown.contains("没有返回正文"))
        XCTAssertTrue(result.markdown.contains("做好了"))
        XCTAssertFalse(result.markdown.contains(SplitTaskSummary.failedMark))
    }

    func testAnthropicSplitPostsMessagesWithImageBlocks() async throws {
        let api = ChatSplitHTTP(.init(
            planner: planJSON(["调研", "起草"]),
            worker: { prompt in
                if prompt.contains("你的子任务：起草") { return (500, "写挂了") }
                return (200, "发现 A")
            },
            summaryText: "调研可用，起草没有完成。",
            wire: .anthropicMessages
        ))
        let image = PromptImage(data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let result = try await ChatSplitTaskOrchestrator(
            configuration: config(.anthropic, key: "sk-ant-split", model: "claude-sonnet-5-5", base: "https://api.anthropic.com/"),
            transport: api
        ).collaborate(
            SplitTaskRequest(task: "写报告", resources: [], images: [image]),
            callbacks: .ignore
        )

        XCTAssertEqual(result.headline, "1/2 完成，1 个失败")
        XCTAssertTrue(result.markdown.contains("发现 A"))
        XCTAssertTrue(result.markdown.contains("写挂了"))
        let posts = api.snapshot().requests
        XCTAssertEqual(posts.count, 4)
        XCTAssertTrue(posts.allSatisfy { $0.url?.absoluteString == "https://api.anthropic.com/v1/messages" })
        XCTAssertTrue(posts.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "sk-ant-split" })
        XCTAssertTrue(posts.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01" })
        XCTAssertTrue(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let workers = posts.filter { promptText(jsonObject($0)).contains("你的子任务") }
        XCTAssertEqual(workers.count, 2)
        for worker in workers {
            let blocks = anthropicContent(jsonObject(worker))
            let source = blocks.first?["source"] as? [String: Any]
            XCTAssertEqual(blocks.first?["type"] as? String, "image")
            XCTAssertEqual(source?["media_type"] as? String, "image/jpeg")
            XCTAssertEqual(source?["data"] as? String, image.data.base64EncodedString())
        }
        let summary = try XCTUnwrap(posts.first { promptText(jsonObject($0)).contains("你是汇总 agent") })
        let summaryBlocks = anthropicContent(jsonObject(summary))
        XCTAssertEqual(summaryBlocks.count, 1)
        XCTAssertEqual(summaryBlocks.first?["type"] as? String, "text")
    }

    func testPlannerImageRefusalDoesNotStartWorkers() async {
        let api = ChatSplitHTTP(.init(
            planner: planJSON(["调研", "起草"]),
            worker: { _ in (200, "不应该跑") }
        ))
        let image = PromptImage(data: Data([1]), mimeType: "image/png")
        do {
            _ = try await ChatSplitTaskOrchestrator(
                configuration: config(.openai, key: "sk", model: "gpt-3.5-turbo", base: "https://api.openai.com/v1"),
                transport: api
            ).collaborate(
                SplitTaskRequest(task: "看图写报告", resources: [], images: [image]),
                callbacks: .ignore
            )
            XCTFail("expected the planner to refuse the image")
        } catch let error as IslandError {
            XCTAssertTrue(error.localizedDescription.contains("不能接收图片"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(api.snapshot().requests.isEmpty)
    }
}

@MainActor
final class RoutedProviderEngineTests: XCTestCase {
    func testShortcutAskAndSplitUseTheModelAPI() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transport = ChatSplitHTTP(.init(
            planner: planJSON(["调研", "起草"]),
            worker: { prompt in
                if prompt.contains("你的子任务：起草") { return (500, "写挂了") }
                return (200, "发现 A")
            },
            summaryText: "汇总正文"
        ))
        let resolution = ModelProviderResolution(
            kind: .xai,
            isExplicit: true,
            configuration: config(.xai, key: "xai-key", model: "grok-4.6", base: "https://api.x.ai/v1")
        )
        let engine = IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(fileURL: folder.appendingPathComponent("runs.json")),
            grokBot: GrokBotExecutor(client: RoutedGrokClient(
                resolve: { resolution },
                transport: transport,
                pollInterval: .milliseconds(1)
            )),
            collaborator: RoutedSplitTaskOrchestrator(
                resolve: { resolution },
                transport: transport,
                pollInterval: .milliseconds(1)
            )
        )

        let png = PromptImage(data: Data([0x89, 0x50]), mimeType: "image/png")
        let page = PageSnapshot(
            appName: "Safari",
            windowTitle: "作业",
            pageURL: "https://example.com/q",
            screenshot: png,
            captureNote: nil
        )
        let shortcut = try engine.runQuickAction(.solveProblems, page: page)
        try await waitUntil { engine.journal.record(id: shortcut.id)?.phase == .succeeded }
        let shortcutRecord = try XCTUnwrap(engine.journal.record(id: shortcut.id))
        XCTAssertEqual(shortcutRecord.origin, .quickAction)
        XCTAssertEqual(shortcutRecord.resultSummary, "快捷按钮的回答")

        let asked = try engine.runQuickAction(.askAboutPage, page: page, question: "这题怎么做")
        try await waitUntil { engine.journal.record(id: asked.id)?.phase == .succeeded }
        XCTAssertEqual(engine.journal.record(id: asked.id)?.origin, .quickAsk)

        let parent = try engine.splitTask("写一份报告")
        try await waitUntil { engine.journal.record(id: parent.id)?.phase == .succeeded }
        let saved = try XCTUnwrap(engine.journal.record(id: parent.id))
        XCTAssertEqual(saved.origin, .splitTask)
        XCTAssertEqual(saved.message, "1/2 完成，1 个失败")
        let summary = try XCTUnwrap(saved.resultSummary)
        XCTAssertTrue(summary.contains("汇总正文"))
        XCTAssertTrue(summary.contains("发现 A"))
        XCTAssertTrue(summary.contains("起草 \(SplitTaskSummary.failedMark)"))

        let children = engine.runs.filter { $0.origin == .splitSubtask }
        XCTAssertEqual(Set(children.map(\.moduleName)), ["调研", "起草"])
        XCTAssertEqual(children.first { $0.moduleName == "起草" }?.phase, .failed)
        XCTAssertEqual(children.first { $0.moduleName == "调研" }?.phase, .succeeded)
        let lights = TaskLightBoard.lights(runs: engine.runs, snapshot: CloudActivitySnapshot())
        let splitLights = lights.filter { $0.title == "调研" || $0.title == "起草" }
        XCTAssertEqual(Set(splitLights.map(\.title)), ["调研", "起草"])
        XCTAssertFalse(lights.contains { $0.runID == parent.id })
        XCTAssertEqual(splitLights.first { $0.title == "起草" }?.state, .failed)
        XCTAssertEqual(splitLights.first { $0.title == "调研" }?.state, .succeeded)

        let calls = transport.snapshot().requests
        XCTAssertTrue(calls.allSatisfy { $0.url?.host == "api.x.ai" })
        XCTAssertTrue(calls.allSatisfy { $0.url?.path == "/v1/chat/completions" })
        XCTAssertFalse(calls.contains { $0.url?.path.contains("/v1/agents") == true })
        let shortcutCall = try XCTUnwrap(calls.first { promptText(jsonObject($0)).contains("解答附图") })
        XCTAssertEqual(shortcutCall.value(forHTTPHeaderField: "Authorization"), "Bearer xai-key")
        XCTAssertFalse(String(decoding: shortcutCall.httpBody ?? Data(), as: UTF8.self).contains("xai-key"))
        XCTAssertEqual(
            imageURLs(jsonObject(shortcutCall)).first,
            "data:image/png;base64,\(png.data.base64EncodedString())"
        )
    }

    func testSelectingAnthropicUsesMessagesForAskAndShortcuts() async throws {
        let transport = ScriptedHTTP { _ in anthropicOK("看完了") }
        let resolution = ModelProviderResolution(
            kind: .anthropic,
            isExplicit: true,
            configuration: config(.anthropic, key: "sk-ant-route", model: "claude-sonnet-5-5", base: "https://api.anthropic.com")
        )
        let client = RoutedGrokClient(resolve: { resolution }, transport: transport, pollInterval: .milliseconds(1))
        let png = PromptImage(data: Data([0x89, 0x50]), mimeType: "image/png")
        let result = try await client.execute(sampleRequest(images: [png])) { _ in }
        XCTAssertEqual(result.detail, "看完了")
        let request = try XCTUnwrap(transport.snapshot().first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-route")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(transport.snapshot().contains { $0.url?.path.contains("chat/completions") == true })
        XCTAssertFalse(transport.snapshot().contains { $0.url?.path.contains("/v1/agents") == true })
    }

    func testCursorProviderStillCreatesACloudAgent() async throws {
        let transport = ScriptedHTTP { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/v1/agents" {
                return (200, #"{"agent":{"id":"bc-1","status":"ACTIVE","url":"https://cursor.com/agents/bc-1"},"run":{"id":"run-1","status":"FINISHED","result":"云端回答"}}"#)
            }
            return (404, #"{"error":{"message":"unexpected \(path)"}}"#)
        }
        let resolution = ModelProviderResolution(
            kind: .cursor,
            isExplicit: true,
            configuration: config(.cursor, key: "crsr_test", model: "grok-test", base: "https://api.cursor.com")
        )
        let client = RoutedGrokClient(
            resolve: { resolution },
            transport: transport,
            pollInterval: .milliseconds(1)
        )
        let result = try await client.execute(sampleRequest()) { _ in }
        XCTAssertEqual(result.detail, "云端回答")
        XCTAssertEqual(result.link, "https://cursor.com/agents/bc-1")
        let create = try XCTUnwrap(transport.snapshot().first { $0.url?.path == "/v1/agents" })
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer crsr_test")
        XCTAssertTrue(transport.snapshot().allSatisfy { $0.url?.path != "/chat/completions" })
    }

    func testMissingProviderFailsTheShortcutWithSetupGuidance() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokIslandMissing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = IslandEngine(
            moduleStore: ModuleStore(fileURL: folder.appendingPathComponent("m.json")),
            inbox: ResourceInbox(),
            journal: RunJournal(fileURL: folder.appendingPathComponent("runs.json")),
            grokBot: GrokBotExecutor(client: RoutedGrokClient(resolve: {
                ModelProviderResolution(kind: .xai, isExplicit: false, configuration: nil)
            }))
        )
        let page = PageSnapshot(appName: "Safari", windowTitle: nil, pageURL: "https://example.com", screenshot: nil, captureNote: nil)
        let record = try engine.runQuickAction(.reviewPageCode, page: page)
        try await waitUntil { engine.journal.record(id: record.id)?.phase == .failed }
        let message = try XCTUnwrap(engine.journal.record(id: record.id)?.message)
        XCTAssertTrue(message.contains("选一个服务"))
        XCTAssertFalse(message.contains("还没有 Cursor"))
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }
}
