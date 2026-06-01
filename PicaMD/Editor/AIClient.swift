import Foundation

/// Multi-provider HTTP client for LLM completions.
///
/// `AIClient` is provider-agnostic — request shape and response
/// parsing are delegated to `AIRequestBuilder` and `AIProvider`
/// (see `AIProvider.swift`). The client itself just orchestrates:
/// build the request, hit the network, decode the body, surface
/// errors.
///
/// Three providers are supported out of the box:
///   - `.anthropic` — `api.anthropic.com/v1/messages`
///   - `.openai` — `api.openai.com/v1/chat/completions`
///   - `.localOpenAICompat` — LM Studio / Ollama / llama.cpp / vLLM /
///     any custom URL the user points us at, no auth required.
struct AIClient {
    let provider: AIProvider
    let endpoint: URL
    let model: String
    let apiKey: String?
    let session: URLSession

    init(provider: AIProvider,
          endpoint: URL,
          model: String,
          apiKey: String?,
          session: URLSession = .shared) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    /// Convenience init that resolves the endpoint URL from a string.
    /// Returns `nil` if the URL is unparseable. Treats an empty
    /// `apiKey` as `nil`.
    init?(provider: AIProvider,
           endpointString: String,
           model: String,
           apiKey: String?,
           session: URLSession = .shared) {
        guard let url = URL(string: endpointString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",   // reject file://, ftp://, etc.
              url.host != nil else {
            return nil
        }
        self.init(provider: provider,
                   endpoint: url,
                   model: model,
                   apiKey: (apiKey?.isEmpty == false) ? apiKey : nil,
                   session: session)
    }

    /// Single round-trip completion. Caller waits via `await`.
    func complete(userPrompt: String, systemPrompt: String? = nil) async throws -> String {
        let req = AICompletionRequest(
            userPrompt: userPrompt,
            systemPrompt: systemPrompt,
            model: model
        )
        let urlRequest = try AIRequestBuilder.build(
            provider: provider,
            endpoint: endpoint,
            apiKey: apiKey,
            request: req
        )

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.invalidResponse("not HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AIError.serverError(status: http.statusCode, body: bodyText)
        }
        return try provider.parseResponseText(data)
    }

    // MARK: - OpenAI parser (kept here, re-used by `AIProvider`)

    /// Parse an OpenAI-shape chat-completion response. Used by both
    /// `.openai` and `.localOpenAICompat` paths via
    /// `AIProvider.parseResponseText`. Public-internal so the
    /// per-provider response parsers can route here.
    static func parseChatResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse("top-level JSON not an object")
        }
        if let errorObj = json["error"] as? [String: Any],
           let msg = errorObj["message"] as? String {
            throw AIError.serverError(status: -1, body: msg)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw AIError.invalidResponse("no choices in response")
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        // Older llama.cpp returns `text` instead of `message.content`.
        if let text = first["text"] as? String {
            return text
        }
        throw AIError.invalidResponse("missing message.content / text")
    }
}

enum AIError: LocalizedError {
    case invalidResponse(String)
    case serverError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let why):
            return "Unexpected response from AI server: \(why)"
        case .serverError(let status, let body):
            let trimmedBody = body.prefix(500)
            return "AI server returned \(status)" +
                   (body.isEmpty ? "" : ":\n\(trimmedBody)")
        }
    }
}
