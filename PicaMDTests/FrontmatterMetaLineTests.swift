import XCTest
import AppKit
import SwiftUI
@testable import PicaMD

/// The collapsed front matter: the grey meta line's text, when the block
/// folds, and the highlighter's attributes for both states.
final class FrontmatterMetaLineTests: XCTestCase {

    private let us = Locale(identifier: "en_US")

    private func meta(_ source: String, heading: String? = nil) -> String {
        FrontmatterMetaLine.text(for: Frontmatter.build(from: source), firstHeading: heading, locale: us)
    }

    func testDateAndTags() {
        XCTAssertEqual(meta("---\ndate: 2026-10-03\ntags: [travel, portugal]\n---\n"),
                       "October 3, 2026 · travel, portugal")
    }

    func testTitleEqualToTheFirstHeadingIsLeftOut() {
        let src = "---\ntitle: Trip to Porto\ndate: 2026-10-03\n---\n"
        XCTAssertEqual(meta(src, heading: "Trip to  porto"), "October 3, 2026")
        XCTAssertEqual(meta(src, heading: "Something else"), "Trip to Porto · October 3, 2026")
        XCTAssertEqual(meta(src, heading: nil), "Trip to Porto · October 3, 2026")
    }

    func testBlockWithoutKnownFieldsShowsAPlaceholder() {
        XCTAssertEqual(meta("---\nlayout: post\n---\n"), FrontmatterMetaLine.placeholder)
        XCTAssertEqual(meta("---\n---\n"), FrontmatterMetaLine.placeholder)
    }

    func testUnparseableDateIsShownRaw() {
        XCTAssertEqual(meta("---\ndate: next week\n---\n"), "next week")
        XCTAssertEqual(FrontmatterMetaLine.formattedDate("2026-02-30", locale: us), "2026-02-30")
        XCTAssertEqual(FrontmatterMetaLine.formattedDate("2026-13-01", locale: us), "2026-13-01")
    }

    func testDateFormatsInTheLocale() {
        XCTAssertEqual(FrontmatterMetaLine.formattedDate("2026-10-03", locale: us), "October 3, 2026")
        XCTAssertEqual(FrontmatterMetaLine.formattedDate("2026-10-03", locale: Locale(identifier: "de_DE")),
                       "3. Oktober 2026")
        XCTAssertEqual(InspectorFormat.frontmatterDate("2026-10-03", locale: us), "October 3, 2026")
    }

    /// The time is shown as written, whatever the Mac's time zone.
    func testDateWithTime() {
        let formatted = FrontmatterMetaLine.formattedDate("2026-10-03T14:20:00+02:00", locale: us)
        XCTAssertTrue(formatted.hasPrefix("October 3, 2026"), formatted)
        XCTAssertTrue(formatted.contains("2:20"), formatted)
        let local = FrontmatterMetaLine.formattedDate("2026-10-03 09:05", locale: us)
        XCTAssertTrue(local.contains("9:05"), local)
    }

    func testFirstH1SkipsCodeAndLowerLevels() {
        let src = "---\na: 1\n---\n## Sub\n```\n# not this\n```\n# **Real** title\n# Second\n"
        let code = CheckboxOverlayManager.protectedRanges(in: src)
        let end = NSMaxRange(Frontmatter.build(from: src).range!)
        XCTAssertEqual(FrontmatterMetaLine.firstH1(in: src, from: end, skipping: code), "Real title")
    }

    func testYAMLCommentIsNotAnOutlineHeading() {
        let headings = HeadingExtractor.extract(from: "---\n# draft\ntitle: T\n---\n# Real\n")
        XCTAssertEqual(headings.map(\.text), ["Real"])
    }
}

final class FrontmatterFoldTests: XCTestCase {

    private let source = "---\ntitle: T\n---\nBody" as NSString
    private var block: NSRange { NSRange(location: 0, length: 17) }

    private func folded(_ location: Int, length: Int = 0, in src: NSString? = nil, block b: NSRange? = nil) -> Bool {
        FrontmatterFold.isFolded(selection: NSRange(location: location, length: length),
                                 block: b ?? block, in: src ?? source)
    }

    func testCaretInsideTheBlockRevealsIt() {
        XCTAssertFalse(folded(0))
        XCTAssertFalse(folded(8))
        XCTAssertFalse(folded(16), "end of the closing fence line")
    }

