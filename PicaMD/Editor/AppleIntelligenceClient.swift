import Foundation
import FoundationModels
import Observation

/// Why Apple Intelligence can or can't run, phrased for the user.
/// Pure value, so the mapping is testable without the model.
enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    case notEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailable

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:  self = .notEnabled
            case .deviceNotEligible:            self = .deviceNotEligible
            case .modelNotReady:                self = .modelNotReady
            @unknown default:                   self = .unavailable
            }
        }
    }

    /// Short state for the Settings status row.
    var title: String {
        switch self {
        case .available:          return "Available"
        case .notEnabled:         return "Turned off"
        case .deviceNotEligible:  return "Not supported on this Mac"
        case .modelNotReady:      return "Preparing the model"
        case .unavailable:        return "Unavailable"
        }
    }

    /// What it means and what to do about it.
    var message: String {
        switch self {
        case .available:
            return "Runs on this Mac. Nothing you send leaves it."
        case .notEnabled:
            return "Apple Intelligence is turned off. Turn it on in System Settings ▸ Apple Intelligence & Siri."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence. Use Anthropic, OpenAI or a custom provider instead."
        case .modelNotReady:
            return "The on-device model is still downloading or getting ready. Try again in a few minutes."
        case .unavailable:
            return "Apple Intelligence isn't available right now. Check System Settings ▸ Apple Intelligence & Siri."
        }
    }

    /// Only "turned off" has a remedy in System Settings.
    var offersSystemSettings: Bool { self == .notEnabled }

    /// The "Apple Intelligence & Siri" pane. Id from
    /// /System/Library/ExtensionKit/Extensions/SiriPreferenceExtension.appex
    /// (CFBundleIdentifier, allowsXAppleSystemPreferencesURLScheme = true).
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}

/// Shared access to the system model, configured the one way PicaMD
/// uses it.
enum AppleIntelligence {
    /// Presets turn text into text, so the permissive guardrails fit:
    /// the default ones rejected a harmless German text as unsafe (measured).
    static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    static var status: AppleIntelligenceStatus {
        AppleIntelligenceStatus(makeModel().availability)
    }

    static var isAvailable: Bool { status == .available }

    /// Context window in tokens. The system has been seen to report 0
    /// right after boot (third-party measurement); the smaller model's
    /// 4096 is a safe floor.
    static func effectiveContextSize(_ reported: Int) -> Int {
        reported > 0 ? reported : 4096
    }
}

/// Live status for Settings ▸ AI. `SystemLanguageModel` is observable,
/// so a change of `availability` (model finished downloading, Apple
/// Intelligence switched in System Settings) re-reads the state; the
/// view also calls `refresh()` when the app becomes active, in case the
/// system doesn't notify.
@MainActor
@Observable
final class AppleIntelligenceMonitor {
    private(set) var status: AppleIntelligenceStatus = .unavailable
    /// e.g. "AFM 3 Core Advanced"; `nil` while unavailable.
    private(set) var variantName: String?
    private(set) var contextSize: Int = 0

    @ObservationIgnored private let model = AppleIntelligence.makeModel()

    /// Whether an observation of `availability` is pending. The view
    /// calls `refresh()` on every activation; registering each time
    /// would stack observations, and one change would then refresh
    /// once per earlier activation.
    @ObservationIgnored private var isObserving = false
    /// How many observations were registered, for tests.
    @ObservationIgnored private(set) var observationRegistrations = 0

    init() { refresh() }

    func refresh() {
        let model = self.model
        let availability: SystemLanguageModel.Availability
        if isObserving {
            availability = model.availability
        } else {
            isObserving = true
            observationRegistrations += 1
            // `onChange` fires once; the refresh it schedules registers
            // the next observation.
            availability = withObservationTracking {
                model.availability
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.isObserving = false
                    self?.refresh()
                }
            }
        }
        status = AppleIntelligenceStatus(availability)
        if status == .available {
            variantName = model.variant.displayName
            contextSize = AppleIntelligence.effectiveContextSize(model.contextSize)
        } else {
            variantName = nil
            contextSize = 0
        }
    }
}

/// How much text fits, decided before the model runs. Overrunning the
/// context window fails only after the whole generation time (measured
/// 83–95 s) and returns nothing, so a selection that can't fit is
/// rejected up front.
enum AppleIntelligenceBudget {
    /// Framing tokens not covered by the separate counts of prompt and
    /// instructions (measured about 8) plus rounding.
    static let safetyMargin = 64
    /// Room kept for the answer of a preset that adds text (summary,
    /// continuation, translation below the selection).
    static let minimumAnswerTokens = 1024

    /// The largest input (instructions + text, in tokens) that fits.
    /// A replacing preset answers with about as much text as it got,
    /// so its input may use about half the window.
    static func maximumInputTokens(contextSize: Int, replacesSelection: Bool) -> Int {
        let context = AppleIntelligence.effectiveContextSize(contextSize)
        return replacesSelection ? context / 2 : context - safetyMargin - minimumAnswerTokens
    }

