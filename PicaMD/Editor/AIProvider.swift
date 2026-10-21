import Foundation

/// The providers PicaMD ships with. Anthropic and OpenAI are HTTP APIs
/// with an editable endpoint, model and Keychain key; Apple Intelligence
/// is the on-device model and has none of the three.
///
/// User-defined OpenAI-compatible servers (Ollama, LM Studio, vLLM on
/// another machine, …) are not cases here: they are `CustomAIProvider`
/// entries in `AIConfig`, referenced through `AIProviderRef`.
enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic
    case openai
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic:           return "Anthropic"
        case .openai:              return "OpenAI"
        case .appleIntelligence:   return "Apple Intelligence"
        }
    }

    /// The built-in providers reached over HTTP, in Settings order.
    static let httpProviders: [AIProvider] = [.anthropic, .openai]

    /// Request/response shape; `nil` for the on-device model.
    var apiFormat: AIAPIFormat? {
        switch self {
        case .anthropic:           return .anthropic
        case .openai:              return .openAI
        case .appleIntelligence:   return nil
        }
    }

    /// Empty for Apple Intelligence, which has no endpoint.
    var defaultEndpoint: String {
        switch self {
        case .anthropic:           return "https://api.anthropic.com/v1"
        case .openai:              return "https://api.openai.com/v1"
        case .appleIntelligence:   return ""
        }
    }

    /// Current defaults, checked against the providers' model lists on
    /// 2026-10-21. Empty for Apple
    /// Intelligence: the system picks the on-device model variant.
    var defaultModel: String {
        switch self {
        case .anthropic:           return "claude-sonnet-5-5"
        case .openai:              return "gpt-6-luna"
        case .appleIntelligence:   return ""
        }
    }

    /// The defaults before 0.10.0. A stored model equal to one of these
    /// was never chosen by the user, so the config migration moves it to
    /// `defaultModel`; anything else the user typed stays.
    var legacyDefaultModel: String? {
        switch self {
        case .anthropic:           return "claude-sonnet-4-6"
        case .openai:              return "gpt-4o-mini"
        case .appleIntelligence:   return nil
        }
    }

    var requiresAPIKey: Bool { apiFormat != nil }

    /// Stable key for storing the provider's API key in the keychain.
    /// Includes the provider rawValue so a user can have multiple
    /// providers configured concurrently without the keys colliding.
    var keychainAccount: String {
        "PicaMD.ai.\(rawValue).apiKey"
    }
}

/// A user-defined OpenAI-compatible server ("Custom providers" in
/// Settings ▸ AI). The API key is optional and lives in the Keychain
/// under `keychainAccount`, never in this struct.
struct CustomAIProvider: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var endpointURL: String
    var model: String

    init(id: UUID = UUID(), name: String, endpointURL: String, model: String) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.model = model
    }

    var keychainAccount: String {
        "PicaMD.ai.custom.\(id.uuidString).apiKey"
    }

    /// Name shown in pickers; never empty, so a half-filled entry is
    /// still selectable and recognisable.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled provider" : trimmed
    }

    // Tolerant decoding: a missing field must not drop the whole list
    // (and with it the user's other providers). Only the id is required.
    private enum CodingKeys: String, CodingKey { case id, name, endpointURL, model }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        endpointURL = (try? c.decodeIfPresent(String.self, forKey: .endpointURL)) ?? ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
    }
}

/// Which provider a request goes to: a built-in one or a custom entry.
/// Persisted as a plain string ("anthropic", "openai",
/// "appleIntelligence", "custom:<uuid>") so the stored JSON stays
/// readable and an unknown value can be skipped instead of failing the
/// whole blob.
enum AIProviderRef: Hashable, Codable, Sendable {
    case builtIn(AIProvider)
    case custom(UUID)

    static let anthropic = AIProviderRef.builtIn(.anthropic)
    static let openai = AIProviderRef.builtIn(.openai)
    static let appleIntelligence = AIProviderRef.builtIn(.appleIntelligence)

    /// Raw value of the provider removed in 0.10.0 ("Local (LM Studio /
    /// Ollama)"). Stored references to it resolve to the custom provider
    /// the config migration creates under `legacyLocalProviderID`.
    static let legacyLocalRawValue = "localOpenAICompat"

