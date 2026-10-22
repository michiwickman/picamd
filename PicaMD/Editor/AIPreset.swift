import Foundation

/// One user-invokable AI command. Combines a prompt template, an
/// insertion mode, and (optionally) a keyboard shortcut.
///
/// The prompt template uses `{{selection}}` as the placeholder for
/// the user's current selection or paragraph. We chose this instead
/// of plain `%@` so the templates are also human-readable in Settings.
struct AIPreset: Codable, Equatable, Identifiable {

    /// Stable UUID — used both as `id` and as the preset's row key in
    /// `AIPresetStore`. Generated on creation, never reassigned.
    var id: UUID
    var name: String
    var systemPrompt: String?
    var userPromptTemplate: String
    var insertionMode: InsertionMode

    /// 1…9 = `⌃⌘<digit>` shortcut, `nil` = preset is invocable only
    /// through the `⌃Space` fuzzy picker. We deliberately limit to
    /// single-digit shortcuts to keep the keyboard surface predictable.
    var hotkey: Int?

    /// Optional per-preset provider/model override. When `nil` the
    /// preset uses whatever's set as the default in `AIConfig`.
    var providerOverride: AIProviderRef?
    var modelOverride: String?

    init(id: UUID,
         name: String,
         systemPrompt: String?,
         userPromptTemplate: String,
         insertionMode: InsertionMode,
         hotkey: Int?,
         providerOverride: AIProviderRef? = nil,
         modelOverride: String? = nil) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.insertionMode = insertionMode
        self.hotkey = hotkey
        self.providerOverride = providerOverride
        self.modelOverride = modelOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, userPromptTemplate, insertionMode, hotkey
        case providerOverride, modelOverride
    }

    /// The overrides decode leniently: a provider this version doesn't
    /// know (or one that was removed) must not fail the whole preset
    /// array — `AIPresetStore` would then fall back to the starter set
    /// and the next edit would overwrite the user's presets. Such a
    /// preset just uses the default provider.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        userPromptTemplate = try c.decode(String.self, forKey: .userPromptTemplate)
        insertionMode = try c.decode(InsertionMode.self, forKey: .insertionMode)
        hotkey = try c.decodeIfPresent(Int.self, forKey: .hotkey)
        providerOverride = (try? c.decodeIfPresent(String.self, forKey: .providerOverride))
            .flatMap { $0 }
            .flatMap(AIProviderRef.init(storageValue:))
        modelOverride = (try? c.decodeIfPresent(String.self, forKey: .modelOverride)) ?? nil
    }

    enum InsertionMode: String, Codable, CaseIterable, Identifiable {
        case replaceSelection
        case appendBelow
        case asBlockquote
        case asHTMLComment
        case showInPopover

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .replaceSelection:  return "Replace selection"
            case .appendBelow:       return "Append below"
            case .asBlockquote:      return "Insert as blockquote"
            case .asHTMLComment:     return "Insert as HTML comment"
            case .showInPopover:     return "Show in popover (don't insert)"
            }
        }
    }

    /// Render the user-prompt template against a concrete selection.
    /// Returns the substituted prompt with `{{selection}}` replaced.
    /// If the template doesn't contain the placeholder, we APPEND the
    /// selection on a new line — that's friendlier than silently
    /// dropping the user's text when they edited a template wrong.
    func resolvePrompt(selection: String, instruction: String? = nil) -> String {
        var template = userPromptTemplate
        if let instruction, !instruction.isEmpty {
            if template.contains(Self.instructionPlaceholder) {
                template = template.replacingOccurrences(of: Self.instructionPlaceholder, with: instruction)
            } else {
                template = instruction + "\n\n" + template
            }
        }
        let placeholder = "{{selection}}"
        if template.contains(placeholder) {
            return template.replacingOccurrences(of: placeholder, with: selection)
        }
        return template + "\n\n" + selection
    }

    /// `{{prompt}}` in a template means "ask me what to do each time".
    static let instructionPlaceholder = "{{prompt}}"

    /// Whether running this preset should first ask the user for an
    /// instruction: its template says so, or it carries no instruction
    /// at all (no system prompt and a bare `{{selection}}` template —
    /// the starter "Custom prompt" preset), which would otherwise send
    /// the selection with nothing to do.
    var needsInstruction: Bool {
        if userPromptTemplate.contains(Self.instructionPlaceholder) { return true }
        let hasSystem = !(systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let bare = userPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines) == "{{selection}}"
        return !hasSystem && bare
    }
}