    func testCaretAfterTheBlockFoldsIt() {
        XCTAssertTrue(folded(17))
        XCTAssertTrue(folded(19))
        XCTAssertTrue(folded(17, length: 3))
    }

    func testSelectionStartingInsideRevealsIt() {
        XCTAssertFalse(folded(10, length: 15))
    }

    func testNoCaretFoldsAndAnUnknownCaretReveals() {
        XCTAssertTrue(folded(NSNotFound))
        // The highlighter's "no cursor" default (tests, previews).
        XCTAssertFalse(folded(-1))
    }

    /// A document that is only front matter, without a final line break:
    /// the caret at the end sits on the closing fence and must see it.
    func testOnlyFrontmatterWithoutLineBreak() {
        let src = "---\ntitle: T\n---" as NSString
        let b = NSRange(location: 0, length: 16)
        XCTAssertFalse(folded(16, in: src, block: b))
        let withBreak = "---\ntitle: T\n---\n" as NSString
        XCTAssertTrue(folded(17, in: withBreak, block: NSRange(location: 0, length: 17)))
    }

    func testInitialCaretIsMovedBehindTheBlock() {
        XCTAssertEqual(FrontmatterFold.initialSelection(NSRange(location: 0, length: 0), block: block, in: source),
                       NSRange(location: 17, length: 0))
        XCTAssertEqual(FrontmatterFold.initialSelection(NSRange(location: 19, length: 0), block: block, in: source),
                       NSRange(location: 19, length: 0))
        XCTAssertEqual(FrontmatterFold.initialSelection(NSRange(location: 0, length: 0), block: nil, in: source),
                       NSRange(location: 0, length: 0))
    }

    /// Blank lines between the block and the first content line are
    /// skipped, so the caret starts on the H1, not above it.
    func testInitialCaretSkipsBlankLinesBehindTheBlock() {
        let spaced = "---\ntitle: T\n---\n\n  \n# T\n" as NSString
        XCTAssertEqual(FrontmatterFold.initialSelection(NSRange(location: 0, length: 0), block: block, in: spaced),
                       NSRange(location: 21, length: 0))
        let onlyBlank = "---\ntitle: T\n---\n\n\n" as NSString
        XCTAssertEqual(FrontmatterFold.initialSelection(NSRange(location: 0, length: 0), block: block, in: onlyBlank),
                       NSRange(location: 17, length: 0))
    }
}

@MainActor
final class FrontmatterFoldHighlightTests: XCTestCase {

    private func highlight(_ source: String, caret: Int) -> (NSTextStorage, SyntaxHighlighter) {
        let storage = NSTextStorage(string: source)
        let highlighter = SyntaxHighlighter()
        highlighter.highlight(textStorage: storage, isDark: false,
                              cursorRange: NSRange(location: caret, length: 0))
        return (storage, highlighter)
    }

