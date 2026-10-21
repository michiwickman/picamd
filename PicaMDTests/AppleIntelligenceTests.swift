import XCTest
import FoundationModels
@testable import PicaMD

/// Apple Intelligence without the model: status mapping, the token
/// budget, truncation and error mapping. CI runners have no Apple
/// Intelligence, so nothing here calls `respond`.
final class AppleIntelligenceTests: XCTestCase {

    // MARK: Status

    func testAvailabilityMapsToStatus() {
        XCTAssertEqual(AppleIntelligenceStatus(.available), .available)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.appleIntelligenceNotEnabled)), .notEnabled)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.deviceNotEligible)), .deviceNotEligible)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.modelNotReady)), .modelNotReady)
    }

    func testOnlyTurnedOffOffersSystemSettings() {
        let all: [AppleIntelligenceStatus] = [.available, .notEnabled, .deviceNotEligible, .modelNotReady, .unavailable]
        XCTAssertEqual(all.filter(\.offersSystemSettings), [.notEnabled])
        XCTAssertTrue(AppleIntelligenceStatus.notEnabled.message.contains("System Settings"))
        XCTAssertEqual(AppleIntelligenceStatus.systemSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        for status in all {
            XCTAssertFalse(status.message.isEmpty)
            XCTAssertFalse(status.title.isEmpty)
        }
    }

    func testZeroContextSizeCountsAs4096() {
        XCTAssertEqual(AppleIntelligence.effectiveContextSize(0), 4096)
        XCTAssertEqual(AppleIntelligence.effectiveContextSize(8192), 8192)
    }

    // MARK: Budget (reject before running)

    func testReplacingPresetMayUseHalfTheWindow() throws {
        XCTAssertEqual(AppleIntelligenceBudget.maximumInputTokens(contextSize: 8192, replacesSelection: true), 4096)
        let output = try AppleIntelligenceBudget.outputTokens(inputTokens: 4096, contextSize: 8192,
                                                              requestedMaxTokens: 16_000, replacesSelection: true)
        XCTAssertEqual(output, 8192 - 4096 - AppleIntelligenceBudget.safetyMargin)
        XCTAssertThrowsError(try AppleIntelligenceBudget.outputTokens(inputTokens: 4097, contextSize: 8192,
                                                                      requestedMaxTokens: 16_000, replacesSelection: true)) {
            XCTAssertEqual($0 as? AIError, .tooLongForAppleIntelligence(tokens: 4097, limit: 4096))
        }
    }

    func testAddingPresetKeepsRoomForTheAnswer() throws {
        let limit = 8192 - AppleIntelligenceBudget.safetyMargin - AppleIntelligenceBudget.minimumAnswerTokens
        XCTAssertEqual(AppleIntelligenceBudget.maximumInputTokens(contextSize: 8192, replacesSelection: false), limit)
        let output = try AppleIntelligenceBudget.outputTokens(inputTokens: limit, contextSize: 8192,
                                                              requestedMaxTokens: 16_000, replacesSelection: false)
        XCTAssertEqual(output, AppleIntelligenceBudget.minimumAnswerTokens)
        XCTAssertThrowsError(try AppleIntelligenceBudget.outputTokens(inputTokens: limit + 1, contextSize: 8192,
                                                                      requestedMaxTokens: 16_000, replacesSelection: false))
        // A small input gets the requested cap, not the whole window.
        XCTAssertEqual(try AppleIntelligenceBudget.outputTokens(inputTokens: 100, contextSize: 8192,
                                                                requestedMaxTokens: 500, replacesSelection: false), 500)
    }

    func testColdStartBudgetUsesTheSmallWindow() {
        XCTAssertEqual(AppleIntelligenceBudget.maximumInputTokens(contextSize: 0, replacesSelection: true), 2048)
        XCTAssertThrowsError(try AppleIntelligenceBudget.outputTokens(inputTokens: 3000, contextSize: 0,
                                                                      requestedMaxTokens: 16_000, replacesSelection: true))
    }

    func testTooLongMessageNamesTheCountsAndTheAlternative() {
        let message = AIError.tooLongForAppleIntelligence(tokens: 5000, limit: 4096).errorDescription
        XCTAssertEqual(message,
                       "This selection is too long for Apple Intelligence (\(5000.formatted()) of \(4096.formatted()) tokens). Use Anthropic or OpenAI for long texts.")
    }

    func testOutputAtTheLimitCountsAsTruncated() {
        XCTAssertTrue(AppleIntelligenceClient.isTruncated(outputTokens: 1024, limit: 1024))
        XCTAssertTrue(AppleIntelligenceClient.isTruncated(outputTokens: 1031, limit: 1024))
        XCTAssertFalse(AppleIntelligenceClient.isTruncated(outputTokens: 1023, limit: 1024))
    }

    // MARK: Error mapping

    func testLanguageModelErrorsMapToClearMessages() {
        func map(_ error: LanguageModelError) -> AIError? {
            AppleIntelligenceClient.map(error) as? AIError
        }
        XCTAssertEqual(map(.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: ""))),
                       .tooLongForAppleIntelligence(tokens: 9000, limit: 8192))
        guard case .refused? = map(.guardrailViolation(.init(debugDescription: ""))) else {
            return XCTFail("guardrail violation should be a refusal")
        }
        XCTAssertEqual(map(.refusal(.init(explanation: "no", debugDescription: ""))), .refused(nil))
        for error: LanguageModelError in [
            .rateLimited(.init(resetDate: nil, debugDescription: "")),
            .timeout(.init(debugDescription: "")),
            .unsupportedLanguageOrLocale(.init(languageCode: Locale.LanguageCode("xx"), debugDescription: "")),
        ] {
            guard case .appleIntelligence(let message)? = map(error) else {
                return XCTFail("\(error) not mapped")
            }
            XCTAssertTrue(message.hasPrefix("Apple Intelligence"), message)
        }
    }

    func testSessionAndAssetErrorsMap() {
        guard case .appleIntelligence(let busy)? = AppleIntelligenceClient.map(LanguageModelSession.Error.concurrentRequests) as? AIError else {
            return XCTFail("concurrent requests not mapped")
        }
        XCTAssertTrue(busy.contains("another request"))
        XCTAssertEqual(AppleIntelligenceClient.map(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: ""))) as? AIError,
                       .appleIntelligenceUnavailable(AppleIntelligenceStatus.modelNotReady.message))
    }

    func testCancellationPassesThroughUnchanged() {
        XCTAssertTrue(AppleIntelligenceClient.map(CancellationError()) is CancellationError)
    }
}

