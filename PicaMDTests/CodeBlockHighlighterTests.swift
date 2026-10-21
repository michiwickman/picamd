import XCTest
import AppKit
@testable import PicaMD

/// Comments and strings in fenced code: which one a span belongs to is
/// decided by where each token starts, not by the order of the rules.
@MainActor
final class CodeBlockHighlighterTests: XCTestCase {

    /// Highlights the one fenced block in `doc` and returns the storage.
    private func highlighted(_ doc: String) -> NSTextStorage {
        let storage = NSTextStorage(string: doc)
        let ns = doc as NSString
        CodeBlockHighlighter.highlight(textStorage: storage, source: doc,
                                       codeBlocks: [NSRange(location: 0, length: ns.length)],
                                       isDark: false, viewportRange: nil)
        return storage
    }

    private func color(of needle: String, offset: Int = 0, in storage: NSTextStorage) -> NSColor? {
        let r = (storage.string as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "\(needle) not in the document")
        return storage.attribute(.foregroundColor, at: r.location + offset, effectiveRange: nil) as? NSColor
    }

    func testURLInsideASwiftStringStaysAString() {
        let doc = "```swift\nlet url = \"https://example.com\" // done\n```\n"
        let storage = highlighted(doc)
        let string = color(of: "\"https", in: storage)
        XCTAssertNotNil(string)
        XCTAssertEqual(color(of: "https", in: storage), string)
        XCTAssertEqual(color(of: "example", in: storage), string,
                       "the // inside the string must not start a comment")
        XCTAssertNotEqual(color(of: "// done", in: storage), string,
                          "the real comment after the string is still a comment")
    }

    func testApostropheInAPythonCommentDoesNotOpenAString() {
        let doc = "```python\n# it's Bob's\nx = 'a'\n```\n"
        let storage = highlighted(doc)
        let comment = color(of: "# it", in: storage)
        XCTAssertNotNil(comment)
        XCTAssertEqual(color(of: "s Bob", in: storage), comment,
                       "the whole line is a comment")
        XCTAssertEqual(color(of: "Bob's", offset: 4, in: storage), comment)
        let string = color(of: "'a'", in: storage)
        XCTAssertNotNil(string)
        XCTAssertNotEqual(string, comment, "the string on the next line is a string")
    }

    func testHashInsideAPythonStringIsNotAComment() {
        let doc = "```python\ns = \"a # b\"\n```\n"
        let storage = highlighted(doc)
        XCTAssertEqual(color(of: "# b", in: storage), color(of: "\"a", in: storage))
    }
}