    /// Without an H1 after the block, the meta line takes the block's
    /// first line.
    func testFoldedBlockIsConcealedWithOneReservedLine() {
        let src = "---\ntitle: T\ndate: 2026-10-03\n---\nBody\n"
        let block = NSRange(location: 0, length: 34)
        let (storage, highlighter) = highlight(src, caret: 36)
        XCTAssertEqual(highlighter.foldedFrontmatter, block)
        XCTAssertNil(highlighter.frontmatterMetaAnchor)
        for i in [0, 5, 20, 31] {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor,
                           .clear, "char \(i)")
        }
        let para = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let height = SyntaxHighlighter.metaLineHeight(for: highlighter.theme)
        XCTAssertGreaterThan(height, 0)
        XCTAssertEqual(para?.minimumLineHeight, height)
        XCTAssertEqual(para?.maximumLineHeight, height)
        // Only the first line carries the reservation.
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 5, effectiveRange: nil))
    }

    /// An H1 right after the block (blank lines aside) carries the meta
    /// line under it: the block reserves nothing, the H1 gets the room.
    func testMetaLineMovesUnderAFollowingH1() {
        let src = "---\ntitle: Trip\ndate: 2026-10-03\n---\n\n# Trip to Porto\n\nText\n"
        let (storage, highlighter) = highlight(src, caret: 60)
        XCTAssertEqual(highlighter.foldedFrontmatter, NSRange(location: 0, length: 37))
        let title = (src as NSString).range(of: "# Trip to Porto")
        XCTAssertEqual(highlighter.frontmatterMetaAnchor, title)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil), "no reserved line")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        let theme = highlighter.theme
        let para = storage.attribute(.paragraphStyle, at: title.location, effectiveRange: nil) as? NSParagraphStyle
        let room = SyntaxHighlighter.metaLineGap(for: theme) + SyntaxHighlighter.metaLineHeight(for: theme)
        XCTAssertEqual(para?.paragraphSpacing, (theme.headingRule ? 6 : 0) + room)
    }

    func testRoomUnderTheH1KeepsTheHairlineSpacing() {
        let src = "---\ntitle: Trip\n---\n# Trip\nText\n"
        let storage = NSTextStorage(string: src)
        let highlighter = SyntaxHighlighter()
        var theme = highlighter.theme
        theme.headingRule = true
        highlighter.theme = theme
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 30, length: 0))
        let para = storage.attribute(.paragraphStyle, at: 20, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.paragraphSpacing,
                       6 + SyntaxHighlighter.metaLineGap(for: theme) + SyntaxHighlighter.metaLineHeight(for: theme))
        XCTAssertEqual(para?.paragraphSpacingBefore, 4)
    }

    /// Opening the block, even with the H1 outside the working slice,
    /// takes the room under the H1 away again.
    func testRevealRemovesTheRoomUnderTheH1() {
        let src = "---\ntitle: Trip\n---\n# Trip\nText\n"
        let storage = NSTextStorage(string: src)
        let highlighter = SyntaxHighlighter()
        var theme = highlighter.theme
        theme.headingRule = false
        highlighter.theme = theme
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 30, length: 0))
        XCTAssertNotNil(storage.attribute(.paragraphStyle, at: 20, effectiveRange: nil))
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 5, length: 0),
                              viewportRange: NSRange(location: 0, length: 6))
        XCTAssertNil(highlighter.foldedFrontmatter)
        XCTAssertNil(highlighter.frontmatterMetaAnchor)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 20, effectiveRange: nil))
    }

    func testOnlyAnH1OnTheFirstContentLineTakesTheMetaLine() {
        func anchor(_ src: String) -> NSRange? {
            let block = Frontmatter.fenceRegex.firstMatch(
                in: src, range: NSRange(location: 0, length: (src as NSString).length))!.range
            return SyntaxHighlighter.h1DirectlyAfter(block, in: src as NSString)
        }
        XCTAssertEqual(anchor("---\na: 1\n---\n# T\n"), NSRange(location: 13, length: 3))
        XCTAssertEqual(anchor("---\na: 1\n---\n\n  \t\n# T\n"), NSRange(location: 18, length: 3))
        XCTAssertEqual(anchor("---\r\na: 1\r\n---\r\n\r\n# T\r\n"), NSRange(location: 18, length: 3))
        XCTAssertNil(anchor("---\na: 1\n---\n## T\n"))
        XCTAssertNil(anchor("---\na: 1\n---\nIntro\n# T\n"))
        XCTAssertNil(anchor("---\na: 1\n---\n#T\n"))
        XCTAssertNil(anchor("---\na: 1\n---\n"))
        XCTAssertNil(anchor("---\na: 1\n---\n\n\n"))
    }

    func testCaretInsideShowsTheRawYAML() {
        let src = "---\ntitle: T\n---\nBody"
        let (storage, highlighter) = highlight(src, caret: 6)
        XCTAssertNil(highlighter.foldedFrontmatter)
        let color = storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(color, .clear)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
    }

    /// Leaving and re-entering: a fold followed by a reveal must not leave
    /// the reserved line or the concealment behind.
    func testRevealAfterFoldClearsTheReservation() {
        let src = "---\ntitle: T\n---\nBody"
        let storage = NSTextStorage(string: src)
        let highlighter = SyntaxHighlighter()
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 18, length: 0))
        XCTAssertNotNil(highlighter.foldedFrontmatter)
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 2, length: 0),
                              viewportRange: NSRange(location: 17, length: 3))
        XCTAssertNil(highlighter.foldedFrontmatter)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil),
                     "repainted even outside the working slice")
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .clear)
    }

    func testCurrentSearchMatchInsideKeepsTheBlockOpen() {
        let src = "---\ntitle: Needle\n---\nBody"
        let storage = NSTextStorage(string: src)
        let highlighter = SyntaxHighlighter()
        highlighter.searchMatchToReveal = NSRange(location: 11, length: 6)
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 22, length: 0))
        XCTAssertNil(highlighter.foldedFrontmatter)
        XCTAssertEqual(highlighter.frontmatterBlock, NSRange(location: 0, length: 22))
        highlighter.searchMatchToReveal = NSRange(location: 22, length: 4)
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: NSRange(location: 22, length: 0))
        XCTAssertNotNil(highlighter.foldedFrontmatter)
    }

    func testCRLFBlockFolds() {
        let src = "---\r\ntitle: T\r\n---\r\nBody"
        let (_, highlighter) = highlight(src, caret: 20)
        XCTAssertEqual(highlighter.foldedFrontmatter, NSRange(location: 0, length: 20))
    }
}