    /// Fixed id of the "Local" custom provider created from an old
    /// `localOpenAICompat` entry. Fixed so that presets (a separate
    /// UserDefaults blob) can point at it without coordinating with the
    /// config migration.
    static let legacyLocalProviderID = UUID(uuidString: "10CA1000-0000-4000-8000-00000000AA01")!

    private static let customPrefix = "custom:"

    init?(storageValue: String) {
        if let builtIn = AIProvider(rawValue: storageValue) {
            self = .builtIn(builtIn)
        } else if storageValue == Self.legacyLocalRawValue {
            self = .custom(Self.legacyLocalProviderID)
        } else if storageValue.hasPrefix(Self.customPrefix),
                  let id = UUID(uuidString: String(storageValue.dropFirst(Self.customPrefix.count))) {
            self = .custom(id)
        } else {
            return nil
        }
    }

    var storageValue: String {
        switch self {
        case .builtIn(let p):  return p.rawValue
        case .custom(let id):  return Self.customPrefix + id.uuidString
        }
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = AIProviderRef(storageValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown AI provider \(raw)"))
        }
        self = ref
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storageValue)
    }
}

/// Wire format of an HTTP provider.
enum AIAPIFormat: Equatable, Sendable {
    /// `/v1/messages`, `x-api-key`.
    case anthropic
    /// The built-in OpenAI entry: `/chat/completions`, key required.
    /// Its endpoint stays editable, so this also covers Groq, Azure &c.
    case openAI
    /// A user-defined OpenAI-compatible server: key optional, smaller
    /// output cap (see `AICompletionRequest.compatibleMaxTokensCap`).
    case openAICompatible
}

// MARK: - Request building

/// One shot of completion across providers. The struct is provider-
/// agnostic; `AIRequestBuilder` turns it into the right HTTP request
/// per provider.
struct AICompletionRequest {
    /// The user's prompt (after preset templating). For Claude /
    /// OpenAI this becomes the only `user` message; system prompt
    /// is carried separately.
    var userPrompt: String
    /// Optional system instruction. For Anthropic this maps to the
    /// top-level `system` field; for OpenAI it becomes the first
    /// `system` message.
    var systemPrompt: String?
    var model: String
    /// Output ceiling. Generous on purpose: current Claude models think
    /// by default and thinking counts against `max_tokens`, so 2048 could
    /// truncate even a short answer. The model stops when it's done;
    /// this is a cap, not a target.
    var maxTokens: Int = AICompletionRequest.defaultMaxTokens

    static let defaultMaxTokens = 16_000
    /// Self-hosted servers (vLLM, llama.cpp, LM Studio) can reject a
    /// `max_tokens` larger than their context window, so custom
    /// providers keep the smaller cap the old "Local" entry used.
    static let compatibleMaxTokensCap = 2048
    /// Output limit every Claude 2 and Claude 3 model accepts (Claude 3
    /// Haiku and Opus stop at 4096). Larger values are rejected with a
    /// 400, and the migration keeps a model the user chose. These models
    /// don't think by default, so the small cap doesn't cut answers short.
    static let legacyClaudeMaxTokensCap = 4096

    /// Whether `model` is a Claude model from before Claude 4.
    static func isLegacyClaude(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("claude-3") || id.hasPrefix("claude-2") || id.hasPrefix("claude-instant")
    }
}

/// Builds provider-specific `URLRequest`s from an `AICompletionRequest`.
/// Splitting this out from `AIClient` keeps the network glue testable
/// in isolation — the unit tests can verify Anthropic-vs-OpenAI body
/// shapes without spinning up a server.
///
/// No request sets `temperature` (or any other sampling parameter):
/// Claude Sonnet 5.5 and OpenAI's reasoning models reject it with a 400.
enum AIRequestBuilder {

    static func build(
        format: AIAPIFormat,
        endpoint: URL,
        apiKey: String?,
        request: AICompletionRequest
    ) throws -> URLRequest {
        switch format {
        case .anthropic:
            return try buildAnthropic(endpoint: endpoint, apiKey: apiKey, req: request)
        case .openAI, .openAICompatible:
            return try buildOpenAI(format: format,
                                    endpoint: endpoint,
                                    apiKey: apiKey,
                                    req: request)
        }
    }

    // MARK: Anthropic

