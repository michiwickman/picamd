import XCTest
import AppKit
@testable import PicaMD

// Regression tests for the fixes from the September 2026 review. Each
// test names the behaviour that used to be wrong.

// MARK: - Typing helpers (auto-pair / smart punctuation)

final class TypingRulesTests: XCTestCase {

    func testApostropheAfterLetterIsNotPaired() {
        // "don" + ' used to become "don''" → typing "t" gave "don't'".
        XCTAssertNil(MarkdownEdits.autoPair(input: "'", in: "don", selection: NSRange(location: 3, length: 0)))
        XCTAssertNil(MarkdownEdits.autoPair(input: "\"", in: "say", selection: NSRange(location: 3, length: 0)))
    }

    func testQuoteAtWordStartIsPaired() {
        let r = MarkdownEdits.autoPair(input: "\"", in: "say ", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(r?.text, "say \"\"")
    }

    func testNoPairDirectlyBeforeAWord() {
        XCTAssertNil(MarkdownEdits.autoPair(input: "(", in: "word", selection: NSRange(location: 0, length: 0)))
    }

    func testThirdBacktickOfAFenceIsNotPaired() {
        // ` → `|` ; second ` skips over ; third must just insert.
        XCTAssertNil(MarkdownEdits.autoPair(input: "`", in: "``", selection: NSRange(location: 2, length: 0)))
        XCTAssertNotNil(MarkdownEdits.autoPair(input: "`", in: "", selection: NSRange(location: 0, length: 0)))
    }

    func testWrappingEmojiSelectionSelectsWholeScalars() {
        let text = "a 👍🏽 b"
        let sel = (text as NSString).range(of: "👍🏽")
        let r = MarkdownEdits.autoPair(input: "(", in: text, selection: sel)
        XCTAssertEqual(r?.selection.length, sel.length, "selection length is UTF-16, not graphemes")
    }

    func testSmartPunctuationStaysOutOfMarkdownSyntax() {
        func allowed(_ text: String) -> Bool {
            MarkdownEdits.smartPunctuationAllowed(in: text, at: (text as NSString).length)
        }
        XCTAssertFalse(allowed("--"), "thematic break / frontmatter fence")
        XCTAssertFalse(allowed("|--"), "table separator row")
        XCTAssertFalse(allowed("run `git --"), "inside inline code")
        XCTAssertFalse(allowed("```\nx --"), "inside a fenced block")
        XCTAssertFalse(allowed("---\ntitle: a --"), "inside frontmatter")
        XCTAssertFalse(allowed("<!-- note --"), "inside an HTML comment")
        XCTAssertFalse(allowed("[a](http://x.y/a--"), "inside a link destination")
        XCTAssertTrue(allowed("Hello --"))
        XCTAssertTrue(allowed("```\ncode\n```\nprose --"), "after a closed fence")
    }

    func testSmartPunctuationIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "PicaMDTypingDefaults-\(UUID().uuidString)")!
        EditorPreferences.registerDefaults(defaults)
        XCTAssertFalse(defaults.bool(forKey: EditorPreferences.smartPunctuationKey))
        XCTAssertTrue(defaults.bool(forKey: EditorPreferences.autoPairKey))
    }

    @MainActor
    func testMinimalChangeReplacesOnlyTheDifference() {
        let c = PicaMDTextView.minimalChange(from: "Hello world", to: "Hello (world)")
        XCTAssertEqual(c.range, NSRange(location: 6, length: 5))
        XCTAssertEqual(c.replacement, "(world)")

        let insert = PicaMDTextView.minimalChange(from: "ab", to: "a()b")
        XCTAssertEqual(insert.range, NSRange(location: 1, length: 0))
        XCTAssertEqual(insert.replacement, "()")
    }

    @MainActor
    func testMinimalChangeNeverSplitsSurrogatePairs() {
        // 😀 and 😃 share their high surrogate.
        let c = PicaMDTextView.minimalChange(from: "x😀y", to: "x😃y")
        let old = "x😀y" as NSString
        let replaced = old.replacingCharacters(in: c.range, with: c.replacement)
        XCTAssertEqual(replaced, "x😃y")
        XCTAssertEqual(c.range, NSRange(location: 1, length: 2))
    }
}

