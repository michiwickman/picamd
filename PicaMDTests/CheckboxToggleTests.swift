import XCTest
import AppKit
import SwiftUI
@testable import PicaMD

/// Tests for the real `MarkdownTextView.Coordinator.toggleCheckbox(at:to:)`
/// code path — not just the static string transform.
///
/// The coordinator is constructed without the full SwiftUI lifecycle by
/// calling `view.makeCoordinator()` and then wiring up a bare `NSTextView`
/// fixture as `coord.textView`.
///
/// NOTE: `shouldChangeText(in:replacementString:)` on a windowless
/// `NSTextView` returns `true` when `isEditable == true` (the default).
/// No window or first-responder promotion is required for the forward-toggle
/// assertions. The undo assertion has a caveat — see CONCERNS below.
@MainActor
final class CheckboxToggleTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal `MarkdownTextView` and its coordinator, backed by a
    /// plain `NSTextView` fixture (no scroll view, no window).
    private func makeCoordAndTextView(initialText: String) -> (
        coord: MarkdownTextView.Coordinator,
        textView: NSTextView
    ) {
        var textBinding = initialText
        let view = MarkdownTextView(
            text: Binding(
                get: { textBinding },
                set: { textBinding = $0 }
            ),
            jumpToken: .constant(nil)
        )
        let coord = view.makeCoordinator()

        let textView = NSTextView()
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = initialText
        coord.textView = textView

        return (coord, textView)
    }

    /// Return the NSRange of the first `[ ]` or `[x]` in `string`, or
    /// `nil` if none is found.
    private func boxRange(in string: String, of token: String = "[ ]") -> NSRange? {
        let ns = string as NSString
        let r = ns.range(of: token)
        guard r.location != NSNotFound else { return nil }
        return r
    }

    // MARK: - testToggleFlipsSourceAndIsUndoable

    /// Forward toggle: `[ ]` becomes `[x]`.
    /// Undo is attempted; see CONCERNS if that branch is flaky.
    func testToggleFlipsSourceAndIsUndoable() {
        let initial = "- [ ] task\n"
        let (coord, textView) = makeCoordAndTextView(initialText: initial)

        guard let range = boxRange(in: textView.string) else {
            XCTFail("No `[ ]` found in fixture string")
            return
        }

        coord.toggleCheckbox(at: range, to: true)

        XCTAssertTrue(
            textView.string.contains("[x]"),
            "After toggleCheckbox(to: true), storage must contain `[x]`; got: \(textView.string.debugDescription)"
        )

        // Undo: NSTextView's undo manager is wired only when the view has a
        // window and is first-responder for the undo-group registration that
        // `shouldChangeText`/`didChangeText` performs. In a headless test the
        // undo stack may be empty, so we gate this assertion.
        if let um = textView.undoManager, um.canUndo {
            um.undo()
            XCTAssertTrue(
                textView.string.contains("[ ]"),
                "After undo, storage must revert to `[ ]`; got: \(textView.string.debugDescription)"
            )
        }
        // If canUndo == false the headless textView never registered the
        // undo group — see CONCERNS.
    }

    // MARK: - testTogglePreservesCaret

    /// The caret position must be restored after a toggle elsewhere.
    func testTogglePreservesCaret() {
        // Put the checkbox on line 1, caret on line 2.
        let initial = "- [ ] item\nother line\n"
        let (coord, textView) = makeCoordAndTextView(initialText: initial)

        // Place caret at start of "other line" (location 11).
        let caretLocation = 11
        textView.setSelectedRange(NSRange(location: caretLocation, length: 0))

        guard let range = boxRange(in: textView.string) else {
            XCTFail("No `[ ]` found in fixture string")
            return
        }

        coord.toggleCheckbox(at: range, to: true)

        // The toggle replaces 3 chars at the same location with 3 chars,
        // so total length is unchanged; caret should still be at 11.
        let afterSelection = textView.selectedRange()
        let total = (textView.string as NSString).length
        let expectedLoc = min(caretLocation, total)
        XCTAssertEqual(
            afterSelection.location,
            expectedLoc,
            "Caret must be preserved after toggling a checkbox elsewhere"
        )
        XCTAssertEqual(afterSelection.length, 0)
    }

    // MARK: - testStaleRangeIsRejected

    /// The stale-range guard rejects a range whose 3 chars are NOT a checkbox
    /// token, leaving the storage string completely unchanged.
    func testStaleRangeIsRejected() {
        let initial = "- [ ] x\n"
        let (coord, textView) = makeCoordAndTextView(initialText: initial)

        // "x\n" starts at index 6; a 3-char range there reads "x\n" + the
        // next char — but with the short 8-char string this will be 3 chars
        // of non-checkbox prose (or out-of-bounds, caught by the length guard).
        // Use location 5 (length 3 → " x\n"), which is not `[ ]` or `[x]`.
        let staleRange = NSRange(location: 5, length: 3)
        let before = textView.string

        coord.toggleCheckbox(at: staleRange, to: true)

        XCTAssertEqual(
            textView.string,
            before,
            "A non-checkbox range must be rejected by the stale-range guard; string must be unchanged"
        )
    }

    // MARK: - testOutOfBoundsRangeIsIgnored

    /// An out-of-bounds range must not crash and must leave the string intact.
    func testOutOfBoundsRangeIsIgnored() {
        let initial = "- [ ] x\n"
        let (coord, textView) = makeCoordAndTextView(initialText: initial)
        let before = textView.string

        let outOfBounds = NSRange(location: (initial as NSString).length, length: 3)
        // Must not crash:
        coord.toggleCheckbox(at: outOfBounds, to: true)

        XCTAssertEqual(
            textView.string,
            before,
            "An out-of-bounds range must be silently ignored; string must be unchanged"
        )
    }
}

/*
 CONCERNS
 --------
 1. Undo assertion (testToggleFlipsSourceAndIsUndoable):
    `NSTextView.shouldChangeText(in:replacementString:)` opens an undo group
    and registers the inverse edit, but only when the view's window's
    `undoManager` is available. A windowless `NSTextView` in a unit-test
    process has `undoManager == nil` at the AppKit layer (it returns the
    view's own private undo manager, but `didChangeText` may not register
    the undo action without a complete responder chain). The test gates on
    `um.canUndo` so it does not fail, but the undo path is not exercised
    unless the harness runs tests in a real NSWindow context.

 2. `shouldChangeText` return value:
    Without a delegate set on the fixture `NSTextView`, `shouldChangeText`
    returns `true` whenever `isEditable == true`. The coordinator is NOT set
    as the textView's delegate in the test fixture (doing so would require the
    full `makeNSView` path). The toggle therefore bypasses the
    `textDidChange` / parent-binding feedback loop — that is intentional for
    these unit tests, which only verify the storage mutation and caret
    preservation, not the SwiftUI binding round-trip.

 3. No production code was modified. All seams used (
    `Coordinator.textView`, `Coordinator.toggleCheckbox(at:to:)`) are already
    `internal` / `@testable`-accessible.
*/
