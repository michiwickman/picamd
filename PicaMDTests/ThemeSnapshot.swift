import AppKit
@testable import PicaMD

/// Renders a fixed Markdown sample with a theme and flattens every
/// attribute run the highlighter produces into text. Used to pin that a
/// stored theme still looks exactly the same after a change to the theme
/// model: the expected strings were recorded with the code as it was
/// before the change, so any difference in font, size, colour or
/// paragraph metrics shows up as a readable diff.
@MainActor
enum ThemeSnapshot {
    static let sample = """
    # Title

    Body text with **bold**, *italic*, `inline code`, ==mark== and a [link](https://example.com).

    ## Section

    - item one
    - [ ] open task
    - [x] done task

    > A quote line.

    ### Third

    ```swift
    let x = 1
    ```

    Footnote here[^1].

    [^1]: The note.

    #### Fourth
    """

    static func digest(_ theme: EditorTheme) -> String {
        let highlighter = SyntaxHighlighter()
        highlighter.theme = theme
        let storage = NSTextStorage(string: sample)
        let full = NSRange(location: 0, length: storage.length)
        // What `MarkdownTextView.applyTheme(restyleText: true)` does before
        // the first highlight pass.
        storage.addAttributes([.font: theme.resolvedBodyFont(size: theme.fontBaseSize),
                               .foregroundColor: theme.palette.fg], range: full)
        highlighter.highlight(textStorage: storage, isDark: theme.palette.isDark,
                              cursorRange: NSRange(location: storage.length, length: 0))
        var lines: [String] = []
        storage.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var parts = ["\(range.location)+\(range.length)"]
            if let font = attrs[.font] as? NSFont {
                parts.append("font=\(font.fontName)@\(font.pointSize)")
            }
            if let fg = attrs[.foregroundColor] as? NSColor { parts.append("fg=\(hex(fg))") }
            if let bg = attrs[.backgroundColor] as? NSColor { parts.append("bg=\(hex(bg))") }
            if let u = attrs[.underlineStyle] as? Int { parts.append("ul=\(u)") }
            if let s = attrs[.strikethroughStyle] as? Int { parts.append("st=\(s)") }
            if let k = attrs[.kern] as? CGFloat { parts.append("kern=\(k)") }
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle {
                parts.append("para=\(p.minimumLineHeight)/\(p.maximumLineHeight)/\(p.headIndent)/"
                             + "\(p.firstLineHeadIndent)/\(p.paragraphSpacing)/"
                             + "\(p.paragraphSpacingBefore)/\(p.lineSpacing)")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func hex(_ color: NSColor) -> String {
        guard let s = color.usingColorSpace(.sRGB) else { return "\(color)" }
        return s.toHex()
    }
}