/// Runs the real on-device model. Off unless `PICAMD_LIVE_AI=1`
/// (with xcodebuild: `TEST_RUNNER_PICAMD_LIVE_AI=1`).
final class AppleIntelligenceMonitorTests: XCTestCase {
    /// Settings ▸ AI refreshes on every app activation. That must not
    /// stack observations of the model's availability.
    @MainActor
    func testRepeatedRefreshKeepsOneObservation() {
        let monitor = AppleIntelligenceMonitor()
        for _ in 0..<5 { monitor.refresh() }
        XCTAssertEqual(monitor.observationRegistrations, 1)
    }
}

final class AppleIntelligenceLiveTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PICAMD_LIVE_AI"] == "1",
                          "Set PICAMD_LIVE_AI=1 to run against the on-device model")
        try XCTSkipUnless(AppleIntelligence.isAvailable, "Apple Intelligence is not available on this Mac")
    }

    @MainActor
    func testStatusShowsVariantAndContext() {
        let monitor = AppleIntelligenceMonitor()
        XCTAssertEqual(monitor.status, .available)
        XCTAssertFalse(monitor.variantName?.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(monitor.contextSize, 4096)
        print("PicaMD live AI: \(monitor.variantName ?? "-"), \(monitor.contextSize) tokens")
    }

    func testShortRewrite() async throws {
        let client = AppleIntelligenceClient(replacesSelection: true)
        let answer = try await client.complete(
            systemPrompt: "Fix grammar and spelling. Output ONLY the corrected text.",
            userText: "This are a test sentense.",
            maxTokens: AICompletionRequest.defaultMaxTokens
        )
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("PicaMD live AI answer: \(answer)")
    }

    func testOversizeSelectionIsRejectedBeforeRunning() async {
        let text = String(repeating: "Das ist ein Satz über Markdown. ", count: 1200)
        let start = Date()
        do {
            _ = try await AppleIntelligenceClient(replacesSelection: true)
                .complete(systemPrompt: "Fix grammar.", userText: text, maxTokens: 16_000)
            XCTFail("expected tooLongForAppleIntelligence")
        } catch AIError.tooLongForAppleIntelligence(let tokens, let limit) {
            XCTAssertGreaterThan(tokens, limit)
            print("PicaMD live AI: rejected \(tokens) of \(limit) tokens")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "must fail before generating")
    }

    func testCancelReturnsQuickly() async {
        let task = Task {
            try await AppleIntelligenceClient(replacesSelection: false).complete(
                systemPrompt: nil,
                userText: "Write a long essay about the history of typography.",
                maxTokens: 3000
            )
        }
        try? await Task.sleep(for: .seconds(1))
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        if case .failure(let error) = result {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
