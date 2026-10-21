import AppKit

/// Manages the lifecycle of block-attachment overlay views inside an
/// NSTextView. The text storage retains the original markdown source
/// (concealed via clear-color + tiny font + extra line height), and
/// these overlay views are rendered on top at the corresponding glyph
/// positions, so the markdown looks "rendered" while staying editable.
///
/// Math and Mermaid blocks live behind a viewport-aware lazy layer:
/// only blocks within an expanded viewport window get their real
/// `WebViewBlockView` (which spawns a WKWebView process). Off-screen
/// blocks render as a cheap `PlaceholderBlockView` instead. This
/// keeps RAM bounded at large docs with many math/mermaid blocks.
///
/// **View pool keyed by content identity, not range.** The pool is
/// keyed by `(kind, payload, ordinal)` rather than by `ExtractedBlock`
/// (whose hash includes `range.location`). Editing a character *above*
/// a math/mermaid block shifts every following block's range — if the
/// pool were range-keyed, all those blocks would look "new", their
/// WKWebViews would be torn down and respawned on every keystroke. With
/// identity keying, a range shift reuses the same view (only its frame
/// moves); a WKWebView is created/destroyed only when a block's content
/// actually appears/changes/disappears.
@MainActor
final class BlockOverlayManager {
    weak var textView: NSTextView?
    /// The document's file URL, for resolving relative image paths.
    /// The first highlight pass runs before the view is in a window, so
    /// image overlays are often built while this is still nil — they then
    /// showed "file not found" for every `./assets/…` image until the
    /// line was edited. Drop them when the URL arrives so the next
    /// `update` rebuilds them against the right folder.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            for (id, entry) in entries where id.kind == .image {
                entry.view.removeFromSuperview()
                entries.removeValue(forKey: id)
            }
            probeHeightCache = probeHeightCache.filter { $0.key.kind != .image }
        }
    }

    /// Stable identity for a block across range shifts. `ordinal`
    /// disambiguates two byte-identical blocks (e.g. two `$$x$$`) so
    /// editing above the second doesn't make it adopt the first's view.
    private struct BlockIdentity: Hashable {
        let kind: BlockKind
        let payload: String
        let ordinal: Int
    }

    /// One pooled overlay: the view plus the block it currently renders.
    /// `block` here tracks the *current* range so `reposition()` follows
    /// edits without recreating. For content-keyed kinds the view's own
    /// payload never changes; a position-keyed table view adopts the new
    /// block in `update()`, so before that its payload can be stale.
    private struct Entry {
        let view: BlockAttachmentView
        var block: ExtractedBlock
    }

    /// Pool keyed by content identity. Survives range shifts.
    private var entries: [BlockIdentity: Entry] = [:]
    /// Last reported live-rendered height per block, keyed by identity so
    /// the reserved line-height survives range shifts too.
    private var blockHeights: [BlockIdentity: CGFloat] = [:]
    private var lastBlocks: [ExtractedBlock] = []

    /// Content key used only to disambiguate byte-identical blocks when
    /// assigning ordinals. Deliberately width-free — a resize must not
    /// renumber blocks.
    private struct ContentKey: Hashable {
        let kind: BlockKind
        let payload: String
    }

    /// Height cache for synchronously-measurable blocks (table, image).
    /// Keyed on (kind, payload, width) so the result survives range shifts
    /// **but not a width change**. Leaving `width` out was a real bug: a
    /// window resize changes the wrapped height of a table without changing
    /// its payload, so the highlighter kept reserving the height measured at
    /// the OLD width until the user happened to edit the block. That is the
    /// "it fixes itself when I click into the table" symptom. Width is
    /// quantised to whole points so sub-pixel jitter doesn't defeat the cache.
    private struct ProbeKey: Hashable {
        let kind: BlockKind
        let payload: String
        let width: Int
    }
    private var probeHeightCache: [ProbeKey: CGFloat] = [:]
    /// Quantised width the probe cache currently holds entries for.
    private var lastProbeWidth: Int = 0

    private func probeKey(for block: ExtractedBlock, width: CGFloat) -> ProbeKey {
        ProbeKey(kind: block.kind, payload: block.payload, width: Int(width.rounded()))
    }
    /// Cache of the last-known cursor-active ranges so `refreshLiveSet()`
    /// can re-evaluate the viewport without losing the cursor-overlay-
    /// hiding behaviour.
    private var lastCursorActiveRanges: [NSRange] = []

    /// How far above and below the visible glyph rect we keep blocks
    /// "live". Two viewport heights of pre/post-scroll buffer feels
    /// generous without exploding RAM.
    private let viewportLiveBufferMultiplier: CGFloat = 2.0
    /// Hard ceiling on the number of WebView-backed blocks that may
    /// be live at once, regardless of viewport size. Single-WKWebView
    /// process is ~10 MB resident; this caps us at ~120 MB worst-case
    /// for math/mermaid alone.
    private let maxLiveWebViews: Int = 12

    // MARK: - Identity

    /// Compute a stable identity per block, aligned 1:1 with `blocks`.
    /// `ordinal` counts prior blocks with the same (kind, payload).
    /// Tables are keyed by their POSITION among the document's tables, not by
    /// their content: editing one cell must refresh the existing view, not
    /// replace it, or an open cell editor would be destroyed mid-keystroke.
    /// It also removes per-keystroke view churn while typing inside a table.
    ///
    /// Images, math and mermaid stay content-keyed: there the identity exists
    /// to stop a view from being torn down and respawned when an unrelated
    /// edit above merely shifts the block's range. Images in particular must
    /// NOT be pooled by position: `ImageBlockView` loads its file once, in
    /// `setupContent()`, so a reused view kept showing — and sizing for — the
    /// old image after the path changed or an image above it was removed.
    private func identities(for blocks: [ExtractedBlock]) -> [BlockIdentity] {
        var contentCounts: [ContentKey: Int] = [:]
        var tableCount = 0
        return blocks.map { b in
            switch b.kind {
            case .table:
                let ordinal = tableCount
                tableCount += 1
                return BlockIdentity(kind: b.kind, payload: "", ordinal: ordinal)
            case .image, .mathBlock, .mermaid:
                let key = ContentKey(kind: b.kind, payload: b.payload)
                let ordinal = contentCounts[key, default: 0]
                contentCounts[key] = ordinal + 1
                return BlockIdentity(kind: b.kind, payload: b.payload, ordinal: ordinal)
            }
        }
    }

    // MARK: - Geometry: the single source of truth

    /// The ONE width at which every overlay block is both **measured** and
    /// **drawn**.
    ///
    /// This used to be two independent expressions that disagreed by 2 pt:
    /// the highlighter measured at `textView.bounds.width - inset*2 - 16`
    /// while `reposition()` drew at `boundingRect.width - 4`. Two points
    /// sounds harmless, and for most tables it is — but when a cell's text
    /// happens to sit exactly on a wrap boundary those 2 pt push a word onto
    /// a new line, the row grows by a full line, and the reserved band no
    /// longer matches the drawn table. Measured on real documents: 1 table in
    /// 22 was off, by 16 pt. That is the "usually fine, now and then shifted"
    /// bug.
    ///
    /// Deriving it here — rather than letting callers pass a width in — makes
    /// the two *unable* to diverge. Note that even a momentarily stale
    /// container width is harmless now: measurement and drawing read the same
    /// stale value, stay consistent, and the next pass corrects both.
    /// Returns `nil` while the text container has no resolved width yet.
    /// That case is NOT the same as a genuinely narrow window and must not
    /// be clamped to the minimum: `makeNSView` runs `applyHighlightingNow()`
    /// before SwiftUI has laid the scroll view out, so `container.size.width`
    /// is 0. Clamping there reserved every table in the document as if the
    /// window were 120 pt wide — roughly an eightfold over-reservation — and
    /// because later passes only rewrite the reservation for blocks inside
    /// the viewport slice, every table below the fold kept that band until
    /// the caret happened to visit it.
    func resolvedContentWidth() -> CGFloat? {
        guard let container = textView?.textContainer, container.size.width > 0 else {
            return nil
        }
        let usable = container.size.width
            - 2 * container.lineFragmentPadding
            - EditorLayout.blockOverlayHorizontalInset
        return max(EditorLayout.blockOverlayMinWidth, usable)
    }

    // MARK: - Public API

    /// Compute desired heights for every block, so the highlighter can
    /// reserve enough vertical space (via min-line-height) before the
    /// overlay views are positioned on top. The width is derived internally
    /// (see `contentWidth()`) — callers must not supply one, or the
    /// measure/draw agreement this guarantees would be lost again.
    func desiredHeights(for blocks: [ExtractedBlock]) -> [ExtractedBlock: CGFloat] {
        guard let width = resolvedContentWidth() else { return [:] }
        // A live window resize walks through many widths; without this the
        // cache would accumulate one entry per block per intermediate width.
        // Only the current width can ever be hit again, so drop the rest.
        let quantised = Int(width.rounded())
        if quantised != lastProbeWidth {
            probeHeightCache = probeHeightCache.filter { $0.key.width == quantised }
            lastProbeWidth = quantised
        }
        let ids = identities(for: blocks)
        var out: [ExtractedBlock: CGFloat] = [:]
        for (i, block) in blocks.enumerated() {
            let id = ids[i]
            switch block.kind {
            case .table, .image:
                // Synchronous-measurable. Use the existing live view if
                // available; otherwise consult the content-keyed probe
                // cache (survives range shifts) before falling back to a
                // fresh throwaway probe via makeRealView — which is
                // expensive per highlight pass.
                let key = probeKey(for: block, width: width)
                if let cached = probeHeightCache[key] {
                    out[block] = cached
                } else if let v = entries[id]?.view, !(v is PlaceholderBlockView),
                          v.block.payload == block.payload {
                    // The pooled view may only be measured when it already
                    // renders THIS payload. Tables are pooled by position, so
                    // after an edit the view still holds the previous table
                    // until `update()` runs — later in the same highlight
                    // pass. Measuring it then cached the old height under the
                    // new payload's key, and the band lagged one edit behind
                    // until the width changed.
                    let h = v.desiredHeight(for: width)
                    probeHeightCache[key] = h
                    out[block] = h
                } else {
                    let probe = makeRealView(for: block, identity: id)
                    let h = probe.desiredHeight(for: width)
                    probeHeightCache[key] = h
                    out[block] = h
                }
            case .mathBlock, .mermaid:
                // Webview height is reported async; reserve last-known
                // or a sensible default until the JS callback updates us.
                out[block] = blockHeights[id] ?? defaultHeight(for: block.kind)
            }
        }
        return out
    }

    /// Sync overlay views with the current set of blocks. Adds/removes
    /// views as needed and repositions all of them.
    func update(blocks: [ExtractedBlock], cursorActiveRanges: [NSRange]) {
        guard let textView = textView else { return }

        let ids = identities(for: blocks)
        let liveSet = computeLiveSet(blocks: blocks, ids: ids)

        // Remove views for identities that disappeared this pass.
        let presentIDs = Set(ids)
        for (id, entry) in entries where !presentIDs.contains(id) {
            (entry.view as? WebViewBlockView)?.tearDownWebView()
            entry.view.removeFromSuperview()
            entries.removeValue(forKey: id)
            blockHeights.removeValue(forKey: id)
        }

        // Create / promote / demote / reuse.
        for (i, block) in blocks.enumerated() {
            let id = ids[i]
            let needsLive = liveSet.contains(id)
            let existing = entries[id]?.view
            let isPlaceholder = existing is PlaceholderBlockView
            let isRealKind: Bool
            switch block.kind {
            case .table, .image: isRealKind = true   // always real
            case .mathBlock, .mermaid: isRealKind = needsLive
            }
            let needsRecreation = existing == nil
                || (isRealKind && isPlaceholder)
                || (!isRealKind && existing != nil && !isPlaceholder)
            if needsRecreation {
                (existing as? WebViewBlockView)?.tearDownWebView()
                existing?.removeFromSuperview()
                let v: BlockAttachmentView
                if isRealKind {
                    v = makeRealView(for: block, identity: id)
                } else {
                    v = PlaceholderBlockView(block: block, documentURL: documentURL)
                }
                v.autoresizingMask = []
                entries[id] = Entry(view: v, block: block)
                textView.addSubview(v)
            } else {
                // Reuse: same identity, possibly shifted range and — for
                // position-keyed tables/images — possibly changed content.
                // Push both, so `reposition()` follows the edit and the view
                // repaints, with no teardown and no WKWebView respawn.
                entries[id]?.block = block
                entries[id]?.view.block = block
            }
        }

        // Rebind the table interaction closures on EVERY pass, each capturing
        // the block as it is right now. A closure bound once at creation would
        // keep handing out a stale range after any edit above the table.
        for (_, entry) in entries {
            guard let table = entry.view as? TableBlockView else { continue }
            let current = entry.block
            table.onEditCell = { [weak self, weak table] row, col, rect in
                guard let table else { return }
                self?.onEditTableCell?(current, row, col, rect, table)
            }
            table.onCollapseToSource = { [weak self] in
                self?.onCollapseBlockToSource?(current)
            }
        }

        // Hide views whose (current) range overlaps a cursor-active range.
        for (_, entry) in entries {
            // Must be the SAME predicate the highlighter uses to decide
            // whether to conceal the block (SyntaxHighlighter, block loop).
            // They used to differ by one character of fuzz, which left the
            // overlay drawn on top of un-concealed source.
            let active = cursorActiveRanges.contains { $0.touchesBlock(entry.block.range) }
            entry.view.isHidden = active
        }

        lastBlocks = blocks
        lastCursorActiveRanges = cursorActiveRanges
        reposition()
    }

    /// Re-run the live-set computation against the *current* viewport
    /// without re-extracting blocks. Cheap to call on scroll — promotes
    /// blocks that just entered the viewport buffer from
    /// `PlaceholderBlockView` to a real `WebViewBlockView`, and demotes
    /// blocks that just left. Caller should debounce (~150 ms idle) so
    /// fast-scroll doesn't thrash WKWebView spawn/teardown.
    func refreshLiveSet() {
        guard !lastBlocks.isEmpty else { return }
        update(blocks: lastBlocks, cursorActiveRanges: lastCursorActiveRanges)
    }

    /// Position all overlay views to match their (current) text ranges.
    func reposition() {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let storageLength = textView.textStorage?.length ?? 0
        // Same width the heights were measured at — see `resolvedContentWidth()`.
        guard let width = resolvedContentWidth() else { return }
        for (_, entry) in entries {
            let r = entry.block.range
            guard r.location + r.length <= storageLength else {
                entry.view.isHidden = true
                continue
            }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard glyphRange.length > 0 else {
                entry.view.isHidden = true
                continue
            }
            let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let inset = textView.textContainerInset
            let pad = EditorLayout.blockOverlayHeightPadding
            let frame = NSRect(
                x: bounding.minX + inset.width,
                y: bounding.minY + inset.height + pad / 2,
                width: width,
                height: max(40, bounding.height - pad)
            )
            entry.view.frame = frame
        }
    }

    /// Forget all overlays (e.g. when the document changes drastically).
    func clear() {
        for (_, entry) in entries {
            (entry.view as? WebViewBlockView)?.tearDownWebView()
            entry.view.removeFromSuperview()
        }
        entries.removeAll()
        blockHeights.removeAll()
        probeHeightCache.removeAll()
    }

    // MARK: - Live-set computation

    /// Pick the webview-backed blocks that should be rendered as real
    /// (vs. as `PlaceholderBlockView`) on this pass, returning their
    /// identities. Tables and images are always real — they're cheap.
    /// Math/mermaid get the lazy treatment.
    private func computeLiveSet(blocks: [ExtractedBlock], ids: [BlockIdentity]) -> Set<BlockIdentity> {
        var result = Set<BlockIdentity>()

        let webViewKinds: Set<BlockKind> = [.mathBlock, .mermaid]
        // Pair each web block with its identity, preserving doc order.
        let webBlocks: [(block: ExtractedBlock, id: BlockIdentity)] = zip(blocks, ids)
            .filter { webViewKinds.contains($0.0.kind) }
            .map { ($0.0, $0.1) }

        guard let viewport = currentViewportCharRange() else {
            // Layout not ready: keep first N as live, rest as placeholders.
            for b in webBlocks.prefix(maxLiveWebViews) { result.insert(b.id) }
            return result
        }

        // Score each web-block by distance to the viewport (0 = fully inside).
        struct Scored { let id: BlockIdentity; let distance: Int }
        let viewportEnd = viewport.location + viewport.length
        let scored: [Scored] = webBlocks.map { pair in
            let start = pair.block.range.location
            let end = pair.block.range.location + pair.block.range.length
            let distance: Int
            if end < viewport.location {
                distance = viewport.location - end
            } else if start > viewportEnd {
                distance = start - viewportEnd
            } else {
                distance = 0
            }
            return Scored(id: pair.id, distance: distance)
        }
        // Sort by distance, take top N.
        let sorted = scored.sorted { $0.distance < $1.distance }
        for s in sorted.prefix(maxLiveWebViews) {
            result.insert(s.id)
        }
        return result
    }

    private func currentViewportCharRange() -> NSRange? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let visible = textView.visibleRect
        guard visible.height > 0 else { return nil }
        // Expand by buffer factor so blocks just off-screen also stay live.
        let expanded = visible.insetBy(dx: 0,
                                        dy: -visible.height * viewportLiveBufferMultiplier)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: expanded,
                                                    in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange,
                                              actualGlyphRange: nil)
    }

    // MARK: - Real-view factory

    private func makeRealView(for block: ExtractedBlock, identity: BlockIdentity) -> BlockAttachmentView {
        let view: BlockAttachmentView
        switch block.kind {
        case .table:
            view = TableBlockView(block: block, documentURL: documentURL)
        case .image:
            view = ImageBlockView(block: block, documentURL: documentURL)
        case .mathBlock:
            let v = MathBlockView(block: block, documentURL: documentURL)
            v.onHeightChange = { [weak self] newHeight in
                self?.blockHeights[identity] = newHeight
                self?.notifyHeightChange()
            }
            view = v
        case .mermaid:
            let v = MermaidBlockView(block: block, documentURL: documentURL)
            v.onHeightChange = { [weak self] newHeight in
                self?.blockHeights[identity] = newHeight
                self?.notifyHeightChange()
            }
            view = v
        }
        view.autoresizingMask = []
        return view
    }

    private func defaultHeight(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .table: return EditorBlockDefaults.table
        case .image: return EditorBlockDefaults.image
        case .mathBlock: return EditorBlockDefaults.mathBlock
        case .mermaid: return EditorBlockDefaults.mermaid
        }
    }

    /// Called when an async-loading block (math/mermaid) reports a new
    /// height after rendering. We need to ask the highlighter to reserve
    /// more line-height so the overlay isn't clipped.
    var heightChangeHandler: (() -> Void)?

    /// A rendered table cell was clicked: (block, row, col, cell rect, view).
    /// `row == -1` is the header band.
    var onEditTableCell: ((ExtractedBlock, Int, Int, NSRect, TableBlockView) -> Void)?
    /// The user asked to edit a block as raw markdown (double-click on the
    /// table chrome, or a block that no longer parses as a table).
    var onCollapseBlockToSource: ((ExtractedBlock) -> Void)?

    /// The overlay view currently rendering `block`, if any.
    ///
    /// Looked up by the block's position in the document, NOT by recomputing
    /// an identity from the block alone: identities carry an ordinal counted
    /// across the whole document, so deriving one from a single-element array
    /// always yields ordinal 0 and would hand back the first table in the
    /// file no matter which one was asked for.
    func view(for block: ExtractedBlock) -> BlockAttachmentView? {
        entries.values.first {
            $0.block.kind == block.kind && $0.block.range.location == block.range.location
        }?.view
    }

    private func notifyHeightChange() {
        heightChangeHandler?()
    }

    // MARK: - Test seams

    /// Test-only: number of pooled overlay views.
    var pooledViewCountForTesting: Int { entries.count }

    /// Test-only: the single width used for BOTH measuring and drawing.
    /// Exposed so a test can assert the two never diverge again.
    var contentWidthForTesting: CGFloat { resolvedContentWidth() ?? 0 }

    /// Test-only: number of entries currently held in the height cache.
    var probeCacheCountForTesting: Int { probeHeightCache.count }

    /// Test-only: the overlay view currently rendering the given block's
    /// content identity, or nil. Lets tests assert view reuse vs.
    /// recreation across edits.
    func pooledViewForTesting(matching block: ExtractedBlock) -> BlockAttachmentView? {
        view(for: block)
    }
}
