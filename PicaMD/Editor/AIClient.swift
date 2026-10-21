import Foundation

/// The one thing `AICommandExecutor` needs from a provider: turn a
/// system prompt and the user's text into an answer.
///
/// A cut-off answer is not returned: implementations throw
/// `AIError.truncated` (and `AIError.refused` for a refusal) so that
/// nothing half-finished ever replaces the user's selection. Cancelling
/// the calling task surfaces as `CancellationError` (or
/// `URLError.cancelled` from URLSession), never as a provider error.
protocol AICompleting: Sendable {
    func complete(systemPrompt: String?, userText: String, maxTokens: Int) async throws -> String
}

/// HTTP client for the Anthropic and OpenAI(-compatible) APIs.
///
/// `AIClient` is format-agnostic — request shape and response parsing
/// are delegated to `AIRequestBuilder` and `AIAPIFormat` (see
/// `AIProvider.swift`). The client itself just orchestrates: build the
/// request, hit the network, decode the body, surface errors.
///
/// Serves the built-in Anthropic and OpenAI entries and every
/// user-defined OpenAI-compatible provider (any URL the user points us
/// at, key optional).
struct AIClient: AICompleting {
    let format: AIAPIFormat
    let endpoint: URL
    let model: String
    let apiKey: String?
    let session: URLSession

    init(format: AIAPIFormat,
          endpoint: URL,
          model: String,
          apiKey: String?,
          session: URLSession = .shared) {
        self.format = format
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    /// Convenience init that resolves the endpoint URL from a string.
    /// Returns `nil` if the URL is unparseable. Treats an empty
    /// `apiKey` as `nil`.
    init?(format: AIAPIFormat,
           endpointString: String,
           model: String,
           apiKey: String?,
           session: URLSession = .shared) {
        guard let url = Self.endpointURL(from: endpointString) else { return nil }
        self.init(format: format,
                   endpoint: url,
                   model: model,
                   apiKey: (apiKey?.isEmpty == false) ? apiKey : nil,
                   session: session)
    }

    /// `endpointString` as an http(s) URL with a host, else `nil`
    /// (rejects file://, ftp://, bare paths, typos without a scheme).
    static func endpointURL(from endpointString: String) -> URL? {
        guard let url = URL(string: endpointString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// Single round-trip completion. Caller waits via `await`.
    func complete(systemPrompt: String?, userText: String, maxTokens: Int) async throws -> String {
        let req = AICompletionRequest(
            userPrompt: userText,
            systemPrompt: systemPrompt,
            model: model,
            maxTokens: maxTokens
        )
        let urlRequest = try AIRequestBuilder.build(
            format: format,
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
        return try format.parseResponseText(data)
    }

    // MARK: - OpenAI parser (kept here, re-used by `AIAPIFormat`)

    /// Parse an OpenAI-shape chat-completion response. Used by the
    /// built-in OpenAI entry and by custom providers via
    /// `AIAPIFormat.parseResponseText`.
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
        switch first["finish_reason"] as? String {
        case "length":
            throw AIError.truncated
        case "content_filter":
            throw AIError.refused(nil)
        default:
            break
        }
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        // Older llama.cpp returns `text` instead of `message.content`;
        // custom providers can point at such a server.
        if let text = first["text"] as? String {
            return text
        }
        throw AIError.invalidResponse("missing message.content / text")
    }
}

enum AIError: LocalizedError, Equatable {
    case invalidResponse(String)
    case serverError(status: Int, body: String)
    /// The model hit its output limit mid-answer.
    case truncated
    /// The provider declined to answer. Carries the provider's reason
    /// when it gives one (Anthropic's `stop_details`).
    case refused(String?)
    /// Apple Intelligence can't run right now; the text says why and
    /// what to do.
    case appleIntelligenceUnavailable(String)
    /// Checked before anything runs: the on-device context window is
    /// small, and overrunning it fails only after the full generation
    /// time (measured: 83–95 s). `limit` is the largest input that fits.
    case tooLongForAppleIntelligence(tokens: Int, limit: Int)
    /// Any other on-device failure, already phrased for the user.
    case appleIntelligence(String)

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "The AI's answer was cut off at the output limit, so nothing was changed. Try a shorter selection."
        case .refused(let reason):
            let base = "The AI declined to answer this request, so nothing was changed."
            guard let reason, !reason.isEmpty else { return base }
            return base + "\n\n" + reason
        case .invalidResponse(let why):
            return "Unexpected response from AI server: \(why)"
        case .serverError(let status, let body):
            let trimmedBody = body.prefix(500)
            return "AI server returned \(status)" +
                   (body.isEmpty ? "" : ":\n\(trimmedBody)")
        case .appleIntelligenceUnavailable(let message):
            return message
        case .tooLongForAppleIntelligence(let tokens, let limit):
            return "This selection is too long for Apple Intelligence (\(tokens.formatted()) of \(limit.formatted()) tokens). Use Anthropic or OpenAI for long texts."
        case .appleIntelligence(let message):
            return message
        }
    }
}
