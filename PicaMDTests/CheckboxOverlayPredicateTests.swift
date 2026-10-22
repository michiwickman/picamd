import XCTest
import AppKit
@testable import PicaMD

/// Checkbox overlays: the highlighter decides with `touchesBlock`
/// whether the caret is editing a task line (and reveals `[ ]`), the
/// overlay manager decided with a private `intersects` whether to hide the
/// drawn checkbox. The two differ by the highlighter's one-character lead:
/// with the caret at the end of the line above, the source `[ ]` was shown
/// in the accent colour and the overlay checkbox stayed drawn on top of it.
/// For every caret position the overlay must be hidden exactly when the
/// highlighter reveals the source.
@MainActor
final class CheckboxOverlayPredicateTests: XCTestCase {

    private let source = "Intro line\n- [ ] Task\nAfter\n"

    /// Highlighter's answer: is the box source visible (not `.clear`)?
    private func highlighterReveals(caret: Int) -> Bool {
        let storage = NSTextStorage(string: source,
                                    attributes: [.font: NSFont.systemFont(ofSize: 15)])
        SyntaxHighlighter().highlight(textStorage: storage, isDark: false,
                                      cursorRange: NSRange(location: caret, length: 0))
        let box = CheckboxOverlayManager.extractMatches(from: source)[0].boxRange
        let color = storage.attribute(.foregroundColor, at: box.location, effectiveRange: nil) as? NSColor
        return (color?.alphaComponent ?? 1) > 0
    }

    /// Overlay manager's answer: is the drawn checkbox hidden?
    private func overlayHidden(caret: Int) -> Bool {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = source
        let manager = CheckboxOverlayManager()
        manager.textView = tv
        manager.update(matches: CheckboxOverlayManager.extractMatches(from: source),
                       cursorActiveRanges: [NSRange(location: caret, length: 0)])
        let views = tv.subviews.compactMap { $0 as? CheckboxView }
        XCTAssertEqual(views.count, 1)
        return views.first?.isHidden ?? false
    }

    func testOverlayHidesExactlyWhenTheHighlighterRevealsTheSource() {
        let line = CheckboxOverlayManager.extractMatches(from: source)[0].lineRange
        let carets = [
            0,                              // far above
            line.location - 1,              // end of the line above
            line.location,                  // start of the task line
            line.location + 3,              // inside the box
            NSMaxRange(line),               // end of the task line
            NSMaxRange(line) + 1,           // start of the line below
            (source as NSString).length,    // end of the document
        ]
        for caret in carets {
            XCTAssertEqual(overlayHidden(caret: caret), highlighterReveals(caret: caret),
                           "caret \(caret): overlay and highlighter disagree")
        }
    }

    func testCaretOnTheTaskLineRevealsAndCaretBelowDoesNot() {
        let line = CheckboxOverlayManager.extractMatches(from: source)[0].lineRange
        XCTAssertTrue(overlayHidden(caret: line.location))
        XCTAssertTrue(overlayHidden(caret: NSMaxRange(line)))
        XCTAssertFalse(overlayHidden(caret: NSMaxRange(line) + 1))
        XCTAssertFalse(overlayHidden(caret: 0))
    }
    /// VoiceOver names each checkbox after its task, so a list of them can
    /// be told apart; retyping a task of the same length renames it.
    func testCheckboxesAreNamedAfterTheirTask() {
        let doc = "- [ ] Buy milk\n- [x] Call Anna\n"
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = doc
        let manager = CheckboxOverlayManager()
        manager.textView = tv
        manager.update(matches: CheckboxOverlayManager.extractMatches(from: doc), cursorActiveRanges: [])
        var views = tv.subviews.compactMap { $0 as? CheckboxView }
        XCTAssertEqual(views.map { $0.accessibilityLabel() }, ["Buy milk", "Call Anna"])

        let retyped = "- [ ] Buy silk\n- [x] Call Anna\n"
        tv.string = retyped
        manager.update(matches: CheckboxOverlayManager.extractMatches(from: retyped), cursorActiveRanges: [])
        views = tv.subviews.compactMap { $0 as? CheckboxView }
        XCTAssertEqual(views.first?.accessibilityLabel(), "Buy silk")
        XCTAssertEqual(CheckboxView.accessibilityLabel(for: "  "), "Task")
    }

    /// The tick on the accent fill reaches 3:1 (a graphic) on every accent.
    func testTickStandsOutOnEveryAccent() {
        var accents = AccentChoice.allCases.filter { $0 != .system }.map(\.color)
        accents += PaletteName.allCases.map { $0.palette.accent }
        for accent in accents {
            let tick = CheckboxView.tickColor(on: accent)
            XCTAssertGreaterThanOrEqual(Palette.contrast(tick, accent), 3, accent.toHex())
        }
    }
}
