import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Seam for tests: the Cloud Agents client only needs one request/response hop.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CursorAPIError.invalidResponse }
        return (data, http)
    }
}

enum CursorAPIError: Error, LocalizedError, Equatable {
    case invalidResponse
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Cursor API 返回了无法识别的响应。"
        case .http(let status, let message):
            switch status {
            case 401, 403:
                return "Cursor API key 无效或没有权限（\(status)）。在设置里重新填一个。"
            case 429:
                return "Cursor API 请求太频繁，稍后再试。"
            default:
                return message.isEmpty ? "Cursor API 错误 \(status)" : "Cursor API 错误 \(status)：\(message)"
            }
        }
    }
}

struct CloudAgentSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var status: String
    var url: String?
    var createdAt: String?
    var updatedAt: String?
    var latestRunId: String?

    /// v1 reports `ACTIVE` while a turn runs; v0-style statuses are accepted too.
    var isActive: Bool {
        ["ACTIVE", "RUNNING", "CREATING"].contains(status.uppercased())
    }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }
}

struct CloudRun: Codable, Equatable, Sendable {
    var id: String
    var agentId: String?
    var status: String
    var result: String?
    var durationMs: Int?

    var isTerminal: Bool {
        ["FINISHED", "ERROR", "CANCELLED", "EXPIRED"].contains(status.uppercased())
    }
}

struct CloudModel: Codable, Equatable, Sendable {
    var id: String
    var displayName: String?
}

/// Minimal Cursor Cloud Agents API v1 client (https://cursor.com/docs/cloud-agent/api/endpoints).
struct CursorCloudAPI: Sendable {
    var apiKey: String
    var baseURL = URL(string: "https://api.cursor.com")!
    var transport: any HTTPTransport = URLSessionTransport()

    func listAgents(limit: Int = 50) async throws -> [CloudAgentSummary] {
        struct Page: Decodable { var items: [CloudAgentSummary] }
        let data = try await send("GET", "/v1/agents", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "includeArchived", value: "false")
        ])
        return try JSONDecoder().decode(Page.self, from: data).items
    }

    func listModels() async throws -> [CloudModel] {
        struct Page: Decodable { var items: [CloudModel] }
        let data = try await send("GET", "/v1/models")
        return try JSONDecoder().decode(Page.self, from: data).items
    }

    func createAgent(
        name: String,
        prompt: String,
        images: [PromptImage],
        modelID: String?
    ) async throws -> (agent: CloudAgentSummary, run: CloudRun) {
        struct Created: Decodable {
            var agent: CloudAgentSummary
            var run: CloudRun
        }
        var body: [String: Any] = [
            "name": String(name.prefix(100)),
            "prompt": Self.promptBody(text: prompt, images: images)
        ]
        if let modelID, !modelID.isEmpty {
            body["model"] = ["id": modelID]
        }
        let data = try await send("POST", "/v1/agents", body: body)
        let created = try JSONDecoder().decode(Created.self, from: data)
        return (created.agent, created.run)
    }

    func run(agentID: String, runID: String) async throws -> CloudRun {
        let data = try await send("GET", "/v1/agents/\(agentID)/runs/\(runID)")
        return try JSONDecoder().decode(CloudRun.self, from: data)
    }

    func cancelRun(agentID: String, runID: String) async throws {
        _ = try await send("POST", "/v1/agents/\(agentID)/runs/\(runID)/cancel", body: [:])
    }

    static func promptBody(text: String, images: [PromptImage]) -> [String: Any] {
        var prompt: [String: Any] = ["text": text]
        if !images.isEmpty {
            prompt["images"] = images.prefix(5).map {
                ["data": $0.data.base64EncodedString(), "mimeType": $0.mimeType]
            }
        }
        return prompt
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CursorAPIError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = (object["message"] ?? object["error"]) as? String {
            return message
        }
        return ""
    }
}

/// Resolves which Grok model to ask when the user left the model field empty.
actor GrokModelPicker {
    static let shared = GrokModelPicker()

    private var resolved: [String: String] = [:]

    func modelID(using api: CursorCloudAPI) async -> String? {
        if let cached = resolved[api.apiKey] { return cached }
        guard let models = try? await api.listModels(), let pick = Self.choose(from: models) else {
            return nil
        }
        resolved[api.apiKey] = pick
        return pick
    }

    static func choose(from models: [CloudModel]) -> String? {
        models.first { model in
            model.id.lowercased().hasPrefix("grok")
                || (model.displayName?.lowercased().contains("grok") ?? false)
        }?.id
    }
}

/// Answers through a no-repo Cursor Cloud Agent running a Grok model.
struct CursorAgentGrokClient: GrokBotClient {
    var credentials: @Sendable () -> CursorCredentials?
    var transport: any HTTPTransport = URLSessionTransport()
    var pollInterval: Duration = .seconds(2)
    var timeout: TimeInterval = 20 * 60

