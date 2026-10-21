import XCTest
import AppKit
@testable import PicaMD

/// Stands in for a provider: records what it was asked and answers
/// with a fixed result.
private final class FakeCompleter: AICompleting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, any Error>
    private var _calls: [(system: String?, user: String, maxTokens: Int)] = []

    init(_ result: Result<String, any Error>) { self.result = result }

    var calls: [(system: String?, user: String, maxTokens: Int)] {
        lock.withLock { _calls }
    }

    func complete(systemPrompt: String?, userText: String, maxTokens: Int) async throws -> String {
        lock.withLock { _calls.append((systemPrompt, userText, maxTokens)) }
        return try result.get()
    }
}

@MainActor
final class AICommandExecutorTests: XCTestCase {

    private func enabledConfig() -> AIConfig {
        var cfg = AIConfig.default
        cfg.enabled = true
        return cfg
    }

    private func preset(_ mode: AIPreset.InsertionMode, system: String? = "Fix it.") -> AIPreset {
        AIPreset(id: UUID(), name: "p", systemPrompt: system, userPromptTemplate: "{{selection}}",
                 insertionMode: mode, hotkey: nil)
    }

    private func textView(_ text: String, selecting target: String) -> NSTextView {
        let view = NSTextView()
        view.string = text
        view.setSelectedRange((text as NSString).range(of: target))
        return view
    }

    // MARK: run