/// The inspector → editor channel on a window-less `PicaMDTextView`
/// (pattern: `CheckboxToggleTests`). A delegate hands the text view an
/// undo manager, so undo is actually exercised.
@MainActor
final class EditorBridgeTests: XCTestCase {

    @MainActor
    private final class UndoProvider: NSObject, NSTextViewDelegate {
        let undoManager: UndoManager
        init(undoManager: UndoManager) {
            self.undoManager = undoManager
            super.init()
        }
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    /// Kept alive here: `NSTextView.delegate` is weak.
    private var undoProvider: UndoProvider?

    private func makeEditor(_ text: String) -> (MarkdownTextView.Coordinator, PicaMDTextView) {
        var binding = text
        let view = MarkdownTextView(text: Binding(get: { binding }, set: { binding = $0 }),
                                    jumpToken: .constant(nil))
        let coordinator = view.makeCoordinator()
        let textView = PicaMDTextView()
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = text
        let provider = UndoProvider(undoManager: UndoManager())
        undoProvider = provider
        textView.delegate = provider
        coordinator.textView = textView
        return (coordinator, textView)
    }

    func testApplyShiftsTheCaretAndUndoRestoresTheText() throws {
        let src = "---\ntitle: Old\n---\n# Heading\nBody"
        let (coordinator, textView) = makeEditor(src)
        let caret = (src as NSString).range(of: "Body").location
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        let edit = try XCTUnwrap(Frontmatter.edit(source: src, field: .title, newValue: "A longer title"))
        XCTAssertTrue(coordinator.apply(edit, actionName: "Edit Title"))
        XCTAssertEqual(textView.string, "---\ntitle: A longer title\n---\n# Heading\nBody")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: caret + edit.delta, length: 0),
                       "caret stays on the same character")

        let undo = try XCTUnwrap(undoProvider?.undoManager)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Edit Title")
        undo.undo()
        XCTAssertEqual(textView.string, src)
    }

    func testStaleEditIsRefused() {
        let src = "---\ntitle: Old\n---\n"
        let (coordinator, textView) = makeEditor(src)
        let stale = TextEdit(range: NSRange(location: 4, length: 11), replacement: "title: X\n",
                             expected: "title: Abc\n")
        XCTAssertFalse(coordinator.apply(stale, actionName: "Edit Title"))
        XCTAssertEqual(textView.string, src)
        let outOfBounds = TextEdit(range: NSRange(location: 40, length: 1), replacement: "", expected: "x")
        XCTAssertFalse(coordinator.apply(outOfBounds, actionName: "Edit Title"))
    }

    func testBridgeWritesAgainstTheLiveText() {
        let (coordinator, textView) = makeEditor("Body")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let bridge = EditorBridge()
        coordinator.attachBridge(bridge)
        XCTAssertTrue(bridge.setFrontmatter(.title, to: "Trip"))
        XCTAssertEqual(textView.string, "---\ntitle: Trip\n---\nBody")
        XCTAssertEqual(textView.selectedRange().location, 2 + 20)
        XCTAssertTrue(bridge.setTags(["a", "b"]))
        XCTAssertEqual(textView.string, "---\ntitle: Trip\ntags: [a, b]\n---\nBody")
        XCTAssertFalse(bridge.setTags(["a", "b"]), "no change, no undo step")
        XCTAssertEqual(undoProvider?.undoManager.undoActionName, "Edit Tags")
    }

    /// The inspector's tag list lags the text by the re-parse debounce. Two
    /// quick chip clicks must both land: the second is computed from the
    /// live text, not from the list the first click left on screen.
    func testQuickTagRemovalsAndAdditionsAllLand() {
        let (coordinator, textView) = makeEditor("---\ntags: [a, b, c]\n---\nBody")
        let bridge = EditorBridge()
        coordinator.attachBridge(bridge)
        // The shown list is [a, b, c] for both clicks.
        XCTAssertTrue(bridge.removeTag("a", at: 0))
        XCTAssertTrue(bridge.removeTag("c", at: 2))
        XCTAssertEqual(Frontmatter.build(from: textView.string).tags, ["b"],
                       "the first removal must not come back")

        XCTAssertTrue(bridge.addTags(["x"]))
        XCTAssertTrue(bridge.addTags(["y"]))
        XCTAssertEqual(Frontmatter.build(from: textView.string).tags, ["b", "x", "y"])
        XCTAssertFalse(bridge.removeTag("zzz", at: 0), "a tag that is gone already")
    }
}

