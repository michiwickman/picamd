import XCTest
@testable import PicaMD

final class AIClientTests: XCTestCase {

    // MARK: - Plain http to self-hosted providers

    /// A custom provider on a fully qualified host over plain http (a
    /// `.lan` name, Tailscale MagicDNS) must reach the network. App
    /// Transport Security refused it with -1022 before any lookup. The
    /// `.invalid` host then fails at DNS (or offline), which is fine; only
    /// the ATS refusal is the bug.
    func testPlainHTTPToAFullyQualifiedHostIsNotBlockedByATS() async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "http://gpu.picamd-ats-probe.invalid:9/v1/models")!)
        request.timeoutInterval = 5
        do {
            _ = try await session.data(for: request)
        } catch let error as URLError {
            XCTAssertNotEqual(error.code, .appTransportSecurityRequiresSecureConnection,
                              "ATS blocks plain http to self-hosted providers")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - parseChatResponse (OpenAI shape)

    func testParseStandardOpenAIResponse() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": "Hello, world!" },
              "finish_reason": "stop"
            }
          ]
        }
        """.data(using: .utf8)!
        let result = try AIClient.parseChatResponse(json)
        XCTAssertEqual(result, "Hello, world!")
    }

    func testParseLegacyTextField() throws {
        // Some llama.cpp builds return `text` instead of `message.content`.
        let json = """
        {
          "choices": [
            { "text": "fallback content" }
          ]
        }
        """.data(using: .utf8)!
        let result = try AIClient.parseChatResponse(json)
        XCTAssertEqual(result, "fallback content")
    }

    func testParseErrorObject() {
        let json = """
        {
          "error": { "message": "model not found", "type": "invalid_request" }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AIClient.parseChatResponse(json)) { error in
            guard case AIError.serverError(_, let body) = error else {
                XCTFail("Expected .serverError, got \(error)")
                return
            }
            XCTAssertTrue(body.contains("model not found"))
        }
    }

    func testParseRejectsTopLevelArray() {
        let json = "[1, 2, 3]".data(using: .utf8)!
        XCTAssertThrowsError(try AIClient.parseChatResponse(json))
    }

    func testParseRejectsEmptyChoices() {
        let json = #"{"choices": []}"#.data(using: .utf8)!
        XCTAssertThrowsError(try AIClient.parseChatResponse(json))
    }

    func testParseRejectsMissingContent() {
        let json = """
        { "choices": [ { "message": { "role": "assistant" } } ] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AIClient.parseChatResponse(json))
    }

    // MARK: - parseAnthropicResponse

    func testParseAnthropicSingleTextBlock() throws {
        let json = """
        {
          "id": "msg_1",
          "type": "message",
          "content": [
            { "type": "text", "text": "Hi from Claude." }
          ],
          "model": "claude-sonnet-5-5"
        }
        """.data(using: .utf8)!
        let result = try AIAPIFormat.anthropic.parseResponseText(json)
        XCTAssertEqual(result, "Hi from Claude.")
    }

    func testParseAnthropicMultipleBlocksConcatenated() throws {
        let json = """
        {
          "content": [
            { "type": "text", "text": "First." },
            { "type": "text", "text": "Second." }
          ]
        }
        """.data(using: .utf8)!
        let result = try AIAPIFormat.anthropic.parseResponseText(json)
        XCTAssertEqual(result, "First.\n\nSecond.")
    }

    func testParseAnthropicErrorObject() {
        let json = """
        { "error": { "message": "rate limit exceeded", "type": "rate_limit_error" } }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AIAPIFormat.anthropic.parseResponseText(json))
    }

    func testParseAnthropicNonText() {
        // No `text` block → no usable response.
        let json = """
        { "content": [ { "type": "tool_use", "name": "x", "input": {} } ] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AIAPIFormat.anthropic.parseResponseText(json))
    }

    // MARK: - URL parsing

    func testInitRejectsInvalidEndpoint() {
        XCTAssertNil(AIClient(format: .openAI, endpointString: "not a url",
                               model: "m", apiKey: "k"))
        XCTAssertNil(AIClient(format: .openAI, endpointString: "",
                               model: "m", apiKey: "k"))
        XCTAssertNil(AIClient(format: .openAI, endpointString: "/no/scheme",
                               model: "m", apiKey: "k"))
    }

    func testInitAcceptsLocalhost() {
        // Custom providers point at self-hosted servers over plain http.
        let c = AIClient(format: .openAICompatible,
                          endpointString: "http://localhost:1234/v1",
                          model: "m",
                          apiKey: nil)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.endpoint.host, "localhost")
        XCTAssertEqual(c?.endpoint.port, 1234)
    }
}

// MARK: - AIConfig

final class AIConfigTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Named after the test host and emptied after each test, like
        // every other suite (see `makeTestDefaults`).
        defaults = makeTestDefaults("AIConfig")
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreSafelyOff() {
        let cfg = AIConfig.default
        XCTAssertFalse(cfg.enabled, "AI must be off by default — opt-in only")
        XCTAssertEqual(cfg.defaultProvider, .anthropic)
        XCTAssertEqual(cfg.endpoint(for: .anthropic),
                       "https://api.anthropic.com/v1")
        XCTAssertEqual(cfg.endpoint(for: .openai),
                       "https://api.openai.com/v1")
        XCTAssertTrue(cfg.customProviders.isEmpty)
    }

    func testRoundtripSaveAndLoad() {
        var cfg = AIConfig.default
        cfg.enabled = true
        cfg.defaultProvider = .openai
        cfg.setEndpoint("https://api.groq.com/openai/v1", for: .openai)
        cfg.setModel("llama-3.1-70b", for: .openai)
        cfg.save(to: defaults)

        let loaded = AIConfig.load(defaults: defaults)
        XCTAssertTrue(loaded.enabled)
        XCTAssertEqual(loaded.defaultProvider, .openai)
        XCTAssertEqual(loaded.endpoint(for: .openai),
                       "https://api.groq.com/openai/v1")
        XCTAssertEqual(loaded.model(for: .openai), "llama-3.1-70b")
        XCTAssertEqual(loaded.endpoint(for: .anthropic),
                       AIProvider.anthropic.defaultEndpoint)
    }

    func testV1MigrationLiftsOldKeysToACustomProvider() throws {
        // Simulate the old-style flat keys from the original AI hook,
        // which only knew a local server.
        defaults.set(true, forKey: "PicaMD.ai.enabled")
        defaults.set("http://10.0.0.5:11434/v1", forKey: "PicaMD.ai.endpointURL")
        defaults.set("qwen2.5", forKey: "PicaMD.ai.model")

        let loaded = AIConfig.load(defaults: defaults, keyStore: InMemoryKeyStore(),
                                   appleIntelligenceAvailable: { true })
        XCTAssertTrue(loaded.enabled)
        let local = try XCTUnwrap(loaded.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(loaded.defaultProvider, .custom(AIProviderRef.legacyLocalProviderID),
                       "v1 only had a local endpoint — it stays the default, as a custom provider")
        XCTAssertEqual(local.name, "Local")
        XCTAssertEqual(local.endpointURL, "http://10.0.0.5:11434/v1")
        XCTAssertEqual(local.model, "qwen2.5")
    }
}

// MARK: - AIRequestBuilder

final class AIRequestBuilderTests: XCTestCase {

    func testAnthropicRequestShape() throws {
        let url = URL(string: "https://api.anthropic.com/v1")!
        let req = AICompletionRequest(
            userPrompt: "hello",
            systemPrompt: "be concise",
            model: "claude-sonnet-5-5"
        )
        let urlReq = try AIRequestBuilder.build(
            format: .anthropic,
            endpoint: url,
            apiKey: "sk-ant-123",
            request: req
        )

        XCTAssertTrue(urlReq.url?.path.hasSuffix("/messages") ?? false)
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "x-api-key"), "sk-ant-123")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try XCTUnwrap(urlReq.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(json["system"] as? String, "be concise")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(messages[0]["content"], "hello")
    }

    func testAnthropicMissingKeyThrows() {
        let url = URL(string: "https://api.anthropic.com/v1")!
        let req = AICompletionRequest(userPrompt: "x", model: "claude-sonnet-5-5")
        XCTAssertThrowsError(try AIRequestBuilder.build(
            format: .anthropic,
            endpoint: url,
            apiKey: nil,
            request: req
        ))
    }

    func testOpenAIRequestShape() throws {
        let url = URL(string: "https://api.openai.com/v1")!
        let req = AICompletionRequest(
            userPrompt: "hi",
            systemPrompt: "be terse",
            model: "gpt-6-luna"
        )
        let urlReq = try AIRequestBuilder.build(
            format: .openAI,
            endpoint: url,
            apiKey: "sk-456",
            request: req
        )

        XCTAssertTrue(urlReq.url?.path.hasSuffix("/chat/completions") ?? false)
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "Authorization"), "Bearer sk-456")

        let body = try XCTUnwrap(urlReq.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "be terse")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "hi")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testCustomProviderDoesNotRequireKey() throws {
        let url = URL(string: "http://localhost:1234/v1")!
        let req = AICompletionRequest(userPrompt: "hi", model: "local-model")
        let urlReq = try AIRequestBuilder.build(
            format: .openAICompatible,
            endpoint: url,
            apiKey: nil,
            request: req
        )
        XCTAssertNil(urlReq.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(urlReq.url?.path.hasSuffix("/chat/completions") ?? false)
    }

    func testOpenAIWithoutKeyThrows() {
        let url = URL(string: "https://api.openai.com/v1")!
        let req = AICompletionRequest(userPrompt: "x", model: "gpt-6-luna")
        XCTAssertThrowsError(try AIRequestBuilder.build(
            format: .openAI,
            endpoint: url,
            apiKey: nil,
            request: req
        ))
    }
}

// MARK: - AIPreset

final class AIPresetTests: XCTestCase {

    func testResolvePromptSubstitutesPlaceholder() {
        let preset = AIPreset(
            id: UUID(),
            name: "test",
            systemPrompt: nil,
            userPromptTemplate: "Translate this: {{selection}}",
            insertionMode: .replaceSelection,
            hotkey: nil
        )
        XCTAssertEqual(
            preset.resolvePrompt(selection: "Hallo"),
            "Translate this: Hallo"
        )
    }

    func testResolvePromptAppendsWhenPlaceholderMissing() {
        let preset = AIPreset(
            id: UUID(),
            name: "test",
            systemPrompt: nil,
            userPromptTemplate: "Summarize the following:",
            insertionMode: .replaceSelection,
            hotkey: nil
        )
        XCTAssertEqual(
            preset.resolvePrompt(selection: "long text"),
            "Summarize the following:\n\nlong text"
        )
    }

    func testStarterPresetsCoverHotkeys1Through9() {
        let defaults = AIPreset.defaults
        let assigned = Set(defaults.compactMap { $0.hotkey })
        XCTAssertEqual(assigned, Set(1...9))
    }

    func testInsertionModeIsCodableRoundtrip() throws {
        let preset = AIPreset(
            id: UUID(),
            name: "x",
            systemPrompt: "sys",
            userPromptTemplate: "{{selection}}",
            insertionMode: .asBlockquote,
            hotkey: 3
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(AIPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }
}

// MARK: - Current models (Claude Sonnet 5.5, GPT-6 Luna)

final class AIRequestShapeForCurrentModelsTests: XCTestCase {

    private func body(_ format: AIAPIFormat, _ endpoint: String, model: String) throws -> [String: Any] {
        let req = try AIRequestBuilder.build(format: format, endpoint: URL(string: endpoint)!, apiKey: "k",
                                             request: AICompletionRequest(userPrompt: "hi", systemPrompt: "sys", model: model))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    func testNoRequestSendsSamplingParameters() throws {
        // Sonnet 5.5 and OpenAI's reasoning models answer `temperature`
        // with a 400.
        let bodies = [
            try body(.anthropic, "https://api.anthropic.com/v1", model: "claude-sonnet-5-5"),
            try body(.openAI, "https://api.openai.com/v1", model: "gpt-6-luna"),
            try body(.openAICompatible, "http://box:11434/v1", model: "llama3.3"),
        ]
        for json in bodies {
            XCTAssertNil(json["temperature"])
            XCTAssertNil(json["top_p"])
            XCTAssertNil(json["top_k"])
        }
    }

    func testAnthropicBodyHasNoThinkingEffortOrFallbacks() throws {
        let json = try body(.anthropic, "https://api.anthropic.com/v1", model: "claude-sonnet-5-5")
        XCTAssertEqual(Set(json.keys), ["model", "max_tokens", "messages", "system"])
    }

    func testOpenAIReasoningModelUsesMaxCompletionTokens() throws {
        let json = try body(.openAI, "https://api.openai.com/v1", model: "gpt-6-luna")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, AICompletionRequest.defaultMaxTokens)
        XCTAssertNil(json["max_tokens"])
    }

    func testTextOnlyAfterAThinkingBlock() throws {
        let json = #"""
        {"content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"Clean text."}],"stop_reason":"end_turn"}
        """#
        XCTAssertEqual(try AIAPIFormat.anthropic.parseResponseText(Data(json.utf8)), "Clean text.")
    }

    func testRefusalCarriesStopDetails() {
        func refusal(_ json: String) -> AIError? {
            do {
                _ = try AIAPIFormat.anthropic.parseResponseText(Data(json.utf8))
                return nil
            } catch {
                return error as? AIError
            }
        }
        XCTAssertEqual(refusal(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Looks like exploit development."}}"#),
                       .refused("Looks like exploit development."))
        XCTAssertEqual(refusal(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"general_harms"}}"#),
                       .refused("Policy category: general_harms."))
        XCTAssertEqual(refusal(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"refusal","stop_details":null}"#),
                       .refused(nil))
        XCTAssertTrue(AIError.refused("Looks like exploit development.").errorDescription?
            .contains("Looks like exploit development.") ?? false)
    }

    func testContextWindowStopIsTruncation() {
        let json = #"{"content":[{"type":"text","text":"half"}],"stop_reason":"model_context_window_exceeded"}"#
        XCTAssertThrowsError(try AIAPIFormat.anthropic.parseResponseText(Data(json.utf8))) {
            XCTAssertEqual($0 as? AIError, .truncated)
        }
    }

    func testCurrentDefaultModels() {
        XCTAssertEqual(AIProvider.anthropic.defaultModel, "claude-sonnet-5-5")
        XCTAssertEqual(AIProvider.openai.defaultModel, "gpt-6-luna")
        XCTAssertFalse(AIProvider.appleIntelligence.requiresAPIKey)
        XCTAssertNil(AIProvider.appleIntelligence.apiFormat)
    }
}