// MARK: - Default starter presets

extension AIPreset {
    /// 9 built-in presets the user can immediately try after enabling
    /// AI. Their hotkeys are pre-bound to ⌃⌘1…⌃⌘9.
    ///
    /// They're written to keep answers short for snappy UX, and each
    /// fits everyday writing: drafts, project notes, README-style docs.
    /// The names are English; the prompts keep the language of the
    /// selected text. Stored presets keep the names they were saved
    /// with, so this list only reaches new installs and Reset.
    static let defaults: [AIPreset] = [
        AIPreset(
            id: UUID(),
            name: "Clean Up Markdown",
            systemPrompt: "You're a careful Markdown editor. Clean up the user's text into well-formed Markdown without changing meaning. Replace fancy quotes with straight quotes, em-dashes (—) with comma or parentheses where appropriate, normalise whitespace, fix obvious typos. Output ONLY the cleaned Markdown, no preamble.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .replaceSelection,
            hotkey: 1
        ),
        AIPreset(
            id: UUID(),
            name: "Summarize",
            systemPrompt: "You're a concise summarizer. Produce a crisp 3–5 bullet summary of the user's text. Keep the user's language (German stays German). Output ONLY the bullet list, no preamble.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .asBlockquote,
            hotkey: 2
        ),
        AIPreset(
            id: UUID(),
            name: "Rewrite Naturally",
            systemPrompt: "Rewrite the user's text in natural, flowing prose. Keep the same language. Same tone, same level of formality. Don't add new information. Output ONLY the rewritten text.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .replaceSelection,
            hotkey: 3
        ),
        AIPreset(
            id: UUID(),
            name: "Continue Paragraph",
            systemPrompt: "Continue the user's paragraph naturally — same tone, same direction. Add 2–4 sentences of substance. Same language. Don't repeat what's already said. Output ONLY the new continuation, starting from where the user left off.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .appendBelow,
            hotkey: 4
        ),
        AIPreset(
            id: UUID(),
            name: "Fix Grammar & Spelling",
            systemPrompt: "Fix grammar, punctuation, and spelling in the user's text. Don't change meaning, voice, or vocabulary unless required for correctness. Same language. Output ONLY the corrected text.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .replaceSelection,
            hotkey: 5
        ),
        AIPreset(
            id: UUID(),
            name: "Translate (German ↔ English)",
            systemPrompt: "Translate the user's text. If it's German, translate to English. If it's English, translate to German. If it's a mix, default to whichever is dominant. Preserve Markdown formatting. Output ONLY the translation.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .appendBelow,
            hotkey: 6
        ),
        AIPreset(
            id: UUID(),
            name: "Make More Formal",
            systemPrompt: "Rewrite the user's text in a more formal register — appropriate for a business letter or technical documentation. Same language. Same factual content. Output ONLY the rewritten text.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .replaceSelection,
            hotkey: 7
        ),
        AIPreset(
            id: UUID(),
            name: "Make More Casual",
            systemPrompt: "Rewrite the user's text in a more casual, conversational register. Same language. Same factual content. Output ONLY the rewritten text.",
            userPromptTemplate: "{{selection}}",
            insertionMode: .replaceSelection,
            hotkey: 8
        ),
        AIPreset(
            id: UUID(),
            name: "Custom Prompt",
            systemPrompt: nil,
            userPromptTemplate: "{{prompt}}\n\n{{selection}}",
            insertionMode: .appendBelow,
            hotkey: 9
        ),
    ]
}
