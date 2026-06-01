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
    var documentURL: URL?

    /// Stable identity for a block across range shifts. `ordinal`
    /// disambiguates two byte-identical blocks (e.g. two `$$x$$`) so
    /// editing above the second doesn't make it adopt the first's view.
    private struct BlockIdentity: Hashable {
        let kind: BlockKind
        let payload: String
        let ordinal: Int
    }

    /// One pooled overlay: the view plus the block it currently renders.
    /// The view's own `block` is immutable (set at creation, content is
    /// payload-stable for a given identity); `block` here tracks the
    /// *current* range so `reposition()` follows edits without recreating.
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

    /// Height cache for synchronously-measurable blocks (table, image).
    /// Keyed on (kind, payload) so the result survives range shifts.
    private struct ProbeKey: Hashable {
        let kind: BlockKind
        let payload: String
    }
    private var probeHeightCache: [ProbeKey: CGFloat] = [:]
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
    private func identities(for blocks: [ExtractedBlock]) -> [BlockIdentity] {
        var counts: [ProbeKey: Int] = [:]
        return blocks.map { b in
            let key = ProbeKey(kind: b.kind, payload: b.payload)
            let ordinal = counts[key, default: 0]
            counts[key] = ordinal + 1
            return BlockIdentity(kind: b.kind, payload: b.payload, ordinal: ordinal)
        }
    }

    // MARK: - Public API

    /// Compute desired heights for every block, so the highlighter can
    /// reserve enough vertical space (via min-line-height) before the
    /// overlay views are positioned on top.
    func desiredHeights(for blocks: [ExtractedBlock], width: CGFloat) -> [ExtractedBlock: CGFloat] {
        guard width > 0 else { return [:] }
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
                if let v = entries[id]?.view, !(v is PlaceholderBlockView) {
                    v.frame.size.width = width
                    let h = v.desiredHeight(for: width)
                    probeHeightCache[ProbeKey(kind: block.kind, payload: block.payload)] = h
                    out[block] = h
                } else {
                    let key = ProbeKey(kind: block.kind, payload: block.payload)
                    if let cached = probeHeightCache[key] {
                        out[block] = cached
                    } else {
                        let probe = makeRealView(for: block, identity: id)
                        probe.frame.size.width = width
                        let h = probe.desiredHeight(for: width)
                        probeHeightCache[key] = h
                        out[block] = h
                    }
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
                // Reuse: same content, possibly shifted range. Update the
                // tracked block so reposition() follows the edit — no
                // teardown, no WKWebView respawn.
                entries[id]?.block = block
            }
        }

        // Hide views whose (current) range overlaps a cursor-active range.
        for (_, entry) in entries {
            let active = cursorActiveRanges.contains { intersects($0, entry.block.range) }
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
            let frame = NSRect(
                x: bounding.minX + inset.width,
                y: bounding.minY + inset.height + 2,
                width: max(EditorLayout.blockOverlayMinWidth, bounding.width - 4),
                height: max(40, bounding.height - 6)
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

    private func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location <= bEnd && b.location <= aEnd
    }

    /// Called when an async-loading block (math/mermaid) reports a new
    /// height after rendering. We need to ask the highlighter to reserve
    /// more line-height so the overlay isn't clipped.
    var heightChangeHandler: (() -> Void)?

    private func notifyHeightChange() {
        heightChangeHandler?()
    }

    // MARK: - Test seams

    /// Test-only: number of pooled overlay views.
    var pooledViewCountForTesting: Int { entries.count }

    /// Test-only: the overlay view currently rendering the given block's
    /// content identity, or nil. Lets tests assert view reuse vs.
    /// recreation across edits.
    func pooledViewForTesting(matching block: ExtractedBlock) -> BlockAttachmentView? {
        let id = identities(for: [block]).first
        return id.flatMap { entries[$0]?.view }
    }
}