    private static func buildAnthropic(
        endpoint: URL, apiKey: String?, req: AICompletionRequest
    ) throws -> URLRequest {
        guard let key = apiKey, !key.isEmpty else {
            throw AIError.invalidResponse("Anthropic requires an API key — set one in Settings → AI")
        }
        var url = endpoint
        // Tolerate the user typing `…/v1` or `…/v1/` — strip a trailing
        // `/messages` if they over-specified.
        if !url.path.hasSuffix("/messages") {
            url = url.appendingPathComponent("messages")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: String]] = []
        messages.append(["role": "user", "content": req.userPrompt])

        // No `thinking`, `effort` or `fallbacks`: the defaults suit short
        // rewrites, and a plain body stays portable across proxies and
        // gateways that speak the Messages API.
        let maxTokens = AICompletionRequest.isLegacyClaude(req.model)
            ? min(req.maxTokens, AICompletionRequest.legacyClaudeMaxTokensCap)
            : req.maxTokens
        var body: [String: Any] = [
            "model": req.model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let sys = req.systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    // MARK: OpenAI / OpenAI-compatible

    private static func buildOpenAI(
        format: AIAPIFormat,
        endpoint: URL,
        apiKey: String?,
        req: AICompletionRequest
    ) throws -> URLRequest {
        var url = endpoint
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if format == .openAI {
            throw AIError.invalidResponse("OpenAI requires an API key — set one in Settings → AI")
        }

        var messages: [[String: String]] = []
        if let sys = req.systemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": req.userPrompt])

        var body: [String: Any] = [
            "model": req.model,
            "messages": messages,
            "stream": false,
        ]
        // OpenAI's own API rejects `max_tokens` on its reasoning models
        // (it wants `max_completion_tokens`); other OpenAI-compatible
        // hosts (Groq, Ollama, vLLM, …) still expect `max_tokens`, and
        // reject one above the model's output limit with a 400. The
        // built-in OpenAI entry pointed at such a host keeps the cap it
        // had before 0.10.0, as custom providers do.
        switch format {
        case .openAI where url.host?.hasSuffix("api.openai.com") == true:
            body["max_completion_tokens"] = req.maxTokens
        case .openAI, .openAICompatible:
            body["max_tokens"] = min(req.maxTokens, AICompletionRequest.compatibleMaxTokensCap)
        case .anthropic:
            body["max_tokens"] = req.maxTokens
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}

// MARK: - Response parsing

extension AIAPIFormat {
    /// Pull the assistant text out of a successful response body. Each
    /// format has its own JSON shape, so we dispatch on `self`.
    func parseResponseText(_ data: Data) throws -> String {
        switch self {
        case .anthropic:
            return try Self.parseAnthropic(data)
        case .openAI, .openAICompatible:
            return try AIClient.parseChatResponse(data)
        }
    }

    /// Anthropic's `/v1/messages` returns `{ "content": [ { "type":
    /// "text", "text": "…" }, … ] }`. Current models think by default,
    /// so `thinking` blocks can come first; only `text` blocks are the
    /// answer. We concatenate them in order.
    private static func parseAnthropic(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("Anthropic: top-level JSON not an object")
        }
        if let errorObj = json["error"] as? [String: Any],
           let msg = errorObj["message"] as? String {
            throw AIError.serverError(status: -1, body: msg)
        }
        // Check why generation stopped before trusting the text: a
        // truncated answer must never replace the user's selection, and
        // a refusal arrives as HTTP 200 with an empty or partial body.
        switch json["stop_reason"] as? String {
        case "max_tokens", "model_context_window_exceeded":
            throw AIError.truncated
        case "refusal":
            throw AIError.refused(refusalDetail(json["stop_details"]))
        default:
            break
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw AIError.invalidResponse("Anthropic: missing `content` array")
        }
        let parts: [String] = content.compactMap { block in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }
        guard !parts.isEmpty else {
            throw AIError.invalidResponse("Anthropic: no text blocks in content")
        }
        return parts.joined(separator: "\n\n")
    }

    /// `stop_details` is informational and may be absent or `null`; its
    /// `explanation` is not guaranteed either. Prefer the explanation,
    /// else name the policy category.
    private static func refusalDetail(_ raw: Any?) -> String? {
        guard let details = raw as? [String: Any] else { return nil }
        if let explanation = details["explanation"] as? String,
           !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explanation
        }
        if let category = details["category"] as? String, !category.isEmpty {
            return "Policy category: \(category)."
        }
        return nil
    }
}
