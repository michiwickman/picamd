import XCTest
import AppKit
@testable import PicaMD

/// Settings ▸ Line width: the text column is centred by widening the
/// text container's side inset.
@MainActor
final class ReadableColumnTests: XCTestCase {

    func testHorizontalInsetValueTable() {
        // (text view width, column width) -> inset, with 5 pt line
        // fragment padding and the 24 pt minimum.
        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (1100, 640, 225),          // (1100 − 640) / 2 − 5
            (1101, 640, 225),          // rounded down, never a half point
            (700, 640, 25),            // just wider than the column
            (690, 640, 24),            // would be 20: the minimum wins
            (400, 640, 24),            // narrower than the column
            (2560, .infinity, 24),     // Full
            (0, 640, 24),              // not laid out yet
        ]
        for (width, column, expected) in rows {
            XCTAssertEqual(EditorLayout.horizontalInset(containerWidth: width, columnWidth: column,
                                                        lineFragmentPadding: 5),
                           expected, "width \(width), column \(column)")
        }
        XCTAssertEqual(EditorLayout.horizontalInset(containerWidth: 1000, columnWidth: 600,
                                                    minInset: 40, lineFragmentPadding: 0), 200)
    }

    func testColumnWidthIsMeasuredInCharactersOfTheBodyFont() {
        let mono = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let zero = ("0" as NSString).size(withAttributes: [.font: mono]).width
        XCTAssertEqual(LineWidth.readable.columnWidth(for: mono), (66 * zero).rounded())
        XCTAssertEqual(LineWidth.wide.columnWidth(for: mono), (100 * zero).rounded())
        XCTAssertEqual(LineWidth.full.columnWidth(for: mono), .infinity)
        // A narrower font gives a narrower column: same line length.
        let small = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertLessThan(LineWidth.readable.columnWidth(for: small), LineWidth.readable.columnWidth(for: mono))
    }

    /// The text view applies the inset on resize and on a column change,
    /// and the container — which every overlay reads its width from —
    /// follows.
    func testTextViewCentresTheColumnAndTheContainerFollows() throws {
        let (scrollView, textView) = PicaMDTextView.makeScrollable()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        textView.textContainerInset = NSSize(width: EditorLayout.textContainerInsetWidth, height: 20)
        textView.string = String(repeating: "word ", count: 400)
        textView.setFrameSize(NSSize(width: 1100, height: 600))
        let container = try XCTUnwrap(textView.textContainer)
        let padding = container.lineFragmentPadding

        XCTAssertEqual(textView.textContainerInset.width, 24, "Full: today's margin")

        textView.readableColumnWidth = 640
        let inset = EditorLayout.horizontalInset(containerWidth: 1100, columnWidth: 640,
                                                 lineFragmentPadding: padding)
        XCTAssertEqual(textView.textContainerInset.width, inset)
        XCTAssertEqual(textView.textContainerInset.height, 20, "vertical inset untouched")
        XCTAssertEqual(container.size.width - 2 * padding, 1100 - 2 * inset - 2 * padding, accuracy: 0.5)
        XCTAssertEqual(container.size.width - 2 * padding, 640, accuracy: 1.5,
                       "the text itself is the column wide")

        textView.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertEqual(textView.textContainerInset.width,
                       EditorLayout.horizontalInset(containerWidth: 800, columnWidth: 640,
                                                    lineFragmentPadding: padding))
        XCTAssertEqual(container.size.width, 800 - 2 * textView.textContainerInset.width, accuracy: 0.5)

        textView.readableColumnWidth = .infinity
        XCTAssertEqual(textView.textContainerInset.width, 24)
        XCTAssertEqual(container.size.width, 800 - 48, accuracy: 0.5)
    }

    /// Tables, images and math are sized from the container, so they
    /// narrow to the column with no code of their own.
    func testBlockOverlaysFollowTheColumn() throws {
        let (_, textView) = PicaMDTextView.makeScrollable()
        textView.setFrameSize(NSSize(width: 1100, height: 600))
        let manager = BlockOverlayManager()
        manager.textView = textView
        let fullWidth = try XCTUnwrap(manager.resolvedContentWidth())
        textView.readableColumnWidth = 640
        let columnWidth = try XCTUnwrap(manager.resolvedContentWidth())
        XCTAssertLessThan(columnWidth, fullWidth)
        XCTAssertEqual(columnWidth, 640 - EditorLayout.blockOverlayHorizontalInset, accuracy: 1.5)
    }

    func testSubPointChangesAreIgnored() {
        let (_, textView) = PicaMDTextView.makeScrollable()
        textView.setFrameSize(NSSize(width: 1000, height: 400))
        textView.readableColumnWidth = 600
        let before = textView.textContainerInset.width
        XCTAssertFalse(textView.updateReadableInset(), "nothing to do")
        textView.setFrameSize(NSSize(width: 1000.6, height: 400))
        XCTAssertEqual(textView.textContainerInset.width, before)
    }
}
