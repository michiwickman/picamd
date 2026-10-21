import Foundation

/// Document counts for the word count in the corner and the inspector's
/// Statistics section, computed in one go off the main actor (see
/// `ContentView.recomputeDerivedState`).
///
/// `words` counts what a reader sees, not the source: Markdown markers,
/// front matter, fenced code, math blocks and task-list boxes are left
/// out, so "**Trip** to Porto" is three words and a `---` rule none.
/// List numbers ("1.") and footnote labels ("[^1]") are not words either.
/// `characters` and `lines` describe the file as stored.
struct TextStats: Equatable, Sendable {
    var words = 0
    var characters = 0
    var lines = 0

    init() {}

    init(_ text: String) {
        self = Self.compute(text, isCancelled: { false })!
    }

    /// The counts, or nil once `isCancelled` reports true. It is checked
    /// between the full-document passes, so a pass that a newer edit has
    /// superseded stops early instead of running to the end.
    static func compute(_ text: String, isCancelled: () -> Bool) -> TextStats? {
        var stats = TextStats()
        stats.characters = text.count
        guard !text.isEmpty else { return stats }
        var newlines = 0
        for unit in text.utf16 where unit == 0x0A { newlines += 1 }
        stats.lines = newlines + 1
        guard let words = visibleWordCount(in: text, isCancelled: isCancelled) else { return nil }
        stats.words = words
        return stats
    }

    /// `- [ ] ` / `1. [x] ` boxes: rendered as checkboxes, so "[x]" is
    /// not a word.
    private static let taskMarker = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[[ xX]\](?=[ \t]|$)"#,
        options: [.anchorsMatchLines]
    )

    /// `1. ` / `2) ` ordered-list numbers (also inside quotes): drawn as
    /// list numbering, but "1." holds a digit and would count as a word.
    /// CommonMark allows at most nine digits.
    private static let orderedListMarker = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*\d{1,9}[.)](?=[ \t]|$)"#,
        options: [.anchorsMatchLines]
    )

    /// Footnote references `[^1]` and definition labels `[^1]:`: markup
    /// around a label, not words of the text.
    private static let footnoteLabel = try! NSRegularExpression(
        pattern: #"\[\^[^\]\s]+\]:?"#
    )

    /// Words of the text the editor shows when the caret is elsewhere.
    ///
    /// Built on `DocumentSearch.visibleText`, which already drops heading
    /// hashes, emphasis/code/math delimiters, quote markers and link URLs
    /// with the highlighter's own patterns. It keeps fenced code, math
    /// blocks and front matter verbatim (search must find text in them),
    /// so those regions are blanked here. A word is a run of non-space
    /// characters with at least one letter or digit: list bullets, table
    /// pipes and rules are runs of punctuation and do not count.
    ///
    /// Cost: one pass per pattern plus two arrays the size of the
    /// document, about what a highlight of the whole file costs. Callers
    /// run it debounced and off the main actor.
    static func visibleWordCount(in source: String) -> Int {
        visibleWordCount(in: source, isCancelled: { false })!
    }

    /// As above; nil once `isCancelled` reports true between passes.
    static func visibleWordCount(in source: String, isCancelled: () -> Bool) -> Int? {
        let ns = source as NSString
        let n = ns.length
        guard n > 0 else { return 0 }
        let full = NSRange(location: 0, length: n)

        var skipped = [Bool](repeating: false, count: n)
        for regex in [MarkdownRegexes.frontmatter, MarkdownRegexes.fencedCode,
                      MarkdownRegexes.mathBlock, taskMarker, orderedListMarker, footnoteLabel] {
            if isCancelled() { return nil }
            for m in regex.matches(in: source, range: full) {
                for i in m.range.location..<min(NSMaxRange(m.range), n) { skipped[i] = true }
            }
        }

        if isCancelled() { return nil }
        let visible = DocumentSearch.visibleText(from: source)
        if isCancelled() { return nil }
        var count = 0
        var inToken = false
        var tokenHasContent = false
        var index = 0
        for unit in visible.text.utf16 {
            defer { index += 1 }
            let isSpace: Bool
            let isContent: Bool
            if skipped[visible.map[index]] {
                isSpace = true
                isContent = false
            } else if let scalar = Unicode.Scalar(unit) {
                isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                isContent = !isSpace && CharacterSet.alphanumerics.contains(scalar)
            } else {
                // Half of a surrogate pair: letters outside the BMP and
                // emoji. Count them as content.
                isSpace = false
                isContent = true
            }
            if isSpace {
                if inToken && tokenHasContent { count += 1 }
                inToken = false
                tokenHasContent = false
            } else {
                inToken = true
                if isContent { tokenHasContent = true }
            }
        }
        if inToken && tokenHasContent { count += 1 }
        return count
    }

    /// 1-based line numbers for ascending UTF-16 `offsets`, in one pass.
    static func lineNumbers(at offsets: [Int], in text: String) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(offsets.count)
        var line = 1
        var position = 0
        var iterator = text.utf16.makeIterator()
        for offset in offsets {
            while position < offset, let unit = iterator.next() {
                if unit == 0x0A { line += 1 }
                position += 1
            }
            result.append(line)
        }
        return result
    }
}