@MainActor
final class ConcealedTypingAttributesTests: XCTestCase {

    func testTypingAfterConcealedTextUsesTheBodyStyle() {
        let theme = EditorTheme.default
        let hidden: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: EditorFont.concealedSize),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: NSParagraphStyle.default,
        ]
        let typed = MarkdownTextView.Coordinator.visibleTypingAttributes(hidden, theme: theme)
        XCTAssertEqual((typed[.font] as? NSFont)?.pointSize, theme.fontBaseSize)
        XCTAssertEqual(typed[.foregroundColor] as? NSColor, theme.palette.fg)
        XCTAssertNil(typed[.paragraphStyle])
    }

    func testVisibleAttributesPassThrough() {
        let bold = NSFont.boldSystemFont(ofSize: 20)
        let attrs: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: NSColor.red]
        let typed = MarkdownTextView.Coordinator.visibleTypingAttributes(attrs, theme: .default)
        XCTAssertEqual(typed[.font] as? NSFont, bold)
        XCTAssertEqual(typed[.foregroundColor] as? NSColor, .red)
    }
}

/// What a document shows right after it opens, in a real document window.
@MainActor
final class DocumentOpenCaretTests: XCTestCase {

    private func open(_ text: String) throws -> HostedDocument {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDOpenCaret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Trip.md")
        try Data(text.utf8).write(to: url)
        return try HostedDocument.open(url, in: self)
    }

    /// The caret starts behind the front matter, on the H1, and the
    /// outline marks that H1, not the last heading.
    func testCaretStartsBehindTheFrontMatter() throws {
        let text = "---\ntitle: Trip\ntags: [a, b]\n---\n# Trip to Porto\n\nText.\n\n## Day one\n\n## Notes\n\nEnd.\n"
        let doc = try open(text)
        defer { doc.close() }
        XCTAssertEqual(doc.textView.selectedRange(), NSRange(location: 33, length: 0))
        let headings = HeadingExtractor.extract(from: text)
        XCTAssertEqual(ContentView.activeHeadingID(in: headings, cursor: doc.textView.selectedRange().location),
                       headings.first?.id)
    }

    /// The usual layout, a blank line between the front matter and the
    /// H1: the caret still starts on the H1 and the outline marks it.
    func testCaretStartsOnTheH1BehindABlankLine() throws {
        let text = "---\ntitle: Trip\ntags: [a, b]\n---\n\n# Trip to Porto\n\nText.\n\n## Notes\n"
        let doc = try open(text)
        defer { doc.close() }
        XCTAssertEqual(doc.textView.selectedRange(), NSRange(location: 34, length: 0))
        let headings = HeadingExtractor.extract(from: text)
        XCTAssertEqual(ContentView.activeHeadingID(in: headings, cursor: doc.textView.selectedRange().location),
                       headings.first?.id)
    }

