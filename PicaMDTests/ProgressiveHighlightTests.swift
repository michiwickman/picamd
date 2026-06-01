import XCTest
import AppKit
@testable import PicaMD

/// The progressive theme re-highlight (F8) sweeps the document in
/// newline-aligned chunks. This must converge to the SAME attribute
/// state as a single full-document pass — otherwise a theme switch on a
/// large doc would leave subtly mis-styled regions at chunk seams.
@MainActor
final class ProgressiveHighlightTests: XCTestCase {

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 15)],
                              range: NSRange(location: 0, length: storage.length))
        return storage
    }

    /// A doc exercising headings, inline markup, a fenced code block, a
    /// math block and task-list checkboxes across many lines so chunk
    /// seams land in varied places.
    private var sampleDoc: String {
        var lines: [String] = []
        for i in 0..<60 {
            lines.append("# Heading \(i)")
            lines.append("Body **bold \(i)** and *italic* and `code\(i)` text.")
            lines.append("- [ ] task \(i) open")
            lines.append("- [x] task \(i) done with **bold** tail")
            lines.append("")
            if i % 7 == 0 {
                lines.append("```swift")
                lines.append("let x\(i) = \(i)  // fenced code")
                lines.append("```")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testChunkedHighlightConvergesToFullHighlight() {
        let source = sampleDoc
        let len = (source as NSString).length
        let cursorFarAway = NSRange(location: len, length: 0)

        // Full single-pass reference.
        let full = makeStorage(source)
        SyntaxHighlighter().highlight(textStorage: full, isDark: false,
                                      cursorRange: cursorFarAway)

        // Chunked pass mirroring Coordinator.applyThemeChangeProgressively:
        // small chunks, end snapped to the next newline.
        let chunked = makeStorage(source)
        let hl = SyntaxHighlighter()
        let ns = source as NSString
        var loc = 0
        let chunkSize = 200   // deliberately tiny to force many seams
        while loc < len {
            var end = min(loc + chunkSize, len)
            if end < len {
                let nl = ns.range(of: "\n", options: [],
                                  range: NSRange(location: end, length: len - end))
                end = (nl.location != NSNotFound) ? nl.location + 1 : len
            }
            hl.highlight(textStorage: chunked, isDark: false,
                         cursorRange: cursorFarAway,
                         viewportRange: NSRange(location: loc, length: end - loc))
            loc = end
        }

        // Compare foreground colour + font at every character.
        var mismatches = 0
        var firstMismatch = -1
        for i in 0..<len {
            let cFull = full.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            let cChunk = chunked.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            let fFull = full.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            let fChunk = chunked.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            if cFull != cChunk || fFull != fChunk {
                mismatches += 1
                if firstMismatch < 0 { firstMismatch = i }
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "chunked highlight diverged from full pass at \(mismatches) chars (first at \(firstMismatch))")
    }

    func testSingleChunkEqualsFullDoc() {
        // Degenerate case: one chunk covering the whole doc must equal a
        // nil-viewport full pass.
        let source = "# Title\n\nBody **x** and `y`.\n- [x] done\n"
        let len = (source as NSString).length
        let cursor = NSRange(location: len, length: 0)

        let a = makeStorage(source)
        SyntaxHighlighter().highlight(textStorage: a, isDark: false, cursorRange: cursor)

        let b = makeStorage(source)
        SyntaxHighlighter().highlight(textStorage: b, isDark: false, cursorRange: cursor,
                                      viewportRange: NSRange(location: 0, length: len))

        for i in 0..<len {
            let ca = a.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            let cb = b.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            XCTAssertEqual(ca, cb, "mismatch at \(i)")
        }
    }
}
