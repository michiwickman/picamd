import Foundation

/// One ATX heading discovered in the source.
struct DocumentHeading: Identifiable, Equatable, Sendable {
    let id: Int            // monotonic per-doc index, used for List diffing
    let level: Int         // 1...6
    let text: String       // heading text without the leading `#`s and the space
    let lineRange: NSRange // range of the entire heading line in the source
    let titleLocation: Int // character location of the first letter of the title
}

/// Extracts ATX-style headings (`# Title`) from a Markdown source. Lines
/// inside fenced code blocks are skipped so `# Comment` inside a Bash
/// snippet doesn't end up in the outline.
enum HeadingExtractor {

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*#*$"#,
        options: [.anchorsMatchLines]
    )
    private static let fencedCodeRegex = try! NSRegularExpression(
        pattern: #"(?m)^([`~]{3,})[^\n]*\n[\s\S]*?^\1[ \t]*$"#,
        options: []
    )

    private static let htmlTagRegex = try! NSRegularExpression(pattern: "</?[a-zA-Z][^>]*>")

    /// Strip Markdown and HTML markup from a heading title so the outline
    /// shows the text as the editor renders it: `# **Bold** <u>x</u>`
    /// becomes "Bold x". Uses the editor's own concealment rules, so
    /// `snake_case` or `a * b` stay intact (every `_`/`*` used to be
    /// deleted), and no longer compiles nine regexes per heading on
    /// every keystroke.
    static func plainText(from source: String) -> String {
        let range = NSRange(location: 0, length: (source as NSString).length)
        let withoutTags = htmlTagRegex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        return DocumentSearch.visibleText(from: withoutTags).text
            .trimmingCharacters(in: .whitespaces)
    }

    static func extract(from source: String) -> [DocumentHeading] {
        guard !source.isEmpty else { return [] }
        let nsString = source as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // First find all fenced code-block ranges so we can skip headings
        // inside them.
        var protected: [NSRange] = []
        fencedCodeRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            if let m = match { protected.append(m.range) }
        }
        func inProtected(_ loc: Int) -> Bool {
            for r in protected {
                if NSLocationInRange(loc, r) { return true }
            }
            return false
        }

        var results: [DocumentHeading] = []
        var nextID = 0
        headingRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            guard let m = match else { return }
            // The heading marker (`#`s) must start at the beginning of a
            // line — the regex's anchorsMatchLines option enforces that.
            // We additionally skip if the match is inside a fenced code
            // block.
            if inProtected(m.range.location) { return }

            let hashes = m.range(at: 1)
            let titleRange = m.range(at: 2)
            let level = hashes.length
            let rawTitle = nsString.substring(with: titleRange)
                .trimmingCharacters(in: .whitespaces)
            // Strip Markdown / HTML markup so the outline shows the
            // user-facing prose, not raw `**Bold**` or `<u>tag</u>`.
            let title = Self.plainText(from: rawTitle)
            // The line range so click-to-jump can scroll to the entire line.
            let lineRange = nsString.lineRange(for: NSRange(location: m.range.location, length: 0))

            results.append(DocumentHeading(
                id: nextID,
                level: level,
                text: title,
                lineRange: lineRange,
                titleLocation: titleRange.location
            ))
            nextID += 1
        }
        return results
    }
}