    func testAnswerReplacesTheSelection() async throws {
        let fake = FakeCompleter(.success("  there \n"))
        let view = textView("Hello world.", selecting: "world")
        try await AICommandExecutor.run(preset: preset(.replaceSelection), in: view,
                                        config: enabledConfig(), completer: fake)
        XCTAssertEqual(view.string, "Hello there.")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls.first?.system, "Fix it.")
        XCTAssertEqual(fake.calls.first?.user, "world")
        XCTAssertEqual(fake.calls.first?.maxTokens, AICompletionRequest.defaultMaxTokens)
    }

    func testTruncatedAnswerLeavesTheTextAlone() async {
        let fake = FakeCompleter(.failure(AIError.truncated))
        let view = textView("Hello world.", selecting: "world")
        do {
            try await AICommandExecutor.run(preset: preset(.replaceSelection), in: view,
                                            config: enabledConfig(), completer: fake)
            XCTFail("expected an error")
        } catch AICommandExecutor.FailureReason.providerError(let underlying) {
            XCTAssertEqual(underlying as? AIError, .truncated)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(view.string, "Hello world.")
    }

    func testEmptyAnswerLeavesTheTextAlone() async {
        for mode: AIPreset.InsertionMode in [.replaceSelection, .appendBelow, .asBlockquote, .asHTMLComment] {
            let fake = FakeCompleter(.success(" \n\t "))
            let view = textView("Hello world.", selecting: "world")
            do {
                try await AICommandExecutor.run(preset: preset(mode), in: view,
                                                config: enabledConfig(), completer: fake)
                XCTFail("expected an error for \(mode)")
            } catch AICommandExecutor.FailureReason.emptyResponse {
                // expected
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(view.string, "Hello world.", "an empty answer must not change the text (\(mode))")
        }
    }

    func testCancellationIsNotReportedAsAFailure() async {
        for cancellation: any Error in [CancellationError(), URLError(.cancelled)] {
            let fake = FakeCompleter(.failure(cancellation))
            let view = textView("Hello world.", selecting: "world")
            do {
                try await AICommandExecutor.run(preset: preset(.replaceSelection), in: view,
                                                config: enabledConfig(), completer: fake)
                XCTFail("expected cancellation")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("\(cancellation) surfaced as \(error)")
            }
            XCTAssertEqual(view.string, "Hello world.")
        }
    }

    func testDisabledAIDoesNotCallTheProvider() async {
        let fake = FakeCompleter(.success("x"))
        let view = textView("Hello world.", selecting: "world")
        do {
            try await AICommandExecutor.run(preset: preset(.replaceSelection), in: view,
                                            config: .default, completer: fake)
            XCTFail("expected aiDisabled")
        } catch AICommandExecutor.FailureReason.aiDisabled {
            XCTAssertTrue(fake.calls.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: resolveProvider

    func testDefaultAppleIntelligenceNeedsNoEndpointOrKey() throws {
        var cfg = enabledConfig()
        cfg.defaultProvider = .appleIntelligence
        var askedForKey = false
        let resolved = try AICommandExecutor.resolveProvider(for: preset(.appendBelow), config: cfg) { _ in
            askedForKey = true
            return nil
        }
        guard case .appleIntelligence = resolved else { return XCTFail("got \(resolved)") }
        XCTAssertFalse(askedForKey)
    }

    func testCustomProviderResolvesToAnOpenAICompatibleClient() throws {
        var cfg = enabledConfig()
        let box = CustomAIProvider(name: "Box", endpointURL: "http://192.168.1.20:11434/v1", model: "llama3.3")
        cfg.upsertCustomProvider(box)
        cfg.defaultProvider = .custom(box.id)
        let resolved = try AICommandExecutor.resolveProvider(for: preset(.appendBelow), config: cfg) {
            $0 == box.keychainAccount ? "sk-box" : nil
        }
        guard case .http(let client) = resolved else { return XCTFail("got \(resolved)") }
        XCTAssertEqual(client.format, .openAICompatible)
        XCTAssertEqual(client.endpoint.absoluteString, "http://192.168.1.20:11434/v1")
        XCTAssertEqual(client.model, "llama3.3")
        XCTAssertEqual(client.apiKey, "sk-box")
    }

    func testPresetOverrideAndModelOverrideWin() throws {
        let cfg = enabledConfig()   // default: Anthropic
        var p = preset(.appendBelow)
        p.providerOverride = .openai
        p.modelOverride = "gpt-6.1-sol"
        guard case .http(let client) = try AICommandExecutor.resolveProvider(for: p, config: cfg, apiKey: { _ in "k" }) else {
            return XCTFail("expected HTTP")
        }
        XCTAssertEqual(client.format, .openAI)
        XCTAssertEqual(client.model, "gpt-6.1-sol")
    }

    func testEmptyModelAndEndpointFieldsMeanTheDefaults() throws {
        var cfg = enabledConfig()
        cfg.setModel("  ", for: .anthropic)
        cfg.setEndpoint("", for: .anthropic)
        guard case .http(let client) = try AICommandExecutor.resolveProvider(for: preset(.appendBelow), config: cfg,
                                                                              apiKey: { _ in "k" }) else {
            return XCTFail("expected HTTP")
        }
        XCTAssertEqual(client.model, AIProvider.anthropic.defaultModel)
        XCTAssertEqual(client.endpoint.absoluteString, AIProvider.anthropic.defaultEndpoint)
    }

    /// A preset pinned to a removed custom provider (e.g. a local
    /// server) must not quietly send its text to a cloud default.
    func testOverrideToARemovedCustomProviderIsReported() {
        let cfg = enabledConfig()   // default: Anthropic
        var p = preset(.appendBelow)
        p.providerOverride = .custom(UUID())
        p.modelOverride = "llama3.3"
        XCTAssertThrowsError(try AICommandExecutor.resolveProvider(for: p, config: cfg,
                                                                    apiKey: { _ in "k" })) { error in
            guard case AICommandExecutor.FailureReason.presetProviderMissing = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testInvalidCustomEndpointIsReported() {
        var cfg = enabledConfig()
        let broken = CustomAIProvider(name: "Typo", endpointURL: "192.168.1.20:11434/v1", model: "m")
        cfg.upsertCustomProvider(broken)
        cfg.defaultProvider = .custom(broken.id)
        XCTAssertThrowsError(try AICommandExecutor.resolveProvider(for: preset(.appendBelow), config: cfg,
                                                                    apiKey: { _ in nil })) { error in
            guard case AICommandExecutor.FailureReason.invalidEndpoint = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testAppleIntelligenceBudgetFollowsTheEffectiveInsertionMode() {
        let replace = preset(.replaceSelection)
        let selected = AICommandExecutor.SelectionContext(text: "x", anchorRange: NSRange(location: 0, length: 1),
                                                          hasExplicitSelection: true)
        var paragraph = selected
        paragraph.hasExplicitSelection = false
        XCTAssertEqual(AICommandExecutor.effectiveMode(of: replace, context: selected), .replaceSelection)
        // No selection: the answer is appended, so the larger budget applies.
        XCTAssertEqual(AICommandExecutor.effectiveMode(of: replace, context: paragraph), .appendBelow)
    }
}