    func execute(
        _ request: ExecutionRequest,
        progress: @escaping @Sendable (ExecutionProgress) async -> Void
    ) async throws -> ExecutionResult {
        guard let credentials = credentials() else {
            throw IslandError.executorFailed("还没有 Cursor API key：点岛右上角的齿轮填入（cursor.com/dashboard → API Keys）。")
        }
        let api = CursorCloudAPI(apiKey: credentials.apiKey, transport: transport)
        let prompt = GrokPromptBuilder.build(request)

        await progress(ExecutionProgress(fraction: 0.05, message: "发送给 Grok…"))
        let modelID: String?
        if credentials.modelID.isEmpty {
            modelID = await GrokModelPicker.shared.modelID(using: api)
        } else {
            modelID = credentials.modelID
        }
        let created = try await api.createAgent(
            name: "grok岛 · \(request.module.displayName)",
            prompt: prompt.text,
            images: prompt.images,
            modelID: modelID
        )
        let agentID = created.agent.id
        let link = created.agent.url
        var run = created.run
        await progress(ExecutionProgress(fraction: 0.1, message: "Grok Bot 启动中", link: link))

        let started = Date()
        do {
            while !run.isTerminal {
                try await Task.sleep(for: pollInterval)
                run = try await api.run(agentID: agentID, runID: run.id)
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > timeout {
                    throw IslandError.executorFailed("Grok 超过 \(Int(timeout / 60)) 分钟没有答完，去 Cloud Agent 页面看看。")
                }
                let label = run.status.uppercased() == "CREATING" ? "Grok Bot 启动中" : "Grok 正在解答"
                await progress(ExecutionProgress(
                    fraction: 0.1 + 0.85 * (1 - exp(-elapsed / 90)),
                    message: "\(label) · \(Int(elapsed))s",
                    link: link
                ))
            }
        } catch is CancellationError {
            let runID = run.id
            Task.detached { try? await api.cancelRun(agentID: agentID, runID: runID) }
            throw CancellationError()
        }

        switch run.status.uppercased() {
        case "FINISHED":
            let text = run.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ExecutionResult(
                summary: GrokPromptBuilder.headline(of: text) ?? "Grok 已完成",
                detail: text.isEmpty ? "Grok 没有返回文字，打开 Cloud Agent 页面查看。" : text,
                link: link
            )
        case "CANCELLED":
            throw CancellationError()
        default:
            throw IslandError.executorFailed("Grok 运行结束状态：\(run.status)。打开 Cloud Agent 页面查看详情。")
        }
    }
}

/// Turns a module run into the text + images sent to the Grok agent.
enum GrokPromptBuilder {
    static let maxInlineTextBytes = 120_000
    static let maxImageBytes = 15 * 1024 * 1024
    static let maxImages = 5
    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp"
    ]

    static let answerRules = """
    回答要求：用中文，直接在回复里给出完整结果（Markdown）。这是一次问答：不要修改任何代码仓库，不要创建分支或 PR。截图里看不清的地方直接说明，不要编造。
    """

    struct Payload: Equatable {
        var text: String
        var images: [PromptImage]
    }

    static func build(_ request: ExecutionRequest) -> Payload {
        var images = Array(request.images.prefix(maxImages))
        var sections: [String] = []

        let task = request.module.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(task.isEmpty ? "任务：\(request.module.displayName)" : task)

        if let extra = request.extraPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            sections.append(extra)
        }

        let attachments = request.resources.map { describe($0, images: &images) }
        if !attachments.isEmpty {
            sections.append("附件：\n" + attachments.joined(separator: "\n"))
        }
        if !images.isEmpty {
            sections.append("已附上 \(images.count) 张图片。")
        }
        sections.append(answerRules)
        return Payload(text: sections.joined(separator: "\n\n"), images: images)
    }

    private static func describe(_ item: ResourceItem, images: inout [PromptImage]) -> String {
        switch item.kind {
        case .url:
            return "- 链接：\(item.location)"
        case .folder:
            return "- 文件夹（在用户的 Mac 上，你无法直接打开）：\(item.name)"
        case .file:
            let url = URL(fileURLWithPath: item.location)
            let ext = url.pathExtension.lowercased()
            if let mime = imageTypes[ext] {
                if images.count < maxImages,
                   let data = try? Data(contentsOf: url),
                   data.count <= maxImageBytes {
                    images.append(PromptImage(data: data, mimeType: mime))
                    return "- 图片：\(item.name)（已附上）"
                }
                return "- 图片：\(item.name)（太大或超过 \(maxImages) 张，未附上）"
            }
            if let size = item.fileSize, size > Int64(maxInlineTextBytes) {
                return "- 文件：\(item.name)（太大，未附上内容）"
            }
            guard let data = try? Data(contentsOf: url),
                  data.count <= maxInlineTextBytes,
                  let text = String(data: data, encoding: .utf8)
            else {
                return "- 文件：\(item.name)（不是文本，未附上内容）"
            }
            return "- 文件：\(item.name)\n```\(ext)\n\(text)\n```"
        }
    }

    /// First meaningful line of a Markdown answer, for the run list.
    static func headline(of text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#*->".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            return line.count > 60 ? String(line.prefix(60)) + "…" : line
        }
        return nil
    }
}
