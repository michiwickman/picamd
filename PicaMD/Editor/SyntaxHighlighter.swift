import AppKit

@MainActor
final class SyntaxHighlighter {
    /// Active theme. Drives palette, heading font, body font, scale.
    /// `EditorTheme.default` if no one has set anything.
    var theme: EditorTheme = .default

    /// Memoised render palette. `RenderPalette(theme:)` does HSB boosts
    /// and alpha-blends on construction; rebuilding it on every highlight
    /// pass (at the 16 ms cursor-move cadence) is pure waste since the
    /// theme rarely changes. Rebuilt only when `theme` actually differs.
    private var cachedPalette: RenderPalette?
    private var cachedPaletteTheme: EditorTheme?

    private func renderPalette() -> RenderPalette {
        if let cached = cachedPalette, cachedPaletteTheme == theme { return cached }
        let p = RenderPalette(theme: theme)
        cachedPalette = p
        cachedPaletteTheme = theme
        return p
    }

    /// Memoised full-document block-structure scan (fenced code, math
    /// blocks, frontmatter). These three regexes are inherently O(n) over
    /// the whole document — re-running them on every cursor move (which
    /// can't change block structure) was the dominant typing-latency cost
    /// on large docs. Keyed on source identity; a text edit recomputes.
    private var blockScanSource: String?
    private var blockScanCode: [NSRange] = []
    private var blockScanMath: [NSRange] = []
    private var blockScanFrontmatter: [NSRange] = []

    private func blockRangesScan(for source: String,
                                  fullRange: NSRange) -> ([NSRange], [NSRange], [NSRange]) {
        if blockScanSource == source {
            return (blockScanCode, blockScanMath, blockScanFrontmatter)
        }
        let code = collect(Self.fencedCodeRegex, in: source, range: fullRange).map(\.range)
        let math = collect(Self.mathBlockRegex, in: source, range: fullRange).map(\.range)
        let front = collect(Self.frontmatterRegex, in: source, range: fullRange).map(\.range)
        blockScanSource = source
        blockScanCode = code
        blockScanMath = math
        blockScanFrontmatter = front
        return (code, math, front)
    }