// MARK: - Shortcuts

final class ShortcutModifierTests: XCTestCase {

    private func key(_ mods: NSEvent.ModifierFlags, chars: String = "", code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testArrowKeysWithNumericPadAndFunctionFlagsStillMatch() {
        // Real arrow-key events carry .numericPad + .function; ⌘⌥↑ never fired.
        let up = key([.command, .option, .numericPad, .function], code: 0x7E)
        XCTAssertEqual(KeybindingMap.default.action(for: up), .moveLineUp)
    }

    func testCapsLockDoesNotDisableShortcuts() {
        let h1 = key([.command, .capsLock], chars: "1", code: 0x12)
        XCTAssertEqual(KeybindingMap.default.action(for: h1), .headingH1)
    }
}

// MARK: - AI

final class AIReviewFixesTests: XCTestCase {

    private func preset(system: String?, template: String) -> AIPreset {
        AIPreset(id: UUID(), name: "p", systemPrompt: system, userPromptTemplate: template,
                 insertionMode: .appendBelow, hotkey: nil)
    }

    func testPresetWithoutInstructionAsksForOne() {
        XCTAssertTrue(preset(system: nil, template: "{{selection}}").needsInstruction)
        XCTAssertTrue(preset(system: "x", template: "{{prompt}}: {{selection}}").needsInstruction)
        XCTAssertFalse(preset(system: "Fix grammar.", template: "{{selection}}").needsInstruction)
        let custom = AIPreset.defaults.first { $0.hotkey == 9 }
        XCTAssertEqual(custom?.needsInstruction, true)
    }

    func testInstructionIsSubstitutedOrPrepended() {
        let withPlaceholder = preset(system: nil, template: "Task: {{prompt}}\n{{selection}}")
        XCTAssertEqual(withPlaceholder.resolvePrompt(selection: "S", instruction: "Do X"), "Task: Do X\nS")
        let bare = preset(system: nil, template: "{{selection}}")
        XCTAssertEqual(bare.resolvePrompt(selection: "S", instruction: "Do X"), "Do X\n\nS")
    }

    func testAnthropicMaxTokensStopIsAnError() {
        let json = #"{"content":[{"type":"text","text":"half an ans"}],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try AIProvider.anthropic.parseResponseText(Data(json.utf8)))
    }

    func testAnthropicRefusalIsAnError() {
        let json = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try AIProvider.anthropic.parseResponseText(Data(json.utf8)))
    }

    func testOpenAILengthFinishIsAnError() {
        let json = #"{"choices":[{"message":{"content":"cut"},"finish_reason":"length"}]}"#
        XCTAssertThrowsError(try AIClient.parseChatResponse(Data(json.utf8)))
    }

