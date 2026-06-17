import SwiftUI
import AppKit
import os

/// Token signalling the editor to scroll/jump to a particular range.
/// We use a UUID so consecutive jumps to the same range still trigger.
struct EditorJumpToken: Equatable {
    let id = UUID()
    let location: Int
    let length: Int
    var range: NSRange { NSRange(location: location, length: length) }

    init(_ range: NSRange) {
        self.location = range.location
        self.length = range.length
    }

    static func == (lhs: EditorJumpToken, rhs: EditorJumpToken) -> Bool {
        lhs.id == rhs.id
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var jumpToken: EditorJumpToken?
    /// Optional outbound binding: the editor reports the current
    /// caret location whenever the selection changes. The outline
    /// sidebar uses this to auto-highlight the heading the user is
    /// currently editing.
    var cursorLocation: Binding<Int>? = nil
    var theme: EditorTheme = .default
    /// When `true`, every paragraph except the one containing the
    /// caret is rendered with `0.3` foreground alpha — a "spotlight"
    /// reading aid. Toggled via the Focus Mode menu / `⌃⌘F`.
    var focusMode: Bool = false
    /// When `true`, every cursor-position change scrolls the
    /// `NSScrollView` so the caret line lands at the vertical centre
    /// of the viewport. Toggled via the Typewriter Mode menu / `⌃⌘Y`.
    var typewriterMode: Bool = false
    /// Find/replace bar state for this window. Matching + highlight drawing
    /// + navigation/replace are driven by the Coordinator; the bar UI and
    /// the Find menu talk to the same `SearchModel`.
    var search: SearchModel? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = PicaMDTextView.makeScrollable()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        // Font is set by applyTheme(...) below from the active theme — no
        // literal default here (it would be dead-overwritten in this same
        // call frame and is a third, disagreeing "base size" source).
        textView.textContainerInset = NSSize(width: EditorLayout.textContainerInsetWidth,
                                             height: EditorLayout.textContainerInsetHeight)
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        // PicaMD ships its own Markdown-aware find bar (see SearchModel /
        // SearchBarView / FindCommands), so the stock NSTextView find bar
        // is disabled: it can't see through the editor's marker
        // concealment, and leaving it on would double-bind ⌘F.
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.isIncrementalSearchingEnabled = false

        textView.string = text
        context.coordinator.seedTextMirror(text)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.search = search
        context.coordinator.isDark = textView.effectiveAppearance.isDark
        context.coordinator.highlighter.theme = theme
        applyTheme(theme, to: scrollView, textView: textView)

        // Wire up the block overlay manager
        let blockManager = BlockOverlayManager()
        blockManager.textView = textView
        blockManager.heightChangeHandler = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleHighlight(delay: 0)
        }
        context.coordinator.blockManager = blockManager

        // Wire up the inline-checkbox overlay manager. The toggle
        // closure flips the source `[ ]` ↔ `[x]` via NSTextStorage so
        // the change goes through the standard undo path; a follow-up
        // highlight pass then refreshes the strikethrough + overlay.
        let checkboxManager = CheckboxOverlayManager()
        checkboxManager.textView = textView
        checkboxManager.theme = theme
        checkboxManager.onToggle = { [weak coordinator = context.coordinator] range, newState in
            coordinator?.toggleCheckbox(at: range, to: newState)
        }
        context.coordinator.checkboxManager = checkboxManager