    // Patterns shared with BlockExtractor live in MarkdownRegexes.
    private static var fencedCodeRegex: NSRegularExpression { MarkdownRegexes.fencedCode }
    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^(#{1,6})([ \t]+)(.+?)[ \t]*#*$"#,
        options: [.anchorsMatchLines]
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^(>[ \t]?)(.*)$"#,
        options: [.anchorsMatchLines]
    )
    private static let listRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|\d+\.)([ \t]+)"#,
        options: [.anchorsMatchLines]
    )
    // Task-list extraction now lives in `CheckboxOverlayManager.extractMatches(from:)`
    // — used by both this highlighter (for concealment + strike-through)
    // and the overlay manager (for view placement) so they can never
    // disagree on which lines have checkboxes.
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"(?<![*_\w])(\*\*|__)(?=\S)([\s\S]+?)(?<=\S)\1(?![*_\w])"#,
        options: []
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<![*_\w])(\*|_)(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#,
        options: []
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: #"(`+)([^`\n]+?)\1"#,
        options: []
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\(([^)]+)\)"#,
        options: []
    )
    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: #"(~~)(?=\S)([\s\S]+?)(?<=\S)\1"#,
        options: []
    )
    private static let highlightRegex = try! NSRegularExpression(
        pattern: #"(==)(?=\S)([\s\S]+?)(?<=\S)\1"#,
        options: []
    )
    private static let hrRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(\*[ \t]*\*[ \t]*\*[\* \t]*|-[ \t]*-[ \t]*-[\- \t]*|_[ \t]*_[ \t]*_[_ \t]*)$"#,
        options: [.anchorsMatchLines]
    )
    private static let mathInlineRegex = try! NSRegularExpression(
        pattern: #"(?<!\$)(\$)(?!\s)([^\$\n]+?)(?<!\s)\1(?!\$)"#,
        options: []
    )
    private static var mathBlockRegex: NSRegularExpression { MarkdownRegexes.mathBlock }
    private static let frontmatterRegex = try! NSRegularExpression(
        pattern: #"\A---\n[\s\S]*?\n---\n"#,
        options: []
    )
    private static let footnoteRefRegex = try! NSRegularExpression(
        pattern: #"\[\^([^\]]+)\]"#,
        options: []
    )
    private static let footnoteDefRegex = try! NSRegularExpression(
        pattern: #"^\[\^([^\]]+)\]:[ \t]+"#,
        options: [.anchorsMatchLines]
    )
    private static let tableRowRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\|.+\|[ \t]*$"#,
        options: [.anchorsMatchLines]
    )
    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)+\|?[ \t]*$"#,
        options: [.anchorsMatchLines]
    )
    private static let htmlTagRegex = try! NSRegularExpression(
        pattern: #"</?[a-zA-Z][^>]*>"#,
        options: []
    )
    private static let kbdRegex = try! NSRegularExpression(
        pattern: #"<kbd>([\s\S]*?)</kbd>"#,
        options: [.caseInsensitive]
    )
    private static let underlineHTMLRegex = try! NSRegularExpression(
        pattern: #"<u>([\s\S]*?)</u>"#,
        options: [.caseInsensitive]
    )
    private static let detailsRegex = try! NSRegularExpression(
        pattern: #"<details>([\s\S]*?)</details>"#,
        options: [.caseInsensitive]
    )
    private static let summaryRegex = try! NSRegularExpression(
        pattern: #"<summary>([\s\S]*?)</summary>"#,
        options: [.caseInsensitive]
    )
    private static let htmlCommentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#,
        options: []
    )
    private static var imageRegex: NSRegularExpression { MarkdownRegexes.inlineImage }
    private static var mermaidFenceRegex: NSRegularExpression { MarkdownRegexes.mermaidFence }

    func highlight(
        textStorage: NSTextStorage,
        isDark: Bool,
        cursorRange: NSRange? = nil,
        blocks: [ExtractedBlock] = [],
        blockHeights: [ExtractedBlock: CGFloat] = [:],
        viewportRange: NSRange? = nil,
        focusMode: Bool = false,
        // Task-list matches, computed once by the caller and shared with
        // the CheckboxOverlayManager so the two can't disagree. `nil`
        // means "compute internally" (the path unit tests and any caller
        // that doesn't pre-extract take).
        taskMatches: [TaskListMatch]? = nil
    ) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        let source = textStorage.string
        let palette = renderPalette()
        let baseFont = theme.bodyFont.font(size: theme.fontBaseSize)
        let cursor = cursorRange ?? NSRange(location: -1, length: 0)
        let blockRanges = blocks.map { $0.range }
        // Working range = the slice of the document we'll re-attribute on
        // this pass. When the caller provides a viewport, we only touch
        // that slice; off-screen attributes from the previous pass are
        // left as-is. This is what keeps long documents responsive.
        let workingRange = clampRange(viewportRange ?? fullRange, to: fullRange)

        textStorage.beginEditing()

        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: palette.foreground,
        ], range: workingRange)

        // Block-level detection always covers the whole document so the
        // overlay manager and protected-range logic see every block.
        // These three full-document regex scans are memoised by source:
        // a cursor move (text unchanged) reuses the cache instead of
        // re-scanning the whole doc at the 16 ms cursor-move cadence.
        let (codeRanges, mathBlockRanges, frontmatterRanges) = blockRangesScan(for: source, fullRange: fullRange)
        let protected = codeRanges + mathBlockRanges + frontmatterRanges + blockRanges

        let resolvedTaskMatches = taskMatches ?? CheckboxOverlayManager.extractMatches(from: source)

        paintBlockStructure(textStorage: textStorage,
                             source: source,
                             workingRange: workingRange,
                             protected: protected,
                             frontmatterRanges: frontmatterRanges,
                             palette: palette,
                             baseFont: baseFont,
                             cursor: cursor,
                             taskMatches: resolvedTaskMatches)

        paintInlineMarkers(textStorage: textStorage,
                            source: source,
                            workingRange: workingRange,
                            protected: protected,
                            palette: palette,
                            baseFont: baseFont,
                            cursor: cursor)

        paintTablesAndMathBlock(textStorage: textStorage,
                                 source: source,
                                 workingRange: workingRange,
                                 protected: protected,
                                 mathBlockRanges: mathBlockRanges,
                                 palette: palette,
                                 cursor: cursor)

        paintHTMLPass(textStorage: textStorage,
                      source: source,
                      workingRange: workingRange,
                      protected: protected,
                      palette: palette,
                      baseFont: baseFont,
                      cursor: cursor)

        paintCodeBlocksAndOverlays(textStorage: textStorage,
                                    source: source,
                                    blocks: blocks,
                                    blockHeights: blockHeights,
                                    blockRanges: blockRanges,
                                    codeRanges: codeRanges,
                                    viewportRange: viewportRange,
                                    palette: palette,
                                    cursor: cursor)

        if focusMode {
            applyFocusModeDim(textStorage: textStorage,
                               source: source,
                               workingRange: workingRange,
                               cursor: cursor)
        }

        textStorage.endEditing()
    }

    /// Final pass that runs only when Focus Mode is active. Dims every
    /// paragraph except the one the cursor sits in by re-applying the
    /// already-set foreground colour at `0.3` alpha. Walks the
    /// existing `.foregroundColor` runs (which the earlier passes set
    /// to a wide variety of palette colours, plus `NSColor.clear` for
    /// concealed markers) and rewrites each to its dimmed counterpart
    /// — so the dimming respects whatever colour the highlighter
    /// would otherwise have used.
    ///
    /// We deliberately do NOT touch `.clear` (concealed markup) or
    /// already-low-alpha colours — those would either become visible
    /// noise or get dimmed twice. Cursor's paragraph is left untouched.
    private func applyFocusModeDim(
        textStorage: NSTextStorage,
        source: String,
        workingRange: NSRange,
        cursor: NSRange
    ) {
        // Define "current paragraph" in the AppKit sense (run between
        // newlines). For an empty selection at start-of-doc this gives
        // an empty range, which is fine — nothing to spare.
        let nsSource = source as NSString
        let cursorParagraph = nsSource.paragraphRange(
            for: NSRange(location: max(0, min(cursor.location, nsSource.length)), length: 0)
        )

        // We only dim what's inside the working range — anything off-
        // viewport keeps its old (already-dimmed-or-not) attributes
        // from the previous pass. The viewport-incremental-highlight
        // model in the rest of the highlighter does the same thing.
        let leading = NSRange(location: workingRange.location,
                              length: max(0, cursorParagraph.location - workingRange.location))
        let trailingStart = cursorParagraph.location + cursorParagraph.length
        let trailing = NSRange(location: trailingStart,
                                length: max(0, NSMaxRange(workingRange) - trailingStart))

        for region in [leading, trailing] where region.length > 0 {
            textStorage.enumerateAttribute(.foregroundColor,
                                            in: region,
                                            options: []) { value, range, _ in
                guard let color = value as? NSColor else { return }
                if color == .clear { return }   // concealed markup — leave hidden
                // Idempotent: if this run is already dimmed (carries the
                // stash), don't dim again — that would compound to 0.3×0.3.
                if textStorage.attribute(.qmdUndimmedForeground,
                                          at: range.location,
                                          effectiveRange: nil) != nil {
                    return
                }
                // Stash the pre-dim colour so a Focus-OFF toggle can
                // restore the exact colour without a full regex re-highlight.
                textStorage.addAttribute(.qmdUndimmedForeground, value: color, range: range)
                let dimmed = color.withAlphaComponent(color.alphaComponent * 0.3)
                textStorage.addAttribute(.foregroundColor, value: dimmed, range: range)
            }
        }
    }

    /// Undo Focus-Mode dimming across the whole document by restoring the
    /// stashed pre-dim foreground colours. Cheap: a single O(n) attribute
    /// walk, no regex passes — so toggling Focus off doesn't pay for a
    /// full-document re-highlight (which froze 10k-line docs for seconds).
    func removeFocusDim(textStorage: NSTextStorage) {
        let full = NSRange(location: 0, length: textStorage.length)
        guard full.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.enumerateAttribute(.qmdUndimmedForeground,
                                        in: full, options: []) { value, range, _ in
            if let original = value as? NSColor {
                textStorage.addAttribute(.foregroundColor, value: original, range: range)
            }
            textStorage.removeAttribute(.qmdUndimmedForeground, range: range)
        }
        textStorage.endEditing()
    }

    // MARK: - Per-pass helpers

    /// Document-structure markers: frontmatter block, headings (with
    /// hairline-rule support when the user has it enabled), block-
    /// quotes, list markers, task-list checkboxes. Each follows its
    /// own concealment scheme — they don't share the
    /// `concealMarkers(...)` helper because their marker placement
    /// varies (heading hashes vs blockquote `>`s vs list bullets).
    private func paintBlockStructure(
        textStorage: NSTextStorage,
        source: String,
        workingRange: NSRange,
        protected: [NSRange],
        frontmatterRanges: [NSRange],
        palette: RenderPalette,
        baseFont: NSFont,
        cursor: NSRange,
        taskMatches: [TaskListMatch]
    ) {
        // Frontmatter — muted code-block-style for the leading `---` block.
        for r in frontmatterRanges {
            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: r)
            textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize - 1), range: r)
        }

        // Headings — proportional fonts per level, hash markers conceal
        // when the cursor's outside, optional hairline rule under H1/H2.
        for m in collect(Self.headingRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let hashesRange = m.range(at: 1)
            let spaceRange = m.range(at: 2)
            let level = hashesRange.length
            let active = cursor.touchesBlock(m.range)

            textStorage.addAttribute(.font, value: headingFont(level: level), range: m.range)
            textStorage.addAttribute(.foregroundColor, value: palette.heading, range: m.range)

            if active {
                textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: hashesRange)
            } else {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: hashesRange)
                textStorage.addAttribute(.font, value: tinyFont(), range: hashesRange)
                textStorage.addAttribute(.font, value: tinyFont(), range: spaceRange)
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: spaceRange)
            }

            if theme.headingRule && level <= 2 {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacing = 6
                para.paragraphSpacingBefore = 4
                textStorage.addAttribute(.paragraphStyle, value: para, range: m.range)
                textStorage.addAttribute(.underlineStyle,
                                         value: NSUnderlineStyle.single.rawValue,
                                         range: m.range)
                textStorage.addAttribute(.underlineColor,
                                         value: palette.muted.withAlphaComponent(0.45),
                                         range: m.range)
            }
        }

        // Blockquotes — italic + indent, leading `>` conceals when cursor's outside.
        for m in collect(Self.blockquoteRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let markerRange = m.range(at: 1)
            let textRange = m.range(at: 2)
            let active = cursor.touchesBlock(m.range)

            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            applyTrait(.italicFontMask, in: textStorage, range: textRange, baseFont: baseFont)

            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = 14
            para.headIndent = 14
            textStorage.addAttribute(.paragraphStyle, value: para, range: m.range)

            if active {
                textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: markerRange)
            } else {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: markerRange)
                textStorage.addAttribute(.font, value: tinyFont(), range: markerRange)
            }
        }

        // List markers — kept visible always, accent-coloured.
        for m in collect(Self.listRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let markerRange = m.range(at: 2)
            if markerRange.location != NSNotFound {
                textStorage.addAttribute(.foregroundColor, value: palette.accent, range: markerRange)
                textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize, bold: true), range: markerRange)
            }
        }

        // Task list checkbox: conceal `[ ]`/`[x]` markup off-cursor —
        // the `CheckboxOverlayManager` paints a real checkbox at the
        // boxRange's glyph rect — and strike-through + dim the rest of
        // the line when the item is checked. Cursor-on-line restores
        // raw markup so the user can edit `[ ]` ↔ `[x]` directly,
        // matching the concealment idiom used by every other inline
        // token in PicaMD.
        //
        // The `[ ]`/`[x]` BOX concealment is written for the FULL match
        // set (not just the viewport slice): checkboxes are sparse, the
        // CheckboxOverlayManager places a view for every match regardless
        // of viewport, and an un-concealed off-viewport `[ ]` would peek
        // out under its overlay. A box write carries no inline markup and
        // is idempotent per match, so writing it doc-wide still converges
        // with a single full pass (important for the progressive theme
        // sweep, which highlights the doc in chunks).
        //
        // The strike-through + dim on the trailing TEXT, however, must stay
        // within the working range: it sets `.foregroundColor`, and writing
        // it outside the current chunk would clobber inline styling
        // (e.g. `**bold**` inside a checked item) that an earlier chunk
        // already painted and that no later pass would restore — making the
        // chunked sweep diverge from a full pass.
        for match in taskMatches {
            if match.lineRange.isInsideAny(of: protected) { continue }

            let active = cursor.touchesBlock(match.lineRange)
            if active {
                textStorage.addAttribute(.foregroundColor,
                                         value: palette.accent,
                                         range: match.boxRange)
            } else {
                // Keep the boxRange at its normal font size so the
                // glyph rect has a well-defined width — the overlay
                // manager queries that rect to position its 14×14 view.
                textStorage.addAttribute(.foregroundColor,
                                         value: NSColor.clear,
                                         range: match.boxRange)
            }

            if match.checked && !active && match.textRange.length > 0
                && NSLocationInRange(match.textRange.location, workingRange) {
                textStorage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue,
                                         range: match.textRange)
                textStorage.addAttribute(.foregroundColor,
                                         value: palette.muted,
                                         range: match.textRange)
            }
        }
    }

    /// Tables (alternate row backgrounds, alignment-separator concealment)
    /// and `$$…$$` math-block fence concealment. Both share "block-
    /// shape" semantics that don't fit cleanly into the inline pass.
    private func paintTablesAndMathBlock(
        textStorage: NSTextStorage,
        source: String,
        workingRange: NSRange,
        protected: [NSRange],
        mathBlockRanges: [NSRange],
        palette: RenderPalette,
        cursor: NSRange
    ) {
        // Tables — alternate row backgrounds, conceal alignment-separator.
        var rowIndex = 0
        for m in collect(Self.tableRowRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let isSeparator = Self.tableSeparatorRegex.firstMatch(in: source, options: [], range: m.range) != nil
            let active = cursor.touchesBlock(m.range)
            textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize - 1), range: m.range)
            if isSeparator {
                if !active {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range)
                    textStorage.addAttribute(.font, value: tinyFont(), range: m.range)
                } else {
                    textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: m.range)
                }
            } else {
                let bg = (rowIndex % 2 == 0) ? palette.codeBackground : palette.codeBlockBackground
                textStorage.addAttribute(.backgroundColor, value: bg, range: m.range)
                rowIndex += 1
            }
        }

        // Math block — conceal `$$` fences when cursor is outside, render inner as math.
        for r in mathBlockRanges {
            let active = cursor.touchesBlock(r)
            textStorage.setAttributes([
                .font: NSFont.systemFont(ofSize: theme.fontBaseSize + 1),
                .foregroundColor: palette.math,
                .backgroundColor: palette.codeBlockBackground,
            ], range: r)
            applyTrait(.italicFontMask, in: textStorage, range: r, baseFont: NSFont.systemFont(ofSize: theme.fontBaseSize + 1))
            let centerPara = NSMutableParagraphStyle()
            centerPara.alignment = .center
            centerPara.lineSpacing = 6
            textStorage.addAttribute(.paragraphStyle, value: centerPara, range: r)
            if !active {
                let nsSource = source as NSString
                let openLine = nsSource.lineRange(for: NSRange(location: r.location, length: 0))
                let closeLineStart = r.location + r.length
                let closeLine = nsSource.lineRange(for: NSRange(location: max(0, closeLineStart - 1), length: 0))
                for fence in [openLine, closeLine] where fence.length > 0 {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: fence)
                    textStorage.addAttribute(.font, value: tinyFont(), range: fence)
                }
            }
        }
    }

    /// Inline markers that follow the standard concealment pattern
    /// (markers vanish when the cursor's outside, become muted hints
    /// when it's inside the span): bold / italic / strikethrough /
    /// highlight / inline-code / inline-math / link-or-image / HR /
    /// footnote-ref / footnote-def. Extracted from `highlight()` so
    /// the orchestrator stays manageable.
    private func paintInlineMarkers(
        textStorage: NSTextStorage,
        source: String,
        workingRange: NSRange,
        protected: [NSRange],
        palette: RenderPalette,
        baseFont: NSFont,
        cursor: NSRange
    ) {
        // Bold (and bold-italic when wrapped as `***x***`)
        for m in collect(Self.boldRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            let inner = m.range(at: 2)
            applyTrait(.boldFontMask, in: textStorage, range: m.range, baseFont: baseFont)

            // Detect `***x***` / `___x___`: inner content begins/ends with the same single marker.
            let nsSource = source as NSString
            if inner.length >= 2 {
                let firstChar = nsSource.substring(with: NSRange(location: inner.location, length: 1))
                let lastChar = nsSource.substring(with: NSRange(location: inner.location + inner.length - 1, length: 1))
                if firstChar == lastChar, (firstChar == "*" || firstChar == "_") {
                    let innerContent = NSRange(location: inner.location + 1, length: inner.length - 2)
                    applyTrait(.italicFontMask, in: textStorage, range: innerContent, baseFont: baseFont)
                    let innerOpen = NSRange(location: inner.location, length: 1)
                    let innerClose = NSRange(location: inner.location + inner.length - 1, length: 1)
                    concealMarkers(textStorage: textStorage, ranges: [innerOpen, innerClose], pair: m.range, cursor: cursor, palette: palette)
                }
            }
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Italic
        for m in collect(Self.italicRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            applyTrait(.italicFontMask, in: textStorage, range: m.range, baseFont: baseFont)
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Strikethrough
        for m in collect(Self.strikethroughRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Highlight (==)
        for m in collect(Self.highlightRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            textStorage.addAttribute(.backgroundColor, value: palette.highlight, range: m.range)
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Inline code
        for m in collect(Self.inlineCodeRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            let inner = m.range(at: 2)
            textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize - 0.5), range: m.range)
            textStorage.addAttribute(.foregroundColor, value: palette.code, range: m.range)
            textStorage.addAttribute(.backgroundColor, value: palette.codeBackground, range: inner)
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Inline math
        for m in collect(Self.mathInlineRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let openR = m.range(at: 1)
            let closeR = NSRange(location: m.range.location + m.range.length - openR.length, length: openR.length)
            textStorage.addAttribute(.foregroundColor, value: palette.math, range: m.range)
            textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize - 0.5), range: m.range)
            concealMarkers(textStorage: textStorage, ranges: [openR, closeR], pair: m.range, cursor: cursor, palette: palette)
        }

        // Links and images
        for m in collect(Self.linkRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let isImage = m.range(at: 1).length > 0
            let textRange = m.range(at: 2)
            let urlRange = m.range(at: 3)
            let active = cursor.touches(m.range)

            let labelColor = isImage ? palette.muted : palette.link
            textStorage.addAttribute(.foregroundColor, value: labelColor, range: textRange)
            if !isImage {
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
            }

            if active {
                textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: urlRange)
            } else {
                // Conceal the bracket pair around the label and the `(url)` portion.
                let openBracket = NSRange(location: m.range.location + (isImage ? 1 : 0), length: 1)
                let imgBangRange = isImage ? NSRange(location: m.range.location, length: 1) : NSRange(location: 0, length: 0)
                let closeBracketLoc = textRange.location + textRange.length
                let closeBracket = NSRange(location: closeBracketLoc, length: 1)
                let parenStart = closeBracketLoc + 1
                let parenEnd = m.range.location + m.range.length
                let parenRange = NSRange(location: parenStart, length: parenEnd - parenStart)

                if isImage {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: imgBangRange)
                    textStorage.addAttribute(.font, value: tinyFont(), range: imgBangRange)
                }
                for r in [openBracket, closeBracket, parenRange] where r.length > 0 {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                    textStorage.addAttribute(.font, value: tinyFont(), range: r)
                }
            }
        }

        // HR — render as a thin rule by concealing `---` and underlining the line.
        for m in collect(Self.hrRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            if cursor.touches(m.range) {
                textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            } else {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range)
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: m.range)
                textStorage.addAttribute(.underlineColor, value: palette.muted, range: m.range)
                textStorage.addAttribute(.kern, value: 30 as Any, range: m.range)
            }
        }

        // Footnote references and definitions.
        for m in collect(Self.footnoteRefRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            textStorage.addAttribute(.foregroundColor, value: palette.link, range: m.range)
            textStorage.addAttribute(.font, value: NSFont.systemFont(ofSize: theme.fontBaseSize - 3), range: m.range)
            textStorage.addAttribute(.baselineOffset, value: 4 as Any, range: m.range)
        }
        for m in collect(Self.footnoteDefRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            textStorage.addAttribute(.font, value: systemFont(size: theme.fontBaseSize - 1), range: m.range)
        }
    }

    /// Code blocks (fenced ``` …) plus the block-overlay concealment
    /// pass. Mermaid blocks live in `blockRanges` so they're skipped
    /// here and rendered as overlays. Code-block syntax-highlighting
    /// runs at the end of this pass so it sits inside the same pass
    /// that owns the code-block backgrounds.
    private func paintCodeBlocksAndOverlays(
        textStorage: NSTextStorage,
        source: String,
        blocks: [ExtractedBlock],
        blockHeights: [ExtractedBlock: CGFloat],
        blockRanges: [NSRange],
        codeRanges: [NSRange],
        viewportRange: NSRange?,
        palette: RenderPalette,
        cursor: NSRange
    ) {
        // Code blocks — visual style depends on theme.codeStyle:
        //   .card    — solid background + subtle indent (default)
        //   .tinted  — solid background, no extra indent
        //   .stripe  — accent-coloured left bar, no background fill
        //   .flat    — muted text, no background, no decoration
        //
        // Block writes are clipped to `work` (the viewport slice). A
        // whole-range write here would clobber, in already-painted chunks,
        // the per-language tokens that `CodeBlockHighlighter` applies only
        // within the current viewport — making the progressive theme sweep
        // diverge from a full pass. Clipping keeps every chunk's writes
        // inside its slice, so the union across chunks equals a full pass.
        let work = viewportRange ?? NSRange(location: 0, length: (source as NSString).length)
        var codeRangesForTokenizing: [NSRange] = []
        for r in codeRanges {
            // Skip if this is a mermaid block (handled by overlay below).
            if blockRanges.contains(where: { NSEqualRanges($0, r) }) { continue }
            let rWork = NSIntersectionRange(r, work)
            if rWork.length == 0 { continue }   // code block outside this slice

            var attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont(size: theme.fontBaseSize - 0.5),
            ]
            switch theme.codeStyle {
            case .card:
                attrs[.foregroundColor] = palette.code
                attrs[.backgroundColor] = palette.codeBlockBackground
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = 8
                para.headIndent = 8
                para.tailIndent = -8
                para.paragraphSpacing = 4
                attrs[.paragraphStyle] = para
            case .tinted:
                attrs[.foregroundColor] = palette.code
                attrs[.backgroundColor] = palette.codeBlockBackground
            case .stripe:
                attrs[.foregroundColor] = palette.code
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = 14
                para.headIndent = 14
                attrs[.paragraphStyle] = para
            case .flat:
                attrs[.foregroundColor] = palette.muted
            }
            textStorage.setAttributes(attrs, range: rWork)
            codeRangesForTokenizing.append(r)

            // Stripe-style: paint the accent on the leftmost char of every
            // line — a fake left-edge bar. A real vertical bar would need
            // a custom NSLayoutManager. Walk only the in-slice portion.
            if theme.codeStyle == .stripe {
                let nsSrc = source as NSString
                var loc = rWork.location
                while loc < rWork.location + rWork.length {
                    let lineRange = nsSrc.lineRange(for: NSRange(location: loc, length: 0))
                    if lineRange.length > 0 {
                        let stripeRange = NSRange(location: lineRange.location, length: 1)
                        textStorage.addAttribute(.foregroundColor,
                                                 value: theme.effectiveAccent,
                                                 range: stripeRange)
                    }
                    loc = NSMaxRange(lineRange)
                    if loc <= lineRange.location { break }
                }
            }

            let active = cursor.touchesBlock(r)
            if !active {
                // Conceal the opening + closing fence lines so the block
                // looks like a clean code panel.
                let nsSource = source as NSString
                let openLineRange = nsSource.lineRange(for: NSRange(location: r.location, length: 0))
                let closeLineStart = r.location + r.length
                let closeLineRange = nsSource.lineRange(for: NSRange(location: max(0, closeLineStart - 1), length: 0))
                for fence in [openLineRange, closeLineRange] {
                    if fence.length > 0 && NSIntersectionRange(fence, work).length > 0 {
                        textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: fence)
                        textStorage.addAttribute(.font, value: tinyFont(), range: fence)
                    }
                }
            }
        }

        // Per-language token highlighting on top of the code-block backdrop.
        CodeBlockHighlighter.highlight(
            textStorage: textStorage,
            source: source,
            codeBlocks: codeRangesForTokenizing,
            isDark: theme.palette.isDark,
            viewportRange: viewportRange
        )

        // Block overlays (tables, math blocks, mermaid, block-level images):
        // when the cursor is OUTSIDE the block, conceal the source text and
        // reserve enough vertical space (min-line-height on the first line)
        // for the overlay view to draw on top.
        for block in blocks {
            let r = block.range
            if cursor.touches(r) { continue }   // editing — keep source
            let rWork = NSIntersectionRange(r, work)
            if rWork.length == 0 { continue }   // overlay block outside this slice
            let nsSource = source as NSString
            textStorage.setAttributes([
                .foregroundColor: NSColor.clear,
                .font: tinyFont(),
            ], range: rWork)
            // The min-line-height reservation goes on the block's first
            // line — apply only when that line is in the current slice.
            let firstLine = nsSource.lineRange(for: NSRange(location: r.location, length: 0))
            if NSIntersectionRange(firstLine, work).length > 0 {
                let height = blockHeights[block] ?? defaultHeight(for: block.kind)
                let para = NSMutableParagraphStyle()
                para.minimumLineHeight = height + 8
                para.maximumLineHeight = height + 8
                textStorage.addAttribute(.paragraphStyle, value: para, range: firstLine)
            }
        }
    }

    /// HTML pass — `<kbd>`, `<u>`, `<summary>`, `<details>`, `<!-- -->`,
    /// and the generic-tag mute-fallback. Extracted from `highlight()`
    /// so the orchestrator stays manageable. Behaviour is identical to
    /// the inline version that lived there before — verified by the
    /// existing 102 highlight + extractor tests.
    private func paintHTMLPass(
        textStorage: NSTextStorage,
        source: String,
        workingRange: NSRange,
        protected: [NSRange],
        palette: RenderPalette,
        baseFont: NSFont,
        cursor: NSRange
    ) {
        // <kbd>X</kbd> → keyboard-key styled X
        for m in collect(Self.kbdRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let inner = m.range(at: 1)
            let active = cursor.touches(m.range)
            textStorage.addAttribute(.font, value: monoFont(size: theme.fontBaseSize - 1), range: inner)
            textStorage.addAttribute(.foregroundColor, value: palette.foreground, range: inner)
            textStorage.addAttribute(.backgroundColor, value: palette.codeBackground, range: inner)
            let openTagLen = "<kbd>".count
            let closeTagLen = "</kbd>".count
            let openTag = NSRange(location: m.range.location, length: openTagLen)
            let closeTag = NSRange(location: m.range.location + m.range.length - closeTagLen, length: closeTagLen)
            if active {
                for r in [openTag, closeTag] {
                    textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: r)
                }
            } else {
                for r in [openTag, closeTag] {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                    textStorage.addAttribute(.font, value: tinyFont(), range: r)
                }
            }
        }

        // <u>X</u> → underlined X
        for m in collect(Self.underlineHTMLRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let inner = m.range(at: 1)
            let active = cursor.touches(m.range)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: inner)
            if !active {
                let openTag = NSRange(location: m.range.location, length: 3)
                let closeTag = NSRange(location: m.range.location + m.range.length - 4, length: 4)
                for r in [openTag, closeTag] {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                    textStorage.addAttribute(.font, value: tinyFont(), range: r)
                }
            }
        }

        // <summary>X</summary> → bold + heading-coloured text; tags conceal when cursor's outside.
        for m in collect(Self.summaryRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            let inner = m.range(at: 1)
            let active = cursor.touches(m.range)
            applyTrait(.boldFontMask, in: textStorage, range: inner, baseFont: baseFont)
            textStorage.addAttribute(.foregroundColor, value: palette.heading, range: inner)
            if !active {
                let openTagLen = "<summary>".count
                let closeTagLen = "</summary>".count
                let openTag = NSRange(location: m.range.location, length: openTagLen)
                let closeTag = NSRange(location: m.range.location + m.range.length - closeTagLen, length: closeTagLen)
                for r in [openTag, closeTag] {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                    textStorage.addAttribute(.font, value: tinyFont(), range: r)
                }
            }
        }

        // <details>...</details> — collapsed-by-default like real HTML.
        // Cursor outside: hide wrapper tags AND body, leaving the <summary>
        // visible. Cursor inside: show everything for editing. Nested
        // blocks need a stack-based scanner; outers process first so the
        // outer collapse-styling gets overridden where an inner sits
        // instead of bleeding through.
        let detailsRanges = Self.balancedDetailsRanges(in: source, within: workingRange)
        for r in detailsRanges where !r.isInsideAny(of: protected) {
            applyDetailsStyling(at: r,
                                palette: palette,
                                source: source,
                                cursor: cursor,
                                textStorage: textStorage)
        }

        // HTML comments → muted
        for m in collect(Self.htmlCommentRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
        }

        // Generic HTML tags (catch-all for tags not handled above) — mute them
        for m in collect(Self.htmlTagRegex, in: source, range: workingRange) {
            if m.range.isInsideAny(of: protected) { continue }
            // Skip if foreground is already overridden by a more-specific
            // pass above (clear / muted / hint).
            let existing = textStorage.attribute(.foregroundColor, at: m.range.location, effectiveRange: nil) as? NSColor
            if existing == NSColor.clear { continue }
            if existing == palette.muted || existing == palette.markupHint { continue }
            let active = cursor.touches(m.range)
            if active {
                textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: m.range)
            } else {
                textStorage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            }
        }
    }

    private func defaultHeight(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .table: return EditorBlockDefaults.table
        case .image: return EditorBlockDefaults.image
        case .mathBlock: return EditorBlockDefaults.mathBlock
        case .mermaid: return EditorBlockDefaults.mermaid
        }
    }

    // MARK: - Helpers

    private func concealMarkers(textStorage: NSTextStorage, ranges: [NSRange], pair: NSRange, cursor: NSRange, palette: RenderPalette) {
        let active = cursor.touches(pair)
        for r in ranges {
            if r.length == 0 { continue }
            if active {
                textStorage.addAttribute(.foregroundColor, value: palette.markupHint, range: r)
            } else {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                textStorage.addAttribute(.font, value: tinyFont(), range: r)
            }
        }
    }

    /// Stack-scanner for balanced `<details>...</details>` ranges. Returns
    /// every block whose opening tag falls within `bounds` (or whose
    /// closing tag does). Outer blocks come BEFORE their inner blocks.
    private static func balancedDetailsRanges(in source: String,
                                              within bounds: NSRange) -> [NSRange] {
        guard source.range(of: "<details", options: .caseInsensitive) != nil else { return [] }
        let nsString = source as NSString
        let length = nsString.length
        let openTag = "<details>"
        let closeTag = "</details>"
        let openLen = openTag.count
        let closeLen = closeTag.count

        var openings: [Int] = []
        var ranges: [NSRange] = []
        var i = 0
        while i <= length - closeLen {
            // Match case-insensitively by lowercasing the next chunk
            let lookahead = max(openLen, closeLen)
            guard i + 1 <= length else { break }
            // Quick char check
            if nsString.character(at: i) == 0x3C /* < */ {
                let remaining = length - i
                if remaining >= openLen,
                   nsString.substring(with: NSRange(location: i, length: openLen)).lowercased() == openTag {
                    openings.append(i)
                    i += openLen
                    continue
                }
                if remaining >= closeLen,
                   nsString.substring(with: NSRange(location: i, length: closeLen)).lowercased() == closeTag {
                    if let start = openings.popLast() {
                        let r = NSRange(location: start, length: (i + closeLen) - start)
                        // Only include blocks that touch the requested bounds
                        let boundsEnd = bounds.location + bounds.length
                        let rEnd = r.location + r.length
                        if rEnd > bounds.location && r.location < boundsEnd {
                            ranges.append(r)
                        }
                    }
                    i += closeLen
                    continue
                }
                _ = lookahead
            }
            i += 1
        }
        // Outer-first ordering so inner styling overrides outer.
        ranges.sort { ($0.length, -$0.location) > ($1.length, -$1.location) }
        return ranges
    }

    private func applyDetailsStyling(at mRange: NSRange,
                                     palette: RenderPalette,
                                     source: String,
                                     cursor: NSRange,
                                     textStorage: NSTextStorage) {
        let active = cursor.touches(mRange)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 12
        para.headIndent = 12
        textStorage.addAttribute(.paragraphStyle, value: para, range: mRange)
        textStorage.addAttribute(.backgroundColor,
                                 value: palette.codeBackground.withAlphaComponent(0.5),
                                 range: mRange)
        if active { return }   // editing — show source

        let openTagLen = "<details>".count
        let closeTagLen = "</details>".count
        let openTag = NSRange(location: mRange.location, length: openTagLen)
        let closeTag = NSRange(location: mRange.location + mRange.length - closeTagLen,
                               length: closeTagLen)
        let inner = NSRange(location: mRange.location + openTagLen,
                            length: mRange.length - openTagLen - closeTagLen)
        let summaryMatch = Self.summaryRegex.firstMatch(in: source, options: [], range: inner)

        guard let sm = summaryMatch, sm.numberOfRanges > 1 else {
            // No summary → leave the source visible (just muted), so
            // the user sees something to click back on.
            textStorage.addAttribute(.foregroundColor, value: palette.muted, range: mRange)
            return
        }

        textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: mRange)
        textStorage.addAttribute(.font, value: tinyFont(), range: mRange)
        let summaryInner = sm.range(at: 1)
        textStorage.addAttributes([
            .foregroundColor: palette.heading,
            .font: self.headingFont(level: 4),
        ], range: summaryInner)
        for r in [openTag, closeTag] {
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            textStorage.addAttribute(.font, value: tinyFont(), range: r)
        }
    }

    private func clampRange(_ range: NSRange, to bounds: NSRange) -> NSRange {
        let lower = max(bounds.location, range.location)
        let upper = min(bounds.location + bounds.length, range.location + range.length)
        let length = max(0, upper - lower)
        return NSRange(location: lower, length: length)
    }

    private func collect(_ regex: NSRegularExpression, in source: String, range: NSRange) -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            if let m = match { results.append(m) }
        }
        return results
    }

    private func applyTrait(_ trait: NSFontTraitMask, in storage: NSTextStorage, range: NSRange, baseFont: NSFont) {
        if range.length == 0 { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let current = (value as? NSFont) ?? baseFont
            let traited = NSFontManager.shared.convert(current, toHaveTrait: trait)
            storage.addAttribute(.font, value: traited, range: subRange)
        }
    }

    private func headingFont(level: Int) -> NSFont {
        let sizes = theme.headingScale.sizes
        let idx = max(0, min(sizes.count - 1, level - 1))
        return theme.headingFont.font(size: sizes[idx], bold: true)
    }

    private func systemFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private func monoFont(size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private func tinyFont() -> NSFont {
        NSFont.systemFont(ofSize: EditorFont.concealedSize)
    }
}

