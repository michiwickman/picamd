import Foundation
import AppKit
import Markdown

/// Convert a Markdown source to a standalone HTML document for export.
///
/// Uses Apple's `swift-markdown` `MarkupVisitor` to walk the GFM AST
/// (headings, paragraphs, emphasis/strong/strikethrough, code, lists,
/// task items, tables, blockquotes, images, links, HR, HTML
/// pass-through). KaTeX is loaded via CDN with auto-render so any
/// `$…$` / `$$…$$` in the source typesets when the file opens in a
/// browser. Mermaid blocks (` ```mermaid ` fences) get class="mermaid"
/// + mermaid.js init so they render as diagrams.
///
/// We intentionally do **not** depend on the `swift-markdown` HTML
/// renderer Apple ships — that one drops GFM tables and forces a
/// single line-feed model. Hand-rolling the visitor lets us match
/// PicaMD's editor styling and embed a portable CSS theme.
enum MarkdownToHTML {

    /// Render the document. `title` falls through:
    ///   1. explicit `title` parameter (caller-provided)
    ///   2. `title:` from YAML frontmatter
    ///   3. text of first heading
    ///   4. "Untitled"
    ///
    /// `palette` lets the export pick up the user's editor theme so
    /// the printed file isn't jarringly different from what they were
    /// looking at while editing. Pass `nil` for the standalone default.
    static func render(_ source: String,
                        title explicitTitle: String? = nil,
                        palette: Palette? = nil) -> String {
        // Strip frontmatter from the body but mine its `title` first.
        let fm = Frontmatter.build(from: source)
        let nsSource = source as NSString
        let body: String = {
            guard let fmRange = fm.range else { return source }
            let after = NSRange(location: NSMaxRange(fmRange),
                                length: nsSource.length - NSMaxRange(fmRange))
            return nsSource.substring(with: after)
        }()

        // Pre-processing pipeline. Order matters: footnotes turn `[^id]`
        // into HTML refs and strip the `[^id]: …` definition lines into
        // a separate footer block. Highlights are pure inline. Both
        // happen before swift-markdown parses, so the visitor doesn't
        // have to know about them. KaTeX `$…$` is left untouched so the
        // auto-render JS can typeset it client-side without fighting
        // HTML escaping.
        let footnoteIndex = FootnoteIndex.build(from: body)
        let withFootnotes = preprocessFootnotes(body, index: footnoteIndex)
        let preprocessed = preprocessHighlights(withFootnotes)

        // Parse + visit.
        let document = Document(parsing: preprocessed)
        var visitor = HTMLVisitor()
        var html = visitor.visit(document)

        if !footnoteIndex.refs.isEmpty {
            html += renderFootnoteBlock(index: footnoteIndex)
        }

        let title = explicitTitle
            ?? fm.title
            ?? firstHeadingText(in: document)
            ?? "Untitled"

        return wrap(body: html, title: title, palette: palette)
    }

    // MARK: - Helpers