    /// The answer's token limit for `GenerationOptions`, or
    /// `AIError.tooLongForAppleIntelligence` when the input doesn't fit.
    static func outputTokens(inputTokens: Int, contextSize: Int,
                             requestedMaxTokens: Int, replacesSelection: Bool) throws -> Int {
        let limit = maximumInputTokens(contextSize: contextSize, replacesSelection: replacesSelection)
        guard inputTokens <= limit else {
            throw AIError.tooLongForAppleIntelligence(tokens: inputTokens, limit: limit)
        }
        let context = AppleIntelligence.effectiveContextSize(contextSize)
        return max(1, min(requestedMaxTokens, context - inputTokens - safetyMargin))
    }
}

/// `AICompleting` on the on-device model. One fresh
/// `LanguageModelSession` per request: a session serves one request at
/// a time, and the editor allows one request per window anyway.
struct AppleIntelligenceClient: AICompleting {
    /// Whether the answer will replace the selection; decides the
    /// input budget (see `AppleIntelligenceBudget`).
    var replacesSelection: Bool

    func complete(systemPrompt: String?, userText: String, maxTokens: Int) async throws -> String {
        let model = AppleIntelligence.makeModel()
        let status = AppleIntelligenceStatus(model.availability)
        guard status == .available else {
            throw AIError.appleIntelligenceUnavailable(status.message)
        }
        let instructions = systemPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let inputTokens = await Self.countTokens(model: model, instructions: instructions, prompt: userText)
        try Task.checkCancellation()
        let limit = try AppleIntelligenceBudget.outputTokens(
            inputTokens: inputTokens,
            contextSize: model.contextSize,
            requestedMaxTokens: maxTokens,
            replacesSelection: replacesSelection
        )

        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            // System-default sampling: "expand" and "write more
            // naturally" should vary; only the length is capped.
            let response = try await session.respond(
                to: userText,
                options: GenerationOptions(maximumResponseTokens: limit)
            )
            if Self.isTruncated(outputTokens: response.usage.output.totalTokenCount, limit: limit) {
                throw AIError.truncated
            }
            return response.content
        } catch let error as AIError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    /// The framework reports no stop reason, and an answer cut at
    /// `maximumResponseTokens` comes back as a normal success. Cut
    /// answers always count at least the limit; complete ones count up
    /// to about 7 tokens more than their text (measured), so the limit is
    /// generous and a hit means "cut".
    static func isTruncated(outputTokens: Int, limit: Int) -> Bool {
        outputTokens >= limit
    }

    /// Instructions and prompt counted separately; the turn framing the
    /// sum misses is inside `AppleIntelligenceBudget.safetyMargin`. If
    /// counting fails (model busy), estimate 3 characters per token.
    static func countTokens(model: SystemLanguageModel, instructions: String?, prompt: String) async -> Int {
        do {
            var count = try await model.tokenCount(for: prompt)
            if let instructions {
                count += try await model.tokenCount(for: Instructions(instructions))
            }
            return count
        } catch {
            let characters = prompt.count + (instructions?.count ?? 0)
            return Int((Double(characters) / 3.0).rounded(.up))
        }
    }

    /// Framework errors → `AIError` with a message the user can act on.
    /// `CancellationError` (Esc) and anything unknown pass through
    /// unchanged; the executor treats cancellation as "not a failure".
    static func map(_ error: any Error) -> any Error {
        switch error {
        case let e as LanguageModelError:
            switch e {
            case .contextSizeExceeded(let detail):
                return AIError.tooLongForAppleIntelligence(tokens: detail.tokenCount, limit: detail.contextSize)
            case .guardrailViolation:
                return AIError.refused("Apple Intelligence's safety filter flagged this text.")
            case .refusal:
                return AIError.refused(nil)
            case .rateLimited:
                return AIError.appleIntelligence("Apple Intelligence is busy right now. Try again in a moment.")
            case .timeout:
                return AIError.appleIntelligence("Apple Intelligence didn't answer in time. Try again, or select less text.")
            case .unsupportedLanguageOrLocale:
                return AIError.appleIntelligence("Apple Intelligence doesn't support the language of this text. Use Anthropic or OpenAI instead.")
            default:
                return AIError.appleIntelligence("Apple Intelligence failed: \(e.localizedDescription)")
            }
        case let e as LanguageModelSession.Error:
            if e == .concurrentRequests {
                return AIError.appleIntelligence("Apple Intelligence is still working on another request.")
            }
            return AIError.appleIntelligence("Apple Intelligence failed: \(e.localizedDescription)")
        case is SystemLanguageModel.Error:
            return AIError.appleIntelligenceUnavailable(AppleIntelligenceStatus.modelNotReady.message)
        default:
            return error
        }
    }
}