    func testCaretStartsAtTheTopWithoutFrontMatter() throws {
        let doc = try open("# Trip\n\nText.\n\n## Notes\n")
        defer { doc.close() }
        XCTAssertEqual(doc.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testActiveHeadingIsTheLastOneAtOrAboveTheCaret() {
        let headings = HeadingExtractor.extract(from: "Intro\n# A\ntext\n## B\n")
        XCTAssertNil(ContentView.activeHeadingID(in: headings, cursor: 2))
        XCTAssertEqual(ContentView.activeHeadingID(in: headings, cursor: 6), headings[0].id)
        XCTAssertEqual(ContentView.activeHeadingID(in: headings, cursor: 12), headings[0].id)
        XCTAssertEqual(ContentView.activeHeadingID(in: headings, cursor: 15), headings[1].id)
        XCTAssertNil(ContentView.activeHeadingID(in: [], cursor: 15))
    }
}

/// The meta line under the H1 in a real document window: where it is
/// drawn, that a jump to the H1 keeps it below the toolbar, and that a
/// click on it opens the YAML.
@MainActor
final class MetaLineUnderTitleTests: XCTestCase {

    private let text = "---\ntitle: Trip\ndate: 2026-10-03\ntags: [travel]\n---\n\n# Trip to Porto\n\n"
        + String(repeating: "A line of text that fills the page.\n\n", count: 60)

    private func open() throws -> HostedDocument {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDMetaLine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Trip.md")
        try Data(text.utf8).write(to: url)
        let doc = try HostedDocument.open(url, in: self)
        HostedDocument.spin(until: { doc.textView.frontmatterMetaLine != nil })
        return doc
    }

    private var title: NSRange { (text as NSString).range(of: "# Trip to Porto") }

    func testMetaLineIsDrawnUnderTheH1() throws {
        let doc = try open()
        defer { doc.close() }
        let tv = doc.textView
        let meta = try XCTUnwrap(tv.frontmatterMetaLine)
        XCTAssertEqual(meta.anchor, title)
        let rect = try XCTUnwrap(tv.frontmatterMetaLineRect())
        let lm = try XCTUnwrap(tv.layoutManager)
        let origin = tv.textContainerOrigin
        let lastTitleGlyph = lm.glyphIndexForCharacter(at: NSMaxRange(title) - 1)
        let titleUsed = lm.lineFragmentUsedRect(forGlyphAt: lastTitleGlyph, effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
        let nextLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: NSMaxRange(title) + 1),
                                           effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
        XCTAssertGreaterThanOrEqual(rect.minY, titleUsed.maxY, "below the title's text")
        XCTAssertLessThanOrEqual(rect.maxY, nextLine.minY, "above the next line")
        // The block itself takes no room: the H1 is the first visible line.
        let firstLine = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertLessThan(firstLine.height, 1)
    }

    /// The outline jump puts the H1's top 24 pt under the toolbar
    /// (`EditorScrollMath.jumpOrigin`); the meta line is under the H1, so
    /// it lands inside the visible area too.
    func testJumpToTheH1KeepsTheMetaLineBelowTheToolbar() throws {
        let doc = try open()
        defer { doc.close() }
        let tv = doc.textView
        let lm = try XCTUnwrap(tv.layoutManager)
        let container = try XCTUnwrap(tv.textContainer)
        let clip = try XCTUnwrap(tv.enclosingScrollView?.contentView)
        let titleLocation = title.location + 2
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: titleLocation, length: 1),
                                   actualCharacterRange: nil)
        let lineTop = lm.boundingRect(forGlyphRange: glyphs, in: container).minY + tv.textContainerInset.height
        let insets = clip.contentInsets
        let y = EditorScrollMath.jumpOrigin(lineTop: lineTop, documentHeight: tv.frame.height,
                                            viewportHeight: clip.bounds.height,
                                            insetTop: insets.top, insetBottom: insets.bottom)
        let rect = try XCTUnwrap(tv.frontmatterMetaLineRect())
        XCTAssertGreaterThanOrEqual(rect.minY, y + insets.top, "not under the toolbar")
        XCTAssertLessThanOrEqual(rect.maxY, y + clip.bounds.height - insets.bottom)
    }

    func testClickOnTheMetaLineOpensTheYAML() throws {
        let doc = try open()
        defer { doc.close() }
        let tv = doc.textView
        let window = try XCTUnwrap(tv.window)
        let rect = try XCTUnwrap(tv.frontmatterMetaLineRect())
        let point = tv.convert(NSPoint(x: rect.minX + 20, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // NSTextView's own click tracking waits for the mouse-up.
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        tv.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(HostedDocument.spin(until: { tv.frontmatterMetaLine == nil }), "the YAML opens")
    }
}