/// Adapter from the new top-level `EditorTheme` to the field names the
/// existing highlighter passes use. Kept private so the highlighter
/// internals don't have to change shape; only the colour source does.
/// Pre-computed render-ready colour set derived from the active theme
/// palette + accent. Each `paint…` pass in `SyntaxHighlighter` consumes
/// 5–7 of these 11 colours, so passing the struct around is much
/// cleaner than threading 7 NSColors through each helper signature.
///
/// The init owns the non-trivial bits — the heading-colour boost for
/// dark palettes (OLED / Dark Grey users complained the unboosted
/// version was washed-out) and the derived `markupHint` alpha-blend.
/// Inlining these would mean repeating the logic across every pass,
/// so the struct stays.
private struct RenderPalette {
    let foreground: NSColor
    let heading: NSColor
    let muted: NSColor
    let markupHint: NSColor
    let accent: NSColor
    let link: NSColor
    let code: NSColor
    let codeBackground: NSColor
    let codeBlockBackground: NSColor
    let highlight: NSColor
    let math: NSColor

    /// Build from the canonical theme.
    init(theme: EditorTheme) {
        let p = theme.palette
        let isDark = p.isDark
        let acc = theme.effectiveAccent

        foreground = p.fg

        // Headings need a colour that's distinct from body text but
        // still readable on the chosen palette. On dark backgrounds
        // we want a *brighter, more saturated* hue (OLED users
        // complained the old "blend with fg" version was washed-out).
        // On light backgrounds we keep a deeper, calmer tone.
        if isDark {
            // Saturate the accent and lift its luminance so it pops
            // against deep grey / pure black without burning the eyes.
            heading = Self.boostForDarkBackground(acc)
        } else {
            // Mute the accent slightly so big H1s aren't shouting.
            heading = acc.blended(withFraction: 0.30, of: p.fg) ?? acc
        }

        muted = p.fgMuted
        markupHint = p.fgMuted.withAlphaComponent(0.5)
        accent = acc
        link = acc
        code = p.codeFg
        codeBackground = p.codeInlineBg
        codeBlockBackground = p.codeBg
        highlight = p.highlight
        math = p.math
    }