    private static func preprocessHighlights(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"==([^=\n]+?)=="#) else {
            return source
        }
        let nsSource = source as NSString
        let result = NSMutableString(string: source)
        let matches = regex.matches(in: source, options: [],
                                     range: NSRange(location: 0, length: nsSource.length))
        // Replace right-to-left so earlier-match indexes stay valid.
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2 else { continue }
            let inner = nsSource.substring(with: m.range(at: 1))
            result.replaceCharacters(in: m.range, with: "<mark>\(inner)</mark>")
        }
        return result as String
    }

    /// Replace `[^id]` references with `<sup class="footnote-ref">…`
    /// links, and strip `[^id]: …` definition lines from the body
    /// (they're rendered as a separate `<dl class="footnotes">` block
    /// at the document end). The list of refs and definitions comes
    /// from `FootnoteIndex` so we get the same parsing the editor's
    /// hover-tooltip uses.
    private static func preprocessFootnotes(_ source: String,
                                             index: FootnoteIndex) -> String {
        guard !index.refs.isEmpty || !index.definitions.isEmpty else { return source }
        let nsSource = source as NSString
        let result = NSMutableString(string: source)

        // 1. Strip every `[^id]:` definition line up through the next
        //    blank line (or the next def line). We work from the
        //    bottom up so earlier indexes stay valid.
        if let defRegex = try? NSRegularExpression(
            pattern: #"(?m)^\[\^([^\]]+)\]:[ \t]+[\s\S]*?(?=\n\n|\n\[\^|\z)"#
        ) {
            let matches = defRegex.matches(
                in: result as String,
                options: [],
                range: NSRange(location: 0, length: result.length)
            )
            for m in matches.reversed() {
                // Drop the trailing blank line too (regex stops *at* `\n\n`)
                // by extending one extra newline if there's one right after.
                var dropRange = m.range
                let endLoc = NSMaxRange(dropRange)
                if endLoc < result.length,
                   result.character(at: endLoc) == 10 {  // '\n'
                    dropRange.length += 1
                }
                result.replaceCharacters(in: dropRange, with: "")
            }
        }

        // 2. Replace every `[^id]` ref (in the now-shorter source) with
        //    a numbered <sup><a> link. Re-build a fresh ref-list
        //    against the current `result` to keep ranges valid.
        let refRegex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#)
        guard let refRegex = refRegex else { return result as String }
        let refMatches = refRegex.matches(
            in: result as String,
            options: [],
            range: NSRange(location: 0, length: result.length)
        )
        // Map `id` → 1-based number. First-encountered wins.
        var idToNumber: [String: Int] = [:]
        var counter = 0
        let refs: [(NSRange, String, Int)] = refMatches.compactMap { m in
            guard m.numberOfRanges >= 2 else { return nil }
            let id = (result as NSString).substring(with: m.range(at: 1))
            let n: Int
            if let existing = idToNumber[id] {
                n = existing
            } else {
                counter += 1
                idToNumber[id] = counter
                n = counter
            }
            return (m.range, id, n)
        }
        for (range, id, n) in refs.reversed() {
            let safeId = htmlEscape(id)
            let html = "<sup class=\"footnote-ref\" id=\"fnref-\(safeId)\">" +
                       "<a href=\"#fn-\(safeId)\">\(n)</a></sup>"
            result.replaceCharacters(in: range, with: html)
        }

        return result as String
    }

    /// Render the footer that lists each footnote definition.
    /// Numbered to match the `[^id]` ref order in the body.
    private static func renderFootnoteBlock(index: FootnoteIndex) -> String {
        // Stable ordering: walk refs in document order, dedup by id,
        // emit definitions in the order they were first referenced.
        var seen = Set<String>()
        var ordered: [String] = []
        for ref in index.refs where !seen.contains(ref.id) {
            seen.insert(ref.id)
            ordered.append(ref.id)
        }
        // Append any defined-but-unreferenced ids at the end so the
        // user doesn't lose definitions that drifted from their refs.
        for id in index.definitions.keys where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        guard !ordered.isEmpty else { return "" }

        var html = "<section class=\"footnotes\" role=\"doc-endnotes\">\n"
        html += "<hr>\n<ol>\n"
        for id in ordered {
            let safeId = htmlEscape(id)
            let definition = index.definitions[id] ?? "(no definition)"
            // The definition came from `FootnoteIndex.build` which
            // collapses whitespace — that's fine for the simple
            // single-paragraph footnotes 99% of users write. We still
            // run inline Markdown through `Document(parsing:)` so
            // links/code/emphasis inside the def render correctly.
            let inlineDoc = Document(parsing: definition)
            var visitor = HTMLVisitor()
            let inlineHTML = visitor.visit(inlineDoc)
                .replacingOccurrences(of: "<p>", with: "")
                .replacingOccurrences(of: "</p>\n", with: "")
                .replacingOccurrences(of: "</p>", with: "")
            html += "<li id=\"fn-\(safeId)\">\(inlineHTML) " +
                    "<a href=\"#fnref-\(safeId)\" class=\"footnote-back\" " +
                    "aria-label=\"Back to reference\">↩</a></li>\n"
        }
        html += "</ol>\n</section>\n"
        return html
    }

    private static func firstHeadingText(in doc: Document) -> String? {
        for child in doc.children {
            if let h = child as? Heading {
                return h.plainText
            }
        }
        return nil
    }

    /// Wrap rendered body HTML in a portable standalone document.
    private static func wrap(body: String, title: String, palette: Palette?) -> String {
        let safeTitle = htmlEscape(title)

        // Resolve colours from the palette (if any). Without a palette
        // we ship the system-default light/dark scheme via
        // `prefers-color-scheme` so the file looks reasonable when
        // double-clicked anywhere.
        let css = embeddedCSS(palette: palette)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>\(css)</style>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.css">
        </head>
        <body>
        <article>
        \(body)
        </article>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/contrib/auto-render.min.js"
                onload="renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$',  right: '$',  display: false}
                    ],
                    throwOnError: false
                });"></script>
        <script type="module">
            import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.esm.min.mjs";
            mermaid.initialize({ startOnLoad: true, theme: 'default' });
        </script>
        </body>
        </html>
        """
    }

    private static func embeddedCSS(palette: Palette?) -> String {
        if let p = palette {
            return embeddedCSS(
                bg: p.bg.cssHex,
                fg: p.fg.cssHex,
                muted: p.fgMuted.cssHex,
                accent: p.accent.cssHex,
                codeBg: p.codeBg.cssHex,
                codeFg: p.codeFg.cssHex,
                rule: p.rule.cssHex
            )
        }
        // System-default: respect the viewer's light/dark preference.
        return """
            :root {
                --bg: #ffffff; --fg: #1d1d1f; --muted: #6b6b72;
                --accent: #0a84ff; --code-bg: #f7f7f8; --code-fg: #2a2a2e;
                --rule: #e3e3e7;
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --bg: #1c1c1e; --fg: #ececec; --muted: #9b9ba1;
                    --accent: #0a84ff; --code-bg: #252527; --code-fg: #e7e7ea;
                    --rule: #38383a;
                }
            }
            \(commonCSS)
            """
    }

    private static func embeddedCSS(bg: String, fg: String, muted: String,
                                     accent: String, codeBg: String, codeFg: String,
                                     rule: String) -> String {
        """
        :root {
            --bg: \(bg); --fg: \(fg); --muted: \(muted);
            --accent: \(accent); --code-bg: \(codeBg); --code-fg: \(codeFg);
            --rule: \(rule);
        }
        \(commonCSS)
        """
    }

    private static let commonCSS: String = """
        html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
        body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI",
               "Helvetica Neue", Arial, sans-serif; }
        article { max-width: 720px; margin: 40px auto; padding: 0 24px; }
        h1, h2, h3, h4, h5, h6 { color: var(--fg); margin: 1.2em 0 0.4em; line-height: 1.25; }
        h1 { font-size: 2.0em; border-bottom: 1px solid var(--rule); padding-bottom: 0.2em; }
        h2 { font-size: 1.6em; border-bottom: 1px solid var(--rule); padding-bottom: 0.15em; }
        h3 { font-size: 1.3em; } h4 { font-size: 1.1em; } h5, h6 { font-size: 1.0em; }
        p { margin: 0.6em 0; }
        a { color: var(--accent); text-decoration: none; border-bottom: 1px solid var(--accent); }
        a:hover { background: rgba(10, 132, 255, 0.08); }
        blockquote { color: var(--muted); border-left: 3px solid var(--rule);
                     margin: 1em 0; padding: 0.2em 0 0.2em 1em; font-style: italic; }
        code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
               font-size: 0.92em; background: var(--code-bg); color: var(--code-fg);
               padding: 0.1em 0.3em; border-radius: 4px; }
        pre { background: var(--code-bg); color: var(--code-fg); padding: 12px 16px;
              border-radius: 8px; overflow-x: auto; line-height: 1.4; }
        pre code { background: none; padding: 0; border-radius: 0; font-size: 0.9em; }
        ul, ol { padding-left: 1.6em; }
        li { margin: 0.15em 0; }
        li input[type=checkbox] { margin-right: 0.5em; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        table { border-collapse: collapse; margin: 1em 0; width: 100%; }
        th, td { border: 1px solid var(--rule); padding: 6px 10px; text-align: left; }
        th { background: var(--code-bg); font-weight: 600; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        mark { background: rgba(255, 213, 0, 0.55); color: var(--fg); padding: 0 0.15em; }
        .mermaid { background: var(--code-bg); padding: 12px; border-radius: 8px;
                    text-align: center; }
        details { margin: 0.6em 0; padding: 0.4em 0.8em; border: 1px solid var(--rule);
                   border-radius: 6px; }
        details > summary { font-weight: 600; cursor: pointer; }
        sup.footnote-ref { font-size: 0.75em; line-height: 0; }
        sup.footnote-ref a { border-bottom: 0; padding: 0 0.15em; }
        section.footnotes { margin-top: 3em; font-size: 0.92em; color: var(--muted); }
        section.footnotes ol { padding-left: 1.4em; }
        section.footnotes li { margin: 0.4em 0; }
        a.footnote-back { margin-left: 0.3em; text-decoration: none;
                          border-bottom: 0; opacity: 0.55; }
        a.footnote-back:hover { opacity: 1; }
    """

    /// Sanitize a raw HTML string that came from a user-authored Markdown
    /// document. This is necessary because .md files may be untrusted
    /// (received by mail, downloaded from the web, cloned from an unknown
    /// repo) and PicaMD exports / QuickLook-previews them in a browser
    /// context. The sanitizer:
    ///   - Removes `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`
    ///     elements together with all their content (start-tag to end-tag).
    ///   - Strips all `on*=` event-handler attributes from any remaining tag.
    ///   - Strips `href`/`src`/`action` attribute values that start with
    ///     `javascript:` (case-insensitive, whitespace-tolerant).
    ///
    /// Ordinary formatting tags (`<b>`, `<i>`, `<em>`, `<strong>`,
    /// `<a>`, `<code>`, `<span>`, `<div>`, comments, etc.) are left intact.
    ///
    /// A regex-based approach is deliberately chosen: this codebase has
    /// no SwiftSoup / HTML-parser dependency, and adding one for this
    /// single use-case is out of scope. The patterns are conservative —
    /// they may over-strip in exotic edge cases (e.g. nested quotes in
    /// event attrs), which is acceptable: the failure mode is slightly
    /// degraded rendering, not XSS.
    static func sanitizeHTML(_ html: String) -> String {
        var s = html

        // 1. Remove dangerous block elements including all their content.
        //    Pattern: <tag …> … </tag> (case-insensitive, dot matches
        //    newlines via `.dotMatchesLineSeparators`).
        let dangerousTags = ["script", "style", "iframe", "object", "embed"]
        for tag in dangerousTags {
            let pattern = "<\(tag)(\\s[^>]*)?>.*?</\(tag)>"
            if let re = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
            // Also remove self-closing / void forms: <embed …> <object …>
            let voidPattern = "<\(tag)(\\s[^>]*)?(/)?>?"
            if let re = try? NSRegularExpression(
                pattern: voidPattern,
                options: [.caseInsensitive]
            ) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }

        // 2. Strip on* event-handler attributes from surviving tags.
        //    Matches both single- and double-quoted values, and unquoted.
        //    Pattern: \s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]*)
        if let re = try? NSRegularExpression(
            pattern: #"\s+on[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]*)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }

        // 3. Strip javascript: URLs from href/src/action attributes.
        //    Tolerates whitespace and mixed case between "javascript" and ":".
        if let re = try? NSRegularExpression(
            pattern: #"(href|src|action)\s*=\s*["']?\s*javascript\s*:[^"'\s>]*["']?"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }

        return s
    }

    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - The visitor

/// `MarkupVisitor` that emits standalone HTML strings. We rely on
/// `defaultVisit` to recurse over children, and override only the
/// node types that need a wrapper. Everything inline returns a string
/// (no leading/trailing newline); everything block-level returns the
/// wrapped HTML followed by `\n` so the output is grep-able.
private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    // MARK: Block-level

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = max(1, min(6, heading.level))
        return "<h\(level)>\(defaultVisit(heading))</h\(level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        // Paragraphs containing only an image render as a block-level
        // figure for nicer typography. Otherwise wrap in <p>.
        let inner = defaultVisit(paragraph)
        return "<p>\(inner)</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(blockQuote))</blockquote>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol>\n\(defaultVisit(list))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // For "tight" list items — single paragraph, no nested block —
        // strip the paragraph wrapper so the HTML is `<li>text</li>`
        // instead of `<li><p>text</p></li>`. swift-markdown wraps every
        // item in a Paragraph, but GFM's tight-list rendering doesn't.
        // Loose lists (multi-block items) are left as-is so block
        // separators still render.
        var inner = defaultVisit(listItem)
        let isSingleParagraph = listItem.childCount == 1
            && listItem.child(at: 0) is Paragraph
        if isSingleParagraph,
           inner.hasPrefix("<p>"),
           inner.hasSuffix("</p>\n") {
            inner = String(inner.dropFirst("<p>".count).dropLast("</p>\n".count))
        }
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            return "<li><input type=\"checkbox\" disabled\(checked)>\(inner)</li>\n"
        }
        return "<li>\(inner)</li>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = (codeBlock.language ?? "").lowercased()
        let code = MarkdownToHTML.htmlEscape(codeBlock.code)
        if lang == "mermaid" {
            // Strip the trailing newline so mermaid.js doesn't get
            // confused by an empty final line.
            let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
            return "<pre class=\"mermaid\">\(trimmed)</pre>\n"
        }
        let cls = lang.isEmpty ? "" : " class=\"language-\(lang)\""
        return "<pre><code\(cls)>\(code)</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> String {
        // Sanitize before emitting. Raw .md files may be opened as
        // QuickLook previews or exported HTML and viewed in a browser;
        // in those contexts the author is not necessarily trusted (e.g.
        // a .md file received by e-mail, downloaded, or part of an
        // untrusted repo). Strip executable elements and event handlers
        // while keeping ordinary formatting tags intact.
        MarkdownToHTML.sanitizeHTML(htmlBlock.rawHTML) + "\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        var out = "<table>\n"
        out += "<thead><tr>"
        for cell in table.head.cells {
            out += "<th>\(defaultVisit(cell))</th>"
        }
        out += "</tr></thead>\n"
        out += "<tbody>\n"
        for row in table.body.rows {
            out += "<tr>"
            for cell in row.cells {
                out += "<td>\(defaultVisit(cell))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String {
        MarkdownToHTML.htmlEscape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<s>\(defaultVisit(strikethrough))</s>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(MarkdownToHTML.htmlEscape(inlineCode.code))</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        // Same trust argument as visitHTMLBlock — sanitize before emitting.
        MarkdownToHTML.sanitizeHTML(inlineHTML.rawHTML)
    }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? ""
        let safe = MarkdownToHTML.htmlEscape(dest)
        return "<a href=\"\(safe)\">\(defaultVisit(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = image.source ?? ""
        let safeSrc = MarkdownToHTML.htmlEscape(src)
        let alt = image.plainText
        let safeAlt = MarkdownToHTML.htmlEscape(alt)
        let titleAttr: String = {
            if let t = image.title, !t.isEmpty {
                return " title=\"\(MarkdownToHTML.htmlEscape(t))\""
            }
            return ""
        }()
        return "<img src=\"\(safeSrc)\" alt=\"\(safeAlt)\"\(titleAttr)>"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        " "
    }
}

// MARK: - NSColor → CSS hex helper

private extension NSColor {
    var cssHex: String {
        guard let s = self.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((s.redComponent * 255).rounded())
        let g = Int((s.greenComponent * 255).rounded())
        let b = Int((s.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
