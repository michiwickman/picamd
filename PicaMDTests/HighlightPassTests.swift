import XCTest
import AppKit
import SwiftUI
@testable import PicaMD

/// Drives `MarkdownTextView.Coordinator.applyHighlightingNow()` against a
/// real `PicaMDTextView` without the SwiftUI lifecycle, the same way
/// `CheckboxToggleTests` drives `toggleCheckbox`.
@MainActor
final class HighlightPassTests: XCTestCase {

    private func makeCoordinator(text: String) -> (MarkdownTextView.Coordinator, NSScrollView, PicaMDTextView) {
        var textBinding = text
        let view = MarkdownTextView(
            text: Binding(get: { textBinding }, set: { textBinding = $0 }),
            jumpToken: .constant(nil)
        )
        let coord = view.makeCoordinator()
        // `makeScrollable` builds the view exactly as `makeNSView` does,
        // including the 0 pt wide container of the very first pass.
        let (scrollView, textView) = PicaMDTextView.makeScrollable()
        textView.string = text
        coord.textView = textView
        let manager = BlockOverlayManager()
        manager.textView = textView
        coord.blockManager = manager
        return (coord, scrollView, textView)
    }

    // MARK: - Footnote index on a freshly opened document

    func testFirstPassBuildsTheFootnoteIndexEvenBeforeLayout() {
        let doc = "Ein Satz mit Fußnote.[^1]\n\n[^1]: Die Erklärung.\n"
        let (coord, scrollView, textView) = makeCoordinator(text: doc)
        XCTAssertNil(coord.blockManager?.resolvedContentWidth(),
                     "precondition: the first pass runs before the container has a width")

        coord.applyHighlightingNow()

        // The pre-layout return used to come before the index update. Only
        // that first pass sees the text as changed, so the index stayed
        // empty until the user edited the document.
        let index = textView.footnoteTooltip.index
        XCTAssertTrue(index.refs.contains { $0.id == "1" },
                      "hovering a footnote must work without editing the document first")
        XCTAssertEqual(index.definitions["1"], "Die Erklärung.")
        withExtendedLifetime(scrollView) {}
    }

    // MARK: - Reflow classification only while reflow is on

    private let hardWrapped = "Erste Zeile eines Absatzes\nzweite Zeile davon\ndritte Zeile.\n\nSchluss.\n"

    func testClassifierDoesNotRunWhileReflowIsOff() {
        let (coord, scrollView, _) = makeCoordinator(text: hardWrapped)
        coord.reflowDelegate = ReflowLayoutDelegate()
        coord.reflowMode = false

        coord.applyHighlightingNow()

        XCTAssertTrue(coord.scanCacheSoftNewlines.isEmpty,
                      "with reflow off nothing reads the classification, so it must not be computed")
        XCTAssertTrue(coord.reflowDelegate?.softNewlines.isEmpty ?? false)
        withExtendedLifetime(scrollView) {}
    }

    func testSwitchingReflowOnClassifiesTheUnchangedText() {
        let (coord, scrollView, _) = makeCoordinator(text: hardWrapped)
        let delegate = ReflowLayoutDelegate()
        coord.reflowDelegate = delegate
        coord.applyHighlightingNow()          // reflow off: text scanned, not classified

        coord.reflowMode = true                // the toggle path in updateNSView
        coord.applyHighlightingNow()

        XCTAssertEqual(delegate.softNewlines.count, 2,
                       "turning reflow on must classify even though the text did not change")
        XCTAssertTrue(delegate.isEnabled)
        withExtendedLifetime(scrollView) {}
    }

    func testEditWhileReflowIsOnReclassifies() {
        let (coord, scrollView, textView) = makeCoordinator(text: hardWrapped)
        let delegate = ReflowLayoutDelegate()
        coord.reflowDelegate = delegate
        coord.reflowMode = true
        coord.applyHighlightingNow()
        XCTAssertEqual(delegate.softNewlines.count, 2)

        // Turning the second line into a heading makes both of its
        // newlines structural.
        textView.string = "Erste Zeile eines Absatzes\n# zweite Zeile davon\ndritte Zeile.\n\nSchluss.\n"
        coord.applyHighlightingNow()

        XCTAssertTrue(delegate.softNewlines.isEmpty,
                      "an edit must invalidate the cached classification")
        withExtendedLifetime(scrollView) {}
    }
    // MARK: - Reflow invalidation stays local

    /// A changed classification inside Reflow Mode must relayout only the
    /// lines around the newlines that flipped, not the whole document.
    func testFlippedSoftNewlineInvalidatesOnlyItsLines() {
        let lines = (1...200).map { "Zeile \($0) eines langen Absatzes" }
        let text = lines.joined(separator: "\n") as NSString
        // The newline after line 150 flips from soft to structural.
        let line150 = text.range(of: "Zeile 150 ")
        let newline = NSMaxRange(text.lineRange(for: NSRange(location: line150.location, length: 0))) - 1
        XCTAssertEqual(text.character(at: newline), 0x0A)
        let old: Set<Int> = [newline, 10]
        let new: Set<Int> = [10]

        let range = MarkdownTextView.Coordinator.reflowInvalidationRange(old: old, new: new, in: text)
        let r = range
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.location, line150.location, "starts at the line the newline ends")
        let line151 = text.range(of: "Zeile 151 ")
        let line152 = text.range(of: "Zeile 152 ")
        XCTAssertEqual(r.map(NSMaxRange), line152.location, "ends with the line it joined")
        XCTAssertGreaterThan(line151.location, r?.location ?? .max)
        XCTAssertNil(MarkdownTextView.Coordinator.reflowInvalidationRange(old: new, new: new, in: text))
    }
}