    /// Push an accent colour toward higher saturation and lift its
    /// luminance to ~0.78 so headings stay legible on OLED-black and
    /// dark-grey palettes. This is what fixes the "headings look
    /// washed-out on OLED" complaint.
    private static func boostForDarkBackground(_ color: NSColor) -> NSColor {
        guard let s = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        let boostedSat = min(1.0, sat * 1.25 + 0.10)
        let boostedBrightness = max(0.78, b)
        return NSColor(hue: h, saturation: boostedSat,
                       brightness: boostedBrightness, alpha: a)
    }
}

extension NSAttributedString.Key {
    /// Stashes a run's pre-dim foreground colour while Focus Mode dims it,
    /// so toggling Focus off restores the exact colour with a cheap
    /// attribute walk instead of a full regex re-highlight.
    static let qmdUndimmedForeground = NSAttributedString.Key("qmdUndimmedForeground")
}

private extension NSRange {
    func isInsideAny(of ranges: [NSRange]) -> Bool {
        for r in ranges where NSLocationInRange(location, r) {
            return true
        }
        return false
    }

    /// Cursor "touches" the target range if cursor location/extent is within
    /// 1 char of the range boundary on either side. For a multi-line range,
    /// any cursor inside the range counts as touching.
    func touches(_ target: NSRange) -> Bool {
        let expandedStart = max(0, target.location - 1)
        let expandedEnd = target.location + target.length + 1
        let cursorEnd = location + length
        return cursorEnd >= expandedStart && location <= expandedEnd
    }

    /// Block-level variant of `touches(_:)` — no trailing +1 fuzz so a cursor
    /// positioned exactly one character PAST the end of a block (i.e. on the
    /// first character of the next line) does NOT count as touching. The
    /// leading -1 is kept so a cursor at the very start of the opening line is
    /// still inside the block's active zone.
    func touchesBlock(_ target: NSRange) -> Bool {
        let expandedStart = max(0, target.location - 1)
        let expandedEnd = target.location + target.length   // no +1 here
        let cursorEnd = location + length
        return cursorEnd >= expandedStart && location <= expandedEnd
    }
}
