import Foundation

/// Single source of truth for the regex patterns shared between the
/// `BlockExtractor` (which finds overlay blocks for the BlockOverlayManager)
/// and the `SyntaxHighlighter` (which paints inline attributes and the
/// concealment fence-lines around the same blocks).
///
/// Keeping these in one place removes the previous drift risk where
/// `BlockExtractor.mathBlockRegex` and
/// `SyntaxHighlighter.mathBlockRegex` were two compiled instances of
/// the same pattern that could (and did) get edited independently.
enum MarkdownRegexes {
    static let mathBlock = compile(#"(?m)^\$\$[\s\S]*?^\$\$\s*$"#)
    static let mermaidFence = compile(#"(?m)^```mermaid[ \t]*\n[\s\S]*?^```[ \t]*$"#)
    static let fencedCode = compile(#"(?m)^([`~]{3,})[^\n]*\n[\s\S]*?^\1[ \t]*$"#)
    /// Block-level image: a line that is *only* an `![alt](url)` (with
    /// optional Pandoc-style `{width=N}` attribute set).
    static let blockImage = compile(
        #"^[ \t]*!\[([^\]]*)\]\(([^)]+)\)(\{[^}]*\})?[ \t]*$"#,
        options: [.anchorsMatchLines]
    )
    /// Inline image: same pattern without the line anchors. Multiple
    /// matches per line are possible.
    static let inlineImage = compile(#"!\[([^\]]*)\]\(([^)]+)\)"#)
    /// Pandoc-style `{width=N}` attribute parsed out of an image line.
    static let imageResizeAttribute = compile(
        #"\bwidth\s*=\s*(\d+)"#,
        options: [.caseInsensitive]
    )

    // Inline / line-level markup whose markers the editor conceals. Shared
    // by `SyntaxHighlighter` (which hides the markers) and `DocumentSearch`
    // (whose ignore-formatting mode searches the text left visible), so
    // the two can't drift apart on what counts as markup.
    static let heading = compile(#"^(#{1,6})([ \t]+)(.+?)[ \t]*#*$"#, options: [.anchorsMatchLines])
    static let blockquote = compile(#"^(>[ \t]?)(.*)$"#, options: [.anchorsMatchLines])
    static let bold = compile(#"(?<![*_\w])(\*\*|__)(?=\S)([\s\S]+?)(?<=\S)\1(?![*_\w])"#)
    static let italic = compile(#"(?<![*_\w])(\*|_)(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#)
    static let inlineCode = compile(#"(`+)([^`\n]+?)\1"#)
    static let link = compile(#"(!?)\[([^\]]*)\]\(([^)]+)\)"#)
    static let strikethrough = compile(#"(~~)(?=\S)([\s\S]+?)(?<=\S)\1"#)
    static let highlight = compile(#"(==)(?=\S)([\s\S]+?)(?<=\S)\1"#)
    static let mathInline = compile(#"(?<!\$)(\$)(?!\s)([^\$\n]+?)(?<!\s)\1(?!\$)"#)
    static let frontmatter = compile(#"\A---\n[\s\S]*?\n---\n"#)

    private static func compile(_ pattern: String,
                                 options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