        // Listen for live scroll changes so overlays follow the viewport.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        textView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.documentWillWrite(_:)),
            name: .picaMDDocumentWillWrite,
            object: nil
        )

        context.coordinator.applyHighlightingNow()
        context.coordinator.startObservingAppearance()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            context.coordinator.seedTextMirror(text)
            let total = (text as NSString).length
            let location = min(selection.location, total)
            let length = min(selection.length, total - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            context.coordinator.applyHighlightingNow()
        }

        let isDark = scrollView.effectiveAppearance.isDark
        if context.coordinator.isDark != isDark {
            context.coordinator.isDark = isDark
            context.coordinator.applyHighlightingNow()
        }

        // Live theme update. Markup structure is unchanged — only colours
        // and fonts — so repaint progressively (viewport first, rest in
        // background chunks) instead of one blocking full-document pass.
        if context.coordinator.highlighter.theme != theme {
            context.coordinator.highlighter.theme = theme
            applyTheme(theme, to: scrollView, textView: textView)
            context.coordinator.applyThemeChangeProgressively()
        }

        // Live mode-flag updates (Focus / Typewriter). The focus dim is
        // already viewport-scoped, so toggling it does NOT need a full
        // regex re-highlight (which froze large docs). Turning OFF just
        // restores the stashed pre-dim colours doc-wide (cheap attribute
        // walk) then repaints the viewport.
        if context.coordinator.focusMode != focusMode {
            context.coordinator.focusMode = focusMode
            if focusMode {
                context.coordinator.applyHighlightingNow()
            } else {
                context.coordinator.removeFocusDimAndRepaint()
            }
        }
        if context.coordinator.typewriterMode != typewriterMode {
            context.coordinator.typewriterMode = typewriterMode
            if typewriterMode {
                context.coordinator.scrollCaretToVerticalCenter()
            }
        }

        // Honour an outside-triggered jump (e.g. from the outline sidebar).
        if let token = jumpToken, token != context.coordinator.lastConsumedJumpToken {
            context.coordinator.lastConsumedJumpToken = token
            applyJump(to: token.range, in: textView)
            // Reset binding so subsequent jumps to the same range still trigger.
            DispatchQueue.main.async {
                self.jumpToken = nil
            }
        }

        // Find/replace bar: react to query/option/open changes + one-shot
        // commands (next / previous / replace / use-selection). Deferred to
        // the next main-actor tick so reporting counts back to the model
        // doesn't mutate observable state mid-SwiftUI-update.
        let coordinator = context.coordinator
        coordinator.search = search
        Task { @MainActor in coordinator.syncSearch() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Apply background colours, insertion-point colour, and base font
    /// derived from the theme. Called once on creation and on every
    /// theme change.
    private func applyTheme(_ theme: EditorTheme, to scrollView: NSScrollView, textView: NSTextView) {
        let bg = theme.palette.bg
        scrollView.backgroundColor = bg
        textView.backgroundColor = bg
        textView.insertionPointColor = theme.palette.fg
        textView.textColor = theme.palette.fg
        textView.font = theme.bodyFont.font(size: theme.fontBaseSize)
    }

    private func applyJump(to range: NSRange, in textView: NSTextView) {
        let total = (textView.string as NSString).length
        guard total > 0 else { return }
        let safeLoc = max(0, min(range.location, total))
        let safeRange = NSRange(location: safeLoc, length: 0)
        textView.scrollRangeToVisible(safeRange)
        textView.setSelectedRange(safeRange)
        textView.window?.makeFirstResponder(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        let highlighter = SyntaxHighlighter()
        var blockManager: BlockOverlayManager?
        var checkboxManager: CheckboxOverlayManager?
        let fileWatcher = FileWatcher()
        var isDark: Bool = false
        var lastConsumedJumpToken: EditorJumpToken?
        /// Mirror of the parent view's mode flags. Stored on the
        /// coordinator so `textViewDidChangeSelection` (which runs on
        /// every cursor move) can read them without going through the
        /// SwiftUI binding.
        var focusMode: Bool = false
        var typewriterMode: Bool = false
        private var debounceTask: Task<Void, Never>?
        /// Debounce for scroll-driven re-evaluation of the lazy-render
        /// live set. Fast scroll fires `boundsDidChangeNotification` ~60
        /// times/second; we only need to recompute which math/mermaid
        /// blocks should be live-rendered after the user stops moving.
        private var liveSetRefreshTask: Task<Void, Never>?
        private var appearanceObservation: NSKeyValueObservation?
        private var lastDocumentURL: URL?
        private var pendingReloadAlert: Bool = false
        /// Token for the per-window close observer that unregisters the
        /// document from the MCP registry. Set once the window is known.
        private var windowCloseObserver: NSObjectProtocol?
        /// Lock-protected mirror of the editor's current text, kept in
        /// sync on every change. `documentWillWrite` (nonisolated, fires
        /// on the save queue) reads this SYNCHRONOUSLY to decide whether
        /// the impending write is ours — without it we'd have to hop to
        /// the main actor, which races the vnode event and lets our own
        /// save surface as a spurious external-change alert.
        private let currentTextMirror = OSAllocatedUnfairLock<String>(initialState: "")
        // Initial highlight pass is viewport-only too — saves 400+ ms
        // on a 10k-line cold-open. The textView's own textColor /
        // backgroundColor / font already covers off-viewport chars
        // with the right baseline; only headings/inline markup need
        // the highlighter's styling, and only the visible ones do.
        private var needsFullHighlight: Bool = false

        // MARK: - Find-bar state
        /// The active window's search model (same instance the bar + Find
        /// menu use). Set on creation and on each `updateNSView`.
        var search: SearchModel?
        /// Last values seen from the model, to detect what changed between
        /// SwiftUI re-renders.
        private var lastSearchQuery: String = ""
        private var lastSearchOptions = SearchOptions()
        private var lastSearchOpen = false
        private var lastConsumedActionToken: UUID?
        /// Current match set, document order. Mirrored into the text view
        /// for drawing.
        private var searchMatches: [NSRange] = []
        /// 1-based index of the current match; 0 = none.
        private var currentMatchIndex = 0
        private var searchRefreshTask: Task<Void, Never>?

        init(parent: MarkdownTextView) {
            self.parent = parent
            super.init()
            fileWatcher.onExternalChange = { [weak self] event in
                self?.handleExternalFileChange(event)
            }
        }

        deinit {
            appearanceObservation?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - External-file-change handling

        private func handleExternalFileChange(_ event: FileWatcher.Event) {
            guard let textView = textView, let window = textView.window else { return }
            guard !pendingReloadAlert else { return }
            pendingReloadAlert = true

            switch event {
            case .modified:
                let alert = NSAlert()
                alert.messageText = "File changed on disk"
                alert.informativeText = "The file was modified by another program. Reload from disk and discard your unsaved changes?"
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Keep mine")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window) { [weak self] response in
                    self?.pendingReloadAlert = false
                    guard let self = self,
                          response == .alertFirstButtonReturn,
                          let url = self.lastDocumentURL,
                          let new = try? String(contentsOf: url, encoding: .utf8) else { return }
                    self.applyExternalReload(text: new)
                    // Re-attach the vnode watcher to the (possibly
                    // newly-created) inode at this path. Without this,
                    // an atomic save by another editor swaps the file
                    // out from under our open file descriptor and we
                    // stop seeing further changes.
                    self.fileWatcher.startWatching(url)
                }
            case .renamedOrDeleted:
                let alert = NSAlert()
                alert.messageText = "File renamed or deleted"
                alert.informativeText = "The file is no longer at its original location. Your edits remain in this window — save again to write them back to a new path."
                alert.addButton(withTitle: "OK")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window) { [weak self] _ in
                    self?.pendingReloadAlert = false
                    // Re-attach in case the path now points at a fresh
                    // inode again (e.g. someone created a replacement).
                    if let self = self, let url = self.lastDocumentURL {
                        self.fileWatcher.startWatching(url)
                    }
                }
            }
        }

        private func applyExternalReload(text: String) {
            guard let textView = textView else { return }
            // Replace storage atomically; the SwiftUI binding update will
            // also fire via textDidChange.
            let selection = textView.selectedRange()
            textView.string = text
            parent.text = text
            currentTextMirror.withLock { $0 = text }
            let total = (text as NSString).length
            let location = min(selection.location, total)
            let length = min(selection.length, total - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            invalidateFullHighlight()
            applyHighlightingNow()
        }

        /// Flip a task-list checkbox's source representation between
        /// `[ ]` and `[x]`. Called from the overlay view's mouse-down.
        /// Routes the edit through `NSTextView.shouldChangeText(...)`
        /// so undo works and the SwiftUI text binding syncs via
        /// `textDidChange`. The caller's caret position is preserved
        /// — clicking a checkbox shouldn't move the cursor.
        func toggleCheckbox(at range: NSRange, to checked: Bool) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            guard range.length == 3, range.location + range.length <= storage.length else { return }
            // STALE-RANGE GUARD. The overlay's onToggle closure captures the
            // boxRange from the last highlight pass. Highlighting is debounced
            // (~50 ms), so a fast click after typing/deleting elsewhere — or
            // after an external reload replaced the buffer — can fire with a
            // boxRange that no longer points at a checkbox. Without this check
            // we'd splice `[x]` over 3 chars of arbitrary prose (an undoable
            // corruption). Verify the target still holds a checkbox; if not,
            // re-bind the overlay closures and drop this click.
            let current = (storage.string as NSString).substring(with: range)
            guard current == "[ ]" || current.lowercased() == "[x]" else {
                applyHighlightingNow()
                return
            }
            let replacement = checked ? "[x]" : "[ ]"
            let savedSelection = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                storage.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            let total = storage.length
            let safeLoc = min(savedSelection.location, total)
            let safeLen = min(savedSelection.length, max(0, total - safeLoc))
            textView.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
        }

        @objc func scrollDidChange(_ note: Notification) {
            // Cheap: just slide the existing overlay frames to follow the
            // glyph rects. Runs every tick during scroll.
            blockManager?.reposition()
            checkboxManager?.reposition()

            // Expensive: re-evaluate which math/mermaid blocks should be
            // live-rendered (real WKWebView) vs placeholder. Debounce so
            // we only do it once after the user stops moving — otherwise
            // fast-scroll thrashes WKWebView spawn/teardown.
            liveSetRefreshTask?.cancel()
            liveSetRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(EditorTiming.lazyLiveSetDebounceMs))
                if Task.isCancelled { return }
                self?.blockManager?.refreshLiveSet()
            }
        }

        @objc func frameDidChange(_ note: Notification) {
            scheduleHighlight(delay: EditorTiming.frameChangeHighlightDebounceMs)
        }

        /// Posted by `MarkdownDocument.fileWrapper(_:)` which runs on a
        /// background queue during save. We must hop to the main actor
        /// before touching any of this @MainActor-isolated coordinator's
        /// state — otherwise Swift's strict-concurrency runtime check
        /// trips and the app crashes with `_dispatch_assert_queue_fail`.
        @objc nonisolated func documentWillWrite(_ note: Notification) {
            // The notification is broadcast app-wide. Filter it by
            // matching the payload's text against THIS coordinator's
            // current buffer so a save in window A doesn't mute the
            // file-watcher of window B (which would let an external
            // edit to B sneak past the reload alert and get silently
            // overwritten on B's next save — F2 in the adversarial
            // review).
            //
            // Done SYNCHRONOUSLY against a lock-protected text mirror
            // rather than hopping to the main actor: the write happens on
            // a background save queue and the resulting vnode event fires
            // on `.main`; a `Task { @MainActor }` to call noteSelfWrite
            // could be scheduled AFTER that event, so our own save would
            // surface as a spurious "file changed on disk" alert.
            guard let writtenText = note.userInfo?[MarkdownDocument.willWriteTextKey] as? String
            else {
                fileWatcher.noteSelfWrite()   // no payload to match — assume ours
                return
            }
            if currentTextMirror.withLock({ $0 }) == writtenText {
                fileWatcher.noteSelfWrite()   // our save — suppress the next vnode event
                // Re-index Spotlight with the bytes that just hit disk.
                // Indexing only ran once at open before, so frontmatter
                // title/tag edits stayed stale in Spotlight until reopen.
                // Not latency-critical (unlike noteSelfWrite), so a hop to
                // the main actor for `lastDocumentURL` is fine here.
                Task { @MainActor [weak self] in
                    guard let self = self, let url = self.lastDocumentURL else { return }
                    SpotlightIndexer.index(url: url, source: writtenText)
                }
            }
            // else: a different window's save — leave our watcher armed.
        }

        /// Observe the document window's close so we can deterministically
        /// unregister from the MCP active-documents registry while `self`
        /// is still alive on the main actor (the nonisolated deinit can't
        /// touch main-actor state under Swift 6). Reads `lastDocumentURL`
        /// at close time so a Save-As before closing unregisters the
        /// current path, not the one open at window-creation.
        private func installWindowCloseObserverIfNeeded(for textView: NSTextView) {
            guard windowCloseObserver == nil, let window = textView.window else { return }
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if let url = self.lastDocumentURL {
                        ActiveDocumentsRegistry.shared.unregister(url: url)
                    }
                    // Self-remove: the window is gone, the observer has
                    // done its one job.
                    if let token = self.windowCloseObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.windowCloseObserver = nil
                    }
                }
            }
        }

        func startObservingAppearance() {
            guard let textView = textView else { return }
            appearanceObservation = textView.observe(\.effectiveAppearance, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    let nowDark = view.effectiveAppearance.isDark
                    if self.isDark != nowDark {
                        self.isDark = nowDark
                        // System dark-mode flip: same as a theme change —
                        // progressive repaint, no full-doc freeze.
                        self.applyThemeChangeProgressively()
                    }
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let str = textView.string
            parent.text = str
            currentTextMirror.withLock { $0 = str }
            scheduleHighlight(delay: EditorTiming.highlightDebounceMs)
            scheduleSearchRefresh()
        }

        /// Seed the lock-protected text mirror when the buffer is set
        /// programmatically (initial load, external reload, binding push)
        /// rather than via user typing. Keeps `documentWillWrite`'s
        /// self-write detection accurate before the first edit.
        func seedTextMirror(_ text: String) {
            currentTextMirror.withLock { $0 = text }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Re-render concealment based on the new cursor position.
            // Slightly faster debounce so the user sees the markup expand
            // immediately when stepping into a span.
            scheduleHighlight(delay: EditorTiming.cursorMoveHighlightDebounceMs)
            // Push cursor location upstream (outline auto-highlight).
            if let textView = textView, let binding = parent.cursorLocation {
                let loc = textView.selectedRange().location
                if binding.wrappedValue != loc {
                    binding.wrappedValue = loc
                }
            }
            // Typewriter mode: keep the caret line at viewport mid-height.
            if typewriterMode {
                scrollCaretToVerticalCenter()
            }
        }

        /// Scroll so the caret-glyph rect lands at the vertical centre
        /// of the scroll view's viewport. Called from
        /// `textViewDidChangeSelection` whenever Typewriter Mode is on,
        /// and once when the user toggles Typewriter Mode on so the
        /// initial caret position immediately re-centres.
        func scrollCaretToVerticalCenter() {
            guard let textView = textView,
                  let scrollView = scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let cursor = textView.selectedRange()
            // Cursor index can land on a zero-width glyph at end of line —
            // probe a 1-char range so we get a visible bounding rect.
            let probeRange = NSRange(location: cursor.location,
                                      length: cursor.length > 0 ? cursor.length : 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: probeRange,
                                                       actualCharacterRange: nil)
            let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                       in: textContainer)
            let inset = textView.textContainerInset
            let lineMidY = bounding.minY + inset.height + bounding.height / 2

            let viewportHeight = scrollView.contentView.bounds.height
            // Target: line centre should align with viewport centre.
            let targetY = max(0, lineMidY - viewportHeight / 2)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Background sweep that repaints the off-screen part of the doc
        /// with a new theme/appearance, chunk by chunk, after the visible
        /// viewport has already been repainted. Cancelled by any edit or
        /// cursor move (via `scheduleHighlight`).
        private var progressiveHighlightTask: Task<Void, Never>?

        func scheduleHighlight(delay: Int = 50) {
            // Any user activity supersedes an in-flight theme sweep: the
            // normal viewport highlight takes over, and off-screen chunks
            // catch up to the new theme as they scroll into view.
            progressiveHighlightTask?.cancel()
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.applyHighlightingNow()
            }
        }

        /// Re-highlight the whole document for a theme / dark-mode change
        /// WITHOUT freezing on large docs. The visible viewport is
        /// repainted synchronously (instant feedback), then the rest of
        /// the document is swept in newline-aligned chunks that yield to
        /// the runloop between each, so typing and scrolling stay live.
        /// The full-document block scans are memoised (see F3), so each
        /// chunk only pays for its own inline passes.
        func applyThemeChangeProgressively() {
            progressiveHighlightTask?.cancel()
            guard let textView = textView, let storage = textView.textStorage else { return }
            let total = storage.length
            guard total > 0 else { return }

            // 1. Visible viewport first — the user sees the new theme now.
            needsFullHighlight = false
            applyHighlightingNow()

            // 2. Sweep the remainder in background-yielded chunks.
            let source = textView.string
            let (blocks, taskMatches, _) = textDerivedScans(for: source)
            let availableWidth = max(120, textView.bounds.width
                                     - textView.textContainerInset.width * 2 - 16)
            let heights = blockManager?.desiredHeights(for: blocks, width: availableWidth) ?? [:]
            let chunkSize = EditorBuffer.progressiveChunkChars
            let cursor = textView.selectedRange()
            let dark = isDark
            let focus = focusMode
            let ns = source as NSString

            progressiveHighlightTask = Task { @MainActor [weak self] in
                var loc = 0
                while loc < total {
                    if Task.isCancelled { return }
                    guard let self = self, let storage = self.textView?.textStorage else { return }
                    let len = storage.length
                    if loc >= len { return }   // text shrank — bail
                    // Snap the chunk end to the next newline so an inline
                    // construct (**bold**, `code`, …) is never split.
                    var end = min(loc + chunkSize, len)
                    if end < len {
                        let nl = ns.range(of: "\n", options: [],
                                          range: NSRange(location: end, length: ns.length - end))
                        end = (nl.location != NSNotFound) ? nl.location + 1 : len
                    }
                    end = min(end, len)
                    let chunk = NSRange(location: loc, length: max(0, end - loc))
                    if chunk.length > 0 {
                        self.highlighter.highlight(
                            textStorage: storage,
                            isDark: dark,
                            cursorRange: cursor,
                            blocks: blocks,
                            blockHeights: heights,
                            viewportRange: chunk,
                            focusMode: focus,
                            taskMatches: taskMatches
                        )
                    }
                    loc = end
                    await Task.yield()
                }
            }
        }

        func applyHighlightingNow() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            let cursor = textView.selectedRange()

            // Pick up the document's file URL for relative-path resolution
            // (used by ImageBlockView) and start watching for external edits.
            // Update on every pass since the window's representedURL may
            // not be set when makeNSView runs.
            if let url = textView.window?.representedURL, url != lastDocumentURL {
                // Save-As / representedURL change: drop the stale entry so
                // the registry doesn't double-count the old + new path.
                if let old = lastDocumentURL {
                    ActiveDocumentsRegistry.shared.unregister(url: old)
                }
                lastDocumentURL = url
                blockManager?.documentURL = url
                fileWatcher.startWatching(url)
                if let qmdView = textView as? PicaMDTextView {
                    qmdView.documentURL = url
                }
                // Push frontmatter title + tags + body preview to
                // Spotlight so PicaMD-known files show up with smart
                // metadata instead of the generic plain-text snippet.
                SpotlightIndexer.index(url: url, source: textView.string)
                // Tell the MCP-sidecar (`picamd-mcp`) the user has
                // this document open. It shows up in the sidecar's
                // `workspace.openDocuments` tool result so Claude Code
                // can read/search/edit it through MCP.
                ActiveDocumentsRegistry.shared.register(url: url)
                // Record for the welcome window's recents list (DocumentGroup
                // doesn't maintain NSDocumentController.recentDocumentURLs).
                RecentDocumentsStore.add(url)
                installWindowCloseObserverIfNeeded(for: textView)
            }

            let source = textView.string
            // Block extraction, task-list matches and protected ranges are
            // all full-document scans derived purely from the text. They
            // can't change unless the text changes, so memoise them by
            // source — a cursor move (the 16 ms-debounced hot path) reuses
            // the cache instead of re-scanning the whole document three
            // more times.
            let (blocks, taskMatches, protectedRanges) = textDerivedScans(for: source)
            let availableWidth = max(120, textView.bounds.width
                                     - textView.textContainerInset.width * 2 - 16)
            let heights = blockManager?.desiredHeights(for: blocks, width: availableWidth) ?? [:]

            // Incremental highlight: only re-attribute the visible viewport
            // (plus a generous buffer) on edits/cursor-moves. Off-screen
            // attributes keep their last state, which is correct because
            // the buffer covers any markup that crosses the viewport edge.
            // First pass per session is full-doc so every char gets a base
            // font + foreground colour.
            let viewport = needsFullHighlight ? nil : computeViewportCharRange()
            needsFullHighlight = false

            highlighter.highlight(
                textStorage: storage,
                isDark: isDark,
                cursorRange: cursor,
                blocks: blocks,
                blockHeights: heights,
                viewportRange: viewport,
                focusMode: focusMode,
                taskMatches: taskMatches
            )
            blockManager?.update(blocks: blocks, cursorActiveRanges: [cursor])

            // Inline-checkbox overlays. `protectedRanges` keeps clickable
            // checkboxes off `- [ ]` lines inside ``` code or $$ math —
            // a click there would mutate the user's documented source.
            checkboxManager?.theme = highlighter.theme
            checkboxManager?.update(matches: taskMatches,
                                    cursorActiveRanges: [cursor],
                                    protectedRanges: protectedRanges)

            // Refresh footnote-tooltip index so hover-popovers stay in
            // sync with the source. Cheap (regex pass over the doc).
            if let qmdView = textView as? PicaMDTextView {
                qmdView.footnoteTooltip.updateIndex(from: source)
            }
        }

        /// Memoised text-derived scans (block overlays, task-list
        /// checkboxes, protected code/math ranges). Keyed on source
        /// identity so a cursor move reuses the cache; a text edit
        /// recomputes. See `textDerivedScans(for:)`.
        private var scanCacheSource: String?
        private var scanCacheBlocks: [ExtractedBlock] = []
        private var scanCacheTaskMatches: [TaskListMatch] = []
        private var scanCacheProtected: [NSRange] = []

        private func textDerivedScans(
            for source: String
        ) -> ([ExtractedBlock], [TaskListMatch], [NSRange]) {
            if scanCacheSource == source {
                return (scanCacheBlocks, scanCacheTaskMatches, scanCacheProtected)
            }
            let blocks = BlockExtractor.extract(from: source)
            let matches = CheckboxOverlayManager.extractMatches(from: source)
            let protectedRanges = CheckboxOverlayManager.protectedRanges(in: source)
            scanCacheSource = source
            scanCacheBlocks = blocks
            scanCacheTaskMatches = matches
            scanCacheProtected = protectedRanges
            return (blocks, matches, protectedRanges)
        }

        /// Focus Mode turned off: restore the stashed pre-dim colours
        /// across the whole document (cheap, no regex) then repaint the
        /// viewport. Avoids the full-document re-highlight that the old
        /// `invalidateFullHighlight()` path forced on every focus toggle.
        func removeFocusDimAndRepaint() {
            if let storage = textView?.textStorage {
                highlighter.removeFocusDim(textStorage: storage)
            }
            applyHighlightingNow()
        }

        /// Forces the next `applyHighlightingNow()` call to re-highlight
        /// the entire document instead of only the visible viewport.
        /// Use after destructive changes (theme switch, dark-mode flip,
        /// large reload from disk).
        func invalidateFullHighlight() {
            needsFullHighlight = true
        }

        // MARK: - Find-bar logic

        /// Called from `updateNSView`: reconcile the editor with the
        /// model's current state. Handles open/close transitions,
        /// query/option edits, and one-shot commands.
        func syncSearch() {
            guard let search = search else { return }

            let openChanged = search.isOpen != lastSearchOpen
            lastSearchOpen = search.isOpen

            // Bar closed: clear highlights once, swallow any stray action.
            guard search.isOpen else {
                if openChanged { clearSearchHighlights() }
                lastConsumedActionToken = search.actionToken
                lastSearchQuery = search.query
                lastSearchOptions = search.options
                return
            }

            // One-shot command (next/prev/replace/use-selection) takes
            // priority — it carries a fresh, not-yet-consumed token.
            if search.actionToken != lastConsumedActionToken, let action = search.pendingAction {
                lastConsumedActionToken = search.actionToken
                lastSearchQuery = search.query
                lastSearchOptions = search.options
                performSearchAction(action)
                return
            }
            lastConsumedActionToken = search.actionToken

            let queryChanged = search.query != lastSearchQuery
            let optionsChanged = search.options != lastSearchOptions
            lastSearchQuery = search.query
            lastSearchOptions = search.options

            if openChanged || queryChanged || optionsChanged {
                runSearch(resetToNearest: true, scroll: true)
            }
        }

        private func performSearchAction(_ action: SearchModel.Action) {
            switch action {
            case .next: navigateSearch(by: 1)
            case .previous: navigateSearch(by: -1)
            case .replaceCurrent: replaceCurrentMatch()
            case .replaceAll: replaceAllMatches()
            case .useSelection:
                if let tv = textView {
                    let sel = tv.selectedRange()
                    if sel.length > 0, NSMaxRange(sel) <= (tv.string as NSString).length {
                        let s = (tv.string as NSString).substring(with: sel)
                        search?.setQuery(s)
                        lastSearchQuery = s
                    }
                }
                runSearch(resetToNearest: true, scroll: true)
            }
        }

        /// Light debounce so live edits with the bar open keep counts +
        /// highlights current without scrolling the doc on every keystroke.
        func scheduleSearchRefresh() {
            guard search?.isOpen == true else { return }
            searchRefreshTask?.cancel()
            searchRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled { return }
                self?.runSearch(resetToNearest: false, scroll: false)
            }
        }

        /// Recompute matches over the live buffer, update highlights, the
        /// current-match index, and report counts back to the model.
        private func runSearch(resetToNearest: Bool, scroll: Bool) {
            guard let search = search, let tv = textView else { return }
            guard search.isOpen, !search.query.isEmpty else {
                searchMatches = []
                currentMatchIndex = 0
                pushHighlights(current: nil)
                search.report(count: 0, index: 0, invalidRegex: false)
                return
            }
            let source = tv.string
            let query = search.query
            let options = search.options

            guard DocumentSearch.isValid(query: query, options: options) else {
                searchMatches = []
                currentMatchIndex = 0
                pushHighlights(current: nil)
                search.report(count: 0, index: 0, invalidRegex: true)
                return
            }

            let matches = DocumentSearch.matches(in: source, query: query, options: options)
            searchMatches = matches

            if matches.isEmpty {
                currentMatchIndex = 0
            } else if resetToNearest || currentMatchIndex == 0 {
                currentMatchIndex = nearestMatchIndex(to: tv.selectedRange().location)
            } else {
                currentMatchIndex = min(currentMatchIndex, matches.count)
            }

            let current = currentMatchIndex > 0 ? matches[currentMatchIndex - 1] : nil
            pushHighlights(current: current)
            if scroll, let current = current { scrollToMatch(current) }
            search.report(count: matches.count, index: currentMatchIndex, invalidRegex: false)
        }

        /// First match at/after `loc`, wrapping to the first match. 1-based.
        private func nearestMatchIndex(to loc: Int) -> Int {
            guard !searchMatches.isEmpty else { return 0 }
            for (i, m) in searchMatches.enumerated() where m.location >= loc {
                return i + 1
            }
            return 1
        }

        private func navigateSearch(by delta: Int) {
            // Matches may be stale if the doc changed since the last pass;
            // recompute counts silently first (no scroll) then move.
            if searchMatches.isEmpty {
                runSearch(resetToNearest: true, scroll: false)
            }
            guard !searchMatches.isEmpty else { return }
            let count = searchMatches.count
            let base = currentMatchIndex == 0 ? 1 : currentMatchIndex
            var idx = (base - 1) + delta
            idx = ((idx % count) + count) % count
            currentMatchIndex = idx + 1
            let current = searchMatches[idx]
            pushHighlights(current: current)
            scrollToMatch(current)
            search?.report(count: count, index: currentMatchIndex, invalidRegex: false)
        }

        private func replaceCurrentMatch() {
            guard let search = search, !search.options.ignoreFormatting,
                  let tv = textView, let storage = tv.textStorage else { return }
            guard currentMatchIndex > 0, currentMatchIndex <= searchMatches.count else { return }
            let match = searchMatches[currentMatchIndex - 1]
            guard NSMaxRange(match) <= storage.length else { return }
            let replacement = DocumentSearch.replacementText(
                forMatch: match, in: tv.string, query: search.query,
                template: search.replaceText, options: search.options)
            if tv.shouldChangeText(in: match, replacementString: replacement) {
                storage.replaceCharacters(in: match, with: replacement)
                tv.didChangeText()
            }
            let newLoc = match.location + (replacement as NSString).length
            let total = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(newLoc, total), length: 0))
            // Re-search from the new caret so we land on the next occurrence.
            runSearch(resetToNearest: true, scroll: true)
        }

        private func replaceAllMatches() {
            guard let search = search, !search.options.ignoreFormatting,
                  let tv = textView, let storage = tv.textStorage else { return }
            let source = tv.string
            let matches = DocumentSearch.matches(in: source, query: search.query, options: search.options)
            guard !matches.isEmpty else { return }
            let fullRange = NSRange(location: 0, length: (source as NSString).length)
            // Bracket the whole multi-range edit as a single undo step.
            guard tv.shouldChangeText(in: fullRange, replacementString: nil) else { return }
            storage.beginEditing()
            for match in matches.reversed() {
                guard NSMaxRange(match) <= storage.length else { continue }
                let replacement = DocumentSearch.replacementText(
                    forMatch: match, in: source, query: search.query,
                    template: search.replaceText, options: search.options)
                storage.replaceCharacters(in: match, with: replacement)
            }
            storage.endEditing()
            tv.didChangeText()
            runSearch(resetToNearest: true, scroll: true)
        }

        private func clearSearchHighlights() {
            searchMatches = []
            currentMatchIndex = 0
            pushHighlights(current: nil)
            // Return focus to the editor so typing resumes immediately.
            if let tv = textView { tv.window?.makeFirstResponder(tv) }
        }

        private func pushHighlights(current: NSRange?) {
            guard let qmd = textView as? PicaMDTextView else { return }
            let accent = ThemeStore.currentAccent
            qmd.searchHighlightColor = accent.withAlphaComponent(0.28)
            qmd.currentSearchHighlightColor = accent.withAlphaComponent(0.5)
            qmd.currentSearchBorderColor = accent
            qmd.setSearchMatches(searchMatches, current: current)
        }

        private func scrollToMatch(_ range: NSRange) {
            guard let tv = textView else { return }
            let total = (tv.string as NSString).length
            let loc = min(range.location, total)
            let len = min(range.length, max(0, total - loc))
            tv.scrollRangeToVisible(NSRange(location: loc, length: len))
        }

        private func computeViewportCharRange() -> NSRange? {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return nil
            }
            let visibleRect = textView.visibleRect
            // Empty visible rect means the view hasn't laid out yet -
            // fall back to full doc.
            guard visibleRect.height > 0 else { return nil }
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let total = textView.textStorage?.length ?? 0
            // Buffer covers any inline-markup or block boundary that
            // crosses the viewport edge in real-world docs.
            let buffer = EditorBuffer.viewportContext
            let start = max(0, charRange.location - buffer)
            let end = min(total, charRange.location + charRange.length + buffer)
            return NSRange(location: start, length: end - start)
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