    func testOpenAIUsesMaxCompletionTokensOnlyForOpenAIItself() throws {
        func body(_ provider: AIProvider, _ endpoint: String) throws -> [String: Any] {
            let req = try AIRequestBuilder.build(provider: provider, endpoint: URL(string: endpoint)!,
                                                 apiKey: "k", request: AICompletionRequest(userPrompt: "hi", model: "m"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        }
        let openai = try body(.openai, "https://api.openai.com/v1")
        XCTAssertNotNil(openai["max_completion_tokens"])
        XCTAssertNil(openai["max_tokens"])
        let groq = try body(.openai, "https://api.groq.com/openai/v1")
        XCTAssertNotNil(groq["max_tokens"])
        let local = try body(.localOpenAICompat, "http://localhost:1234/v1")
        XCTAssertEqual(local["max_tokens"] as? Int, 2048)
    }

    func testAnthropicOutputCapLeavesRoomForThinking() throws {
        let req = try AIRequestBuilder.build(provider: .anthropic, endpoint: URL(string: "https://api.anthropic.com/v1")!,
                                             apiKey: "k", request: AICompletionRequest(userPrompt: "hi", model: "m"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertGreaterThanOrEqual(json["max_tokens"] as? Int ?? 0, 16_000)
    }

    @MainActor
    func testReplaceKeepsTheSelectionsTrailingNewline() {
        let (lead, trail) = AICommandExecutor.surroundingWhitespace(of: "Line A\n")
        XCTAssertEqual(lead, "")
        XCTAssertEqual(trail, "\n")
        let (l2, t2) = AICommandExecutor.surroundingWhitespace(of: "\n\n")
        XCTAssertEqual(l2 + t2, "\n\n")
    }

    @MainActor
    func testAppendGoesAfterTheWholeBlock() {
        let src = "First line of\na wrapped paragraph.\n\nNext block."
        // Selection = "First" → insert after "paragraph.", not mid-sentence.
        let end = AICommandExecutor.blockEnd(after: NSRange(location: 0, length: 5), in: src)
        XCTAssertEqual((src as NSString).substring(to: end), "First line of\na wrapped paragraph.")
        // At the end of the document.
        let last = AICommandExecutor.blockEnd(after: (src as NSString).range(of: "Next"), in: src)
        XCTAssertEqual(last, (src as NSString).length)
    }

    @MainActor
    func testResponseFollowsTextThatMovedWhileWaiting() {
        let ctx = AICommandExecutor.SelectionContext(text: "target", anchorRange: NSRange(location: 4, length: 6),
                                                     hasExplicitSelection: true)
        XCTAssertEqual(AICommandExecutor.relocate(ctx, in: "abc target"), NSRange(location: 4, length: 6))
        // User typed "XYZ " in front while the request ran.
        XCTAssertEqual(AICommandExecutor.relocate(ctx, in: "XYZ abc target"), NSRange(location: 8, length: 6))
        // …or deleted it.
        XCTAssertNil(AICommandExecutor.relocate(ctx, in: "abc"))
    }
}

// MARK: - Images & assets

final class ImageAssetTests: XCTestCase {

    @MainActor
    func testImageDestinationsResolveLikeMarkdown() {
        let doc = URL(fileURLWithPath: "/Users/me/notes/doc.md")
        XCTAssertEqual(ImageBlockView.resolve("./assets/a.png", relativeTo: doc)?.path, "/Users/me/notes/assets/a.png")
        XCTAssertEqual(ImageBlockView.resolve("<./assets/a b.png>", relativeTo: doc)?.path, "/Users/me/notes/assets/a b.png")
        XCTAssertEqual(ImageBlockView.resolve("assets/a%20b.png", relativeTo: doc)?.path, "/Users/me/notes/assets/a b.png")
        XCTAssertEqual(ImageBlockView.resolve("x.png \"Title\"", relativeTo: doc)?.path, "/Users/me/notes/x.png")
        XCTAssertEqual(ImageBlockView.resolve("/tmp/a.png", relativeTo: doc)?.path, "/tmp/a.png")
        XCTAssertEqual(ImageBlockView.resolve("https://e.com/a.png", relativeTo: nil)?.absoluteString, "https://e.com/a.png")
        XCTAssertNil(ImageBlockView.resolve("a.png", relativeTo: nil), "relative path needs a saved document")
    }

    func testAssetNamesAreLinkSafe() {
        XCTAssertEqual(MarkdownAssets.safeFileName("Screenshot 2026-09-24 at 12.00.00"),
                       "Screenshot-2026-09-24-at-12.00.00")
        XCTAssertEqual(MarkdownAssets.safeFileName("a (1)"), "a-1")
        XCTAssertEqual(MarkdownAssets.safeFileName("photo"), "photo")
        XCTAssertEqual(MarkdownAssets.safeFileName("   "), "image")
    }

    func testAltTextBracketsDoNotBreakTheLink() {
        let img = MarkdownAssets.SavedImage(absoluteURL: URL(fileURLWithPath: "/x"),
                                            markdownPath: "./assets/x.png", altText: "a [b]")
        XCTAssertEqual(MarkdownAssets.markdownSyntax(for: img), "![a (b)](./assets/x.png)")
    }
}

// MARK: - Blocks, footnotes, headings

final class RenderingReviewFixesTests: XCTestCase {

    func testOneLineDisplayMathDoesNotSwallowTheDocument() {
        let src = "$$E=mc^2$$\n\nSome prose.\n\n- [ ] task\n\n$$\n\\int x\n$$\n"
        let maths = BlockExtractor.extract(from: src).filter { $0.kind == .mathBlock }
        XCTAssertEqual(maths.map(\.payload), ["$$E=mc^2$$", "$$\n\\int x\n$$"])
    }

    func testMathBlockDoesNotEatFollowingBlankLines() {
        let src = "$$\nx\n$$\n\n\nAfter"
        let math = BlockExtractor.extract(from: src).first { $0.kind == .mathBlock }
        XCTAssertEqual(math?.payload, "$$\nx\n$$")
    }

    func testCRLFTableParses() {
        let block = ExtractedBlock(range: NSRange(location: 0, length: 0), kind: .table,
                                   payload: "| A | B |\r\n|---|---|\r\n| 1 | 2 |")
        let t = block.parseTable()
        XCTAssertEqual(t?.headers, ["A", "B"])
        XCTAssertEqual(t?.rows, [["1", "2"]])
    }

    func testFootnoteLookalikesInCodeAreIgnored() {
        let src = "Real[^1] and `[^a-z]`\n\n```\nre = /[^0-9]/\n```\n\n[^1]: Note."
        let index = FootnoteIndex.build(from: src)
        XCTAssertEqual(index.refs.map(\.id), ["1"])
    }

    func testHeadingTitlesKeepIdentifiers() {
        let h = HeadingExtractor.extract(from: "## The `snake_case` **rule**")
        XCTAssertEqual(h.first?.text, "The snake_case rule")
    }

    func testTextStats() {
        let s = TextStats("One two\nthree  four\n")
        XCTAssertEqual(s.words, 4)
        XCTAssertEqual(s.lines, 3)
        XCTAssertEqual(TextStats("").words, 0)
        XCTAssertEqual(TextStats.lineNumbers(at: [0, 4, 8], in: "a\nb\nc\nd\ne"), [1, 3, 5])
    }
}

// MARK: - HTML export

final class HTMLExportReviewFixesTests: XCTestCase {

    func testCodeFenceLanguageCannotInjectMarkup() {
        let out = MarkdownToHTML.render("```x\"><svg/onload=alert(1)>\ncode\n```")
        XCTAssertFalse(out.contains("<svg"))
        // (The page itself has onload="renderMathInElement…" for KaTeX.)
        XCTAssertFalse(out.contains("onload=alert"))
        XCTAssertTrue(out.contains("<pre><code class=\"language-x\">"))
    }

    func testHighlightAndFootnoteSyntaxInsideCodeIsLeftAlone() {
        let out = MarkdownToHTML.render("```\nif (a == b || c == d) { x = /[^a-z]/ }\n```")
        XCTAssertFalse(out.contains("<mark>"))
        XCTAssertFalse(out.contains("<sup class=\"footnote-ref\""))
        XCTAssertFalse(out.contains("<section class=\"footnotes\""))
        XCTAssertTrue(out.contains("a == b || c == d"))
    }

    func testMathReachesKaTeXUntouched() {
        let out = MarkdownToHTML.render("Inline $a_1 + b_1$ and\n\n$$\n\\begin{matrix} a \\\\ b \\end{matrix}\n$$")
        XCTAssertTrue(out.contains("$a_1 + b_1$"), "no <em> inside math")
        XCTAssertTrue(out.contains("a \\\\ b"), "double backslash kept for KaTeX")
    }

    func testScriptURLsAreNeutralised() {
        XCTAssertFalse(MarkdownToHTML.render("[x](javascript:alert(1))").contains("javascript:"))
        XCTAssertFalse(MarkdownToHTML.render("<a href=\"jav&#x61;script:alert(1)\">x</a>").contains("script:alert"))
        XCTAssertTrue(MarkdownToHTML.render("[ok](https://apple.com)").contains("href=\"https://apple.com\""))
        XCTAssertTrue(MarkdownToHTML.render("[frag](#top)").contains("href=\"#top\""))
    }

    func testSanitizerCatchesSlashSeparatedHandlersAndSplicedTags() {
        let a = MarkdownToHTML.sanitizeHTML("<svg/onload=alert(1)>")
        XCTAssertFalse(a.lowercased().contains("onload"))
        let b = MarkdownToHTML.sanitizeHTML("<scr<script>x</script>ipt>alert(1)</script>")
        XCTAssertFalse(b.lowercased().contains("<script"))
    }
}
