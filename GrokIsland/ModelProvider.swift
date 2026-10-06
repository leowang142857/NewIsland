import Foundation

/// Where Ask Grok, the shortcut buttons, and split-task send their prompts.
///
/// Cursor Cloud Agents stays available for people who already use it. Everyone else
/// can point the island at a normal model API.
enum ModelProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case xai
    case openai
    case deepseek
    case ollama
    case compatible
    case cursor

    var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .xai: return "xAI（Grok）"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .ollama: return "本地 Ollama"
        case .compatible: return "OpenAI 兼容"
        case .cursor: return "Cursor（高级）"
        }
    }

    /// Used when the model field is left empty. Ollama, compatible endpoints, and Cursor have none.
    var defaultModel: String {
        switch self {
        case .xai: return "grok-4.6"
        case .openai: return "gpt-4o"
        case .deepseek: return "deepseek-flash"
        case .ollama, .compatible, .cursor: return ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .xai: return "https://api.x.ai/v1"
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .compatible: return ""
        case .cursor: return "https://api.cursor.com"
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .xai: return "grok-4.6"
        case .openai: return "gpt-4o"
        case .deepseek: return "deepseek-flash"
        case .ollama: return "例如 llava、llama3.2-vision"
        case .compatible: return "服务商文档里的模型 ID"
        case .cursor: return "留空：自动选一个 Grok 模型"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .xai: return "xai-…"
        case .openai, .deepseek: return "sk-…"
        case .ollama: return "一般留空"
        case .compatible: return "API key"
        case .cursor: return "crsr_…"
        }
    }

    var requiresAPIKey: Bool { self != .ollama }

    var allowsCustomBaseURL: Bool { self == .ollama || self == .compatible }

    /// `0600` file under Application Support. The Cursor name stays put so existing installs keep working.
    var secretFileName: String {
        switch self {
        case .cursor: return "cursor-api-key"
        case .xai: return "xai-api-key"
        case .openai: return "openai-api-key"
        case .deepseek: return "deepseek-api-key"
        case .ollama: return "ollama-api-key"
        case .compatible: return "compatible-api-key"
        }
    }

    var docsURL: URL? {
        switch self {
        case .xai: return URL(string: "https://console.x.ai/")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .compatible: return nil
        case .cursor: return URL(string: "https://cursor.com/dashboard/api")
        }
    }

    var docsLinkTitle: String {
        switch self {
        case .ollama: return "安装 Ollama"
        case .compatible: return ""
        default: return "获取 API key"
        }
    }

    var keySectionTitle: String {
        switch self {
        case .cursor: return "Cursor API key"
        case .ollama: return "API key（可选）"
        default: return "API key"
        }
    }
}

/// One ready-to-call provider. The API key is held only to put on the request.
struct ModelProviderConfiguration: Equatable, Sendable {
    var kind: ModelProviderKind
    var apiKey: String
    var model: String
    var baseURL: URL
}

/// What settings resolve to right now, including the empty first-run case.
struct ModelProviderResolution: Equatable, Sendable {
    var kind: ModelProviderKind
    /// True after the user picks a provider. A Cursor key left over from an older build is not explicit.
    var isExplicit: Bool
    var configuration: ModelProviderConfiguration?

    var notReadyMessage: String {
        if !isExplicit && configuration == nil {
            return ModelProviderMessages.firstRunBlocked
        }
        return ModelProviderMessages.notReady(kind)
    }
}

enum ModelProviderMessages {
    static let firstRunBlocked = "还没有可用的模型：点岛右上角的齿轮，选一个服务（xAI、OpenAI、DeepSeek、本地 Ollama 或 OpenAI 兼容接口）并填入 API key。"
    static let settingsHint = "先选一个模型服务，再填入 API key。xAI、OpenAI、DeepSeek 或本机 Ollama 都可以，不必有 Cursor 账号。"
    static let gearHelp = "设置：先选模型服务并填入 API key"

    static func notReady(_ kind: ModelProviderKind) -> String {
        switch kind {
        case .cursor:
            return "还没有 Cursor API key：点岛右上角的齿轮填入（cursor.com/dashboard → API Keys）。"
        case .ollama:
            return "还不能用本地 Ollama：点岛右上角的齿轮，确认地址（默认 http://127.0.0.1:11434/v1）并填写模型名。"
        case .compatible:
            return "还不能用 OpenAI 兼容接口：点岛右上角的齿轮，填写接口地址、API key 和模型名。"
        case .xai, .openai, .deepseek:
            return "还没有 \(kind.settingsTitle) 的 API key：点岛右上角的齿轮选好服务并填入。"
        }
    }

    static func imagesUnsupported(model: String) -> String {
        "模型 \(model) 不能接收图片。这次请求带有截图或图片，已停止，没有把图片丢掉后继续问。请换成支持视觉的模型（例如 grok-4.6、gpt-4o、deepseek-flash，或 Ollama 的视觉模型）。"
    }
}

/// Decides whether a prompt that includes a screenshot may be sent.
enum ModelImageInput {
    /// Models documented as text-only. Unknown models are sent with their images and the API answer is checked.
    static func unsupportedReason(kind: ModelProviderKind, model: String) -> String? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        if kind == .xai && id.contains("imagine") {
            return ModelProviderMessages.imagesUnsupported(model: model)
        }
        let blocked = id.hasPrefix("gpt-3.5")
            || id.hasPrefix("text-embedding")
            || id.hasPrefix("whisper")
            || id.hasPrefix("tts-")
            || id.hasPrefix("dall-e")
            || id == "o1-mini"
            || id == "deepseek-v4-pro"
        return blocked ? ModelProviderMessages.imagesUnsupported(model: model) : nil
    }

    /// Turns an HTTP error that is about the attached image into a sentence a person can act on.
    static func apiRejectionMessage(status: Int, body: String, model: String) -> String? {
        guard (400..<500).contains(status) else { return nil }
        let lower = body.lowercased()
        let mentionsImage = lower.contains("image")
            || lower.contains("vision")
            || lower.contains("multimodal")
            || lower.contains("image_url")
        guard mentionsImage else { return nil }
        let unsupported = lower.contains("not support")
            || lower.contains("doesn't support")
            || lower.contains("does not support")
            || lower.contains("unsupported")
            || lower.contains("only supported")
            || lower.contains("unknown variant")
            || lower.contains("cannot")
            || lower.contains("can't")
            || lower.contains("invalid content")
        if unsupported {
            return ModelProviderMessages.imagesUnsupported(model: model) + "（服务返回 \(status)）"
        }
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = detail.count > 180 ? String(detail.prefix(180)) + "…" : detail
        if clipped.isEmpty {
            return "图片没有被接受：模型服务错误 \(status)。"
        }
        return "图片没有被接受：\(clipped)"
    }
}

enum ModelEndpoint {
    /// `http` or `https` with a host. Trailing slashes are removed. Anything else is refused.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}
