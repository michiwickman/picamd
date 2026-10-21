import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    /// When `true`, a newline that merely hard-wraps a paragraph is typeset
    /// as a space, so paragraphs fill the window width like tables already do.
    /// The text storage — and therefore the file on disk — is not modified.
    /// Toggled via the Reflow Mode menu / `⌃⌘R`.
    var reflowMode: Bool = false
    /// Find/replace bar state for this window. Matching + highlight drawing
    /// + navigation/replace are driven by the Coordinator; the bar UI and
    /// the Find menu talk to the same `SearchModel`.
    var search: SearchModel? = nil
    /// Imperative edits from the inspector (front matter fields). The
    /// coordinator registers itself as the bridge's driver.
    var editorBridge: EditorBridge? = nil

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
        // A document that opens with front matter starts with the caret
        // behind it, so the YAML opens collapsed to its meta line. Set
        // before `coordinator.textView`, so the selection callback can't
        // write the cursor binding while SwiftUI is still making the view.
        // Assigning `string` leaves the caret at the end of the text, so
        // the document start is the base: from the end the caret never
        // moved behind the block, and the outline marked the last heading.
        let source = text as NSString
        let block = Frontmatter.fenceRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: source.length))?.range
        let initialSelection = FrontmatterFold.initialSelection(
            NSRange(location: 0, length: 0), block: block, in: source)
        if initialSelection != textView.selectedRange() {
            textView.setSelectedRange(initialSelection)
        }
        context.coordinator.seedTextMirror(text)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.attachSearch(search)
        context.coordinator.attachBridge(editorBridge)
        // The outline highlights the heading at the caret; tell it about
        // the moved caret once SwiftUI has finished making the view (a
        // binding write during makeNSView is not allowed).
        if let binding = cursorLocation, binding.wrappedValue != initialSelection.location {
            let location = initialSelection.location
            DispatchQueue.main.async { binding.wrappedValue = location }
        }
        context.coordinator.isDark = textView.effectiveAppearance.isDark
        context.coordinator.highlighter.theme = theme
        applyTheme(theme, to: scrollView, textView: textView, restyleText: true)

        // Wire up reflow. The layout-manager delegate slot is otherwise
        // unused; the delegate is held strongly by the coordinator because
        // NSLayoutManager keeps only a weak reference.
        if let layoutManager = textView.layoutManager {
            let reflow = ReflowLayoutDelegate()
            reflow.textStorage = textView.textStorage
            reflow.fallbackFont = theme.resolvedBodyFont(size: theme.fontBaseSize)
            reflow.isEnabled = reflowMode
            layoutManager.delegate = reflow
            // Also the storage delegate, so the published offsets follow
            // each edit before the layout manager re-asks about them.
            textView.textStorage?.delegate = reflow
            textView.reflowDelegate = reflow
            context.coordinator.reflowDelegate = reflow
        }

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

        context.coordinator.installTableCellEditing()
        context.coordinator.applyHighlightingNow()
        context.coordinator.startObservingAppearance()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selection = textView.selectedRange()
            // A running theme sweep holds ranges into the old text.
            context.coordinator.cancelProgressiveHighlight()
            textView.string = text
            context.coordinator.seedTextMirror(text)
            let total = (text as NSString).length
            let location = min(selection.location, total)
            let length = min(selection.length, total - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            // Replacing `string` wipes every attribute, so the whole
            // document needs restyling — not just the viewport, or text
            // scrolled into view later would show as raw Markdown.
            context.coordinator.invalidateFullHighlight()
            context.coordinator.applyHighlightingNow()
            context.coordinator.scheduleSearchRefresh()
        }

        // The editor's colours come from the user's palette, not from the
        // system Light/Dark setting, so an appearance flip needs no
        // re-highlight (it used to trigger one for no visual change).
        context.coordinator.isDark = scrollView.effectiveAppearance.isDark

        // Live theme update. Markup structure is unchanged — only colours
        // and fonts — so repaint progressively (viewport first, rest in
        // background chunks) instead of one blocking full-document pass.
        //
        // Fields that never reach the text attributes (chrome appearance,
        // line width, word count, card look) skip the re-colouring sweep:
        // a viewport pass is enough, and it also re-measures overlays if
        // the line width moved the column (the width check in
        // `applyHighlightingNow` turns that pass into a full one).
        let previousTheme = context.coordinator.highlighter.theme
        if previousTheme != theme {
            context.coordinator.highlighter.theme = theme
            context.coordinator.reflowDelegate?.fallbackFont =
                theme.resolvedBodyFont(size: theme.fontBaseSize)
            applyTheme(theme, to: scrollView, textView: textView, restyleText: false)
            if theme.restyles(comparedTo: previousTheme) {
                context.coordinator.applyThemeChangeProgressively()
            } else {
                context.coordinator.scheduleHighlight(delay: 0)
            }
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
        // Reflow toggles change where every line breaks, so every glyph rect
        // in the document moves at once — overlays, checkbox frames and
        // search highlights all read those rects. A full pass, not a
        // viewport repaint.
        if context.coordinator.reflowMode != reflowMode {
            context.coordinator.reflowMode = reflowMode
            context.coordinator.invalidateFullHighlight()
            context.coordinator.applyHighlightingNow()
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

        // The find bar talks to the coordinator directly (SearchDriver);
        // this only keeps the attachment current.
        context.coordinator.attachSearch(search)
        context.coordinator.attachBridge(editorBridge)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Apply background colours, insertion-point colour, and base font
    /// derived from the theme. Called once on creation and on every
    /// theme change.
    ///
    /// `restyleText` sets font + colour on the whole storage — right for
    /// the initial load, wrong for a live theme change: `NSTextView.font`
    /// / `.textColor` overwrite every attribute, un-concealing all the
    /// Markdown outside the viewport until the highlighter reaches it.
    /// On updates only the typing attributes change; the progressive
    /// re-highlight restyles the text itself.
    private func applyTheme(_ theme: EditorTheme, to scrollView: NSScrollView,
                            textView: NSTextView, restyleText: Bool) {
        let bg = theme.palette.bg
        let font = theme.resolvedBodyFont(size: theme.fontBaseSize)
        // Before the colours: changing the column relayouts the text.
        (textView as? PicaMDTextView)?.readableColumnWidth = theme.lineWidth.columnWidth(for: font)
        scrollView.backgroundColor = bg
        textView.backgroundColor = bg
        textView.insertionPointColor = theme.palette.fg
        if restyleText {
            textView.textColor = theme.palette.fg
            textView.font = font
        }
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.foregroundColor] = theme.palette.fg
    }

    private func applyJump(to range: NSRange, in textView: NSTextView) {
        let total = (textView.string as NSString).length
        guard total > 0 else { return }
        let safeLoc = max(0, min(range.location, total))
        let safeRange = NSRange(location: safeLoc, length: 0)
        textView.setSelectedRange(safeRange)
        // Put the heading near the top of the viewport, like a jump in
        // any outline — `scrollRangeToVisible` alone parked it on the
        // bottom edge when jumping forward.
        if let layoutManager = textView.layoutManager,
           let container = textView.textContainer,
           let clip = textView.enclosingScrollView?.contentView {
            let probe = NSRange(location: min(safeLoc, total - 1), length: 1)
            let glyphs = layoutManager.glyphRange(forCharacterRange: probe, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let insets = clip.contentInsets
            let y = EditorScrollMath.jumpOrigin(lineTop: rect.minY + textView.textContainerInset.height,
                                                documentHeight: textView.frame.height,
                                                viewportHeight: clip.bounds.height,
                                                insetTop: insets.top, insetBottom: insets.bottom)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        } else {
            textView.scrollRangeToVisible(safeRange)
        }
        textView.window?.makeFirstResponder(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SearchDriver, EditorEditing {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        let highlighter = SyntaxHighlighter()
        var blockManager: BlockOverlayManager?
        var checkboxManager: CheckboxOverlayManager?
        /// Held strongly: `NSLayoutManager.delegate` is weak.
        var reflowDelegate: ReflowLayoutDelegate?
        var reflowMode: Bool = false
        /// One reusable in-place editor for table cells, shared by every
        /// table in the window.
        let cellEditor = TableCellEditor()
        /// Which table the cell editor is currently working in, identified by
        /// its ordinal among the document's tables — the range shifts with
        /// every edit, the ordinal does not.
        private var editingTableOrdinal: Int?
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
        /// Quantised content width the document was last swept at. A change
        /// forces one document-wide pass so off-screen blocks get their
        /// reserved band rewritten — see `applyHighlightingNow()`.
        private var lastSweptWidth: Int = 0

        // MARK: - Find-bar state
        /// The active window's search model (same instance the bar + Find
        /// menu use). Attached via `attachSearch(_:)`.
        private(set) var search: SearchModel?
        /// Current match set, document order. Mirrored into the text view
        /// for drawing.
        private var searchMatches: [NSRange] = []
        /// 1-based index of the current match; 0 = none.
        private var currentMatchIndex = 0
        private var searchRefreshTask: Task<Void, Never>?
        /// Set when the buffer or query changed since the last pass.
        private var searchMatchesStale = false
        private var pendingSearchReset = false
        private var pendingSearchScroll = false

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

            switch event {
            case .modified:
                handleExternalModification(in: window)
            case .renamedOrDeleted:
                pendingReloadAlert = true
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

        /// Another program changed the file. The reload goes
        /// through NSDocument, never around it: replacing the text directly
        /// left the document marked edited with a stale file date (so the
        /// next save raised a second, spurious conflict), kept undo actions
        /// whose ranges pointed into the replaced text, and read UTF-8 only.
        ///
        /// - No unsaved changes: revert silently, as NSDocument does for an
        ///   unedited document and as TextEdit behaves. Nothing is lost.
        /// - Unsaved changes: ask. Keeping them is the default answer (the
        ///   old prompt made Reload the Return key, one keystroke from
        ///   discarding the user's work) and acknowledges the disk version,
        ///   so the next save overwrites it without asking again.
        private func handleExternalModification(in window: NSWindow) {
            guard let document = NSDocumentController.shared.document(for: window),
                  let url = document.fileURL else { return }
            guard document.isDocumentEdited else {
                revert(document, to: url)
                return
            }
            pendingReloadAlert = true
            // The version the user is asked about. A write that lands while
            // the sheet is up is not part of the answer: acknowledging the
            // disk date at click time would let the next save overwrite it
            // without NSDocument's conflict check.
            let askedAboutDate = Self.modificationDate(of: url)
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” changed on disk"
            alert.informativeText = "Another program changed the file while this window has unsaved changes. Keep your version and overwrite the other program's changes when you save, or revert to the version on disk and lose your unsaved changes."
            alert.addButton(withTitle: "Keep My Changes")
            let revertButton = alert.addButton(withTitle: "Revert")
            revertButton.hasDestructiveAction = true
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.pendingReloadAlert = false
                if response == .alertSecondButtonReturn {
                    self.revert(document, to: url)
                } else {
                    document.fileModificationDate = askedAboutDate
                }
            }
        }

        private func revert(_ document: NSDocument, to url: URL) {
            do {
                try document.revert(toContentsOf: url, ofType: document.fileType ?? UTType.markdown.identifier)
            } catch {
                document.presentError(error)
                return
            }
            // NSDocument clears the change count; the undo actions are the
            // text view's, recorded against the text that was just replaced.
            (textView?.undoManager ?? document.undoManager)?.removeAllActions()
            // Re-attach the vnode watcher to the (possibly newly-created)
            // inode at this path. Without this, an atomic save by another
            // editor swaps the file out from under our open file descriptor
            // and we stop seeing further changes.
            fileWatcher.startWatching(url)
        }

        private static func modificationDate(of url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

        // MARK: - Inspector edits (EditorEditing)

        func attachBridge(_ bridge: EditorBridge?) {
            guard let bridge, bridge.driver !== self else { return }
            bridge.driver = self
        }

        var editorText: String { textView?.string ?? "" }

        var commandTarget: PicaMDTextView? { textView as? PicaMDTextView }

        /// Apply an edit computed outside the text view (the inspector's
        /// front matter fields) as one undo step. Same path as
        /// `toggleCheckbox`: stale-range guard, `shouldChangeText`,
        /// `didChangeText`. Unlike it, the selection is shifted by the
        /// edit, because these edits sit above the caret.
        @discardableResult
        func apply(_ edit: TextEdit, actionName: String) -> Bool {
            guard let textView = textView, let storage = textView.textStorage else { return false }
            // Composing (IME) text has a provisional range of its own.
            guard !textView.hasMarkedText() else { return false }
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= storage.length,
                  (storage.string as NSString).substring(with: edit.range) == edit.expected
            else {
                return false
            }
            let savedSelection = textView.selectedRange()
            // Never merge into the user's last typing run: one field
            // commit is one Undo.
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
                return false
            }
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.undoManager?.setActionName(actionName)

            let adjusted = edit.adjustedSelection(savedSelection)
            let total = storage.length
            let location = min(adjusted.location, total)
            textView.setSelectedRange(NSRange(location: location,
                                              length: min(adjusted.length, total - location)))
            // Synchronous: new front matter must fold before it is drawn
            // as raw YAML in the inserted text's inherited attributes.
            applyHighlightingNow()
            return true
        }

        /// Point the text view's meta line at the block the last pass
        /// folded, with its text (cached per source).
        private var metaLineCache: (source: String, text: String)?

        private func updateFrontmatterMetaLine(source: String, protectedRanges: [NSRange]) {
            guard let qmd = textView as? PicaMDTextView else { return }
            guard let block = highlighter.foldedFrontmatter else {
                qmd.frontmatterMetaLine = nil
                return
            }
            let text: String
            if let cache = metaLineCache, cache.source == source {
                text = cache.text
            } else {
                let heading = FrontmatterMetaLine.firstH1(in: source, from: NSMaxRange(block),
                                                          skipping: protectedRanges)
                text = FrontmatterMetaLine.text(for: Frontmatter.build(from: source),
                                                firstHeading: heading)
                metaLineCache = (source, text)
            }
            let theme = highlighter.theme
            // A folded block never holds the caret, so in Focus Mode its
            // line is always outside the spotlight: dim it like the text.
            let muted = theme.palette.fgMuted
            qmd.frontmatterMetaLine = PicaMDTextView.MetaLine(
                text: text, block: block,
                anchor: highlighter.frontmatterMetaAnchor,
                gap: SyntaxHighlighter.metaLineGap(for: theme),
                font: SyntaxHighlighter.metaLineFont(for: theme),
                color: focusMode ? muted.withAlphaComponent(muted.alphaComponent * 0.3) : muted)
        }

        /// Backspace right behind the folded front matter opens the block
        /// instead of deleting its hidden last line break.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let caret = FrontmatterFold.caretInsteadOfDeleting(
                command: NSStringFromSelector(commandSelector),
                selection: textView.selectedRange(),
                foldedBlock: highlighter.foldedFrontmatter,
                in: textView.string as NSString) else { return false }
            textView.setSelectedRange(caret)
            applyHighlightingNow()
            return true
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
            //
            // The same pass re-highlights what just scrolled into view.
            // Highlighting is viewport-scoped, and nothing used to restyle
            // text on scroll — so anything that went stale off-screen
            // (a theme change whose background sweep was interrupted,
            // Focus Mode, a reload) stayed raw Markdown until the caret
            // got there.
            liveSetRefreshTask?.cancel()
            liveSetRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(EditorTiming.lazyLiveSetDebounceMs))
                if Task.isCancelled { return }
                self?.applyHighlightingNow()
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
                if let previous = note.userInfo?[MarkdownDocument.willWriteConvertedFromKey] as? String {
                    Task { @MainActor [weak self] in
                        self?.showEncodingConversionNote(previousEncoding: previous)
                    }
                }
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

        /// Shown at most once per window: the save that needed it already
        /// switched the document to UTF-8 for good.
        private var shownEncodingConversionNote = false

        /// A save had to leave the file's encoding because the text now
        /// holds characters it can't store. Say so once, plainly, instead of
        /// changing the file's encoding behind the user's back.
        private func showEncodingConversionNote(previousEncoding: String) {
            guard !shownEncodingConversionNote, let window = textView?.window else { return }
            shownEncodingConversionNote = true
            let alert = NSAlert()
            alert.messageText = "Saved as UTF-8"
            alert.informativeText = "This file was in \(previousEncoding), which can't store some of the characters it now contains. PicaMD saved it as UTF-8 and will keep using UTF-8 for it."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.beginSheetModal(for: window)
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
                    // Tracked for completeness only: the palette, not the
                    // system appearance, decides every editor colour.
                    self.isDark = nowDark
                }
            }
        }

        /// Typing right after concealed markup (the folded front matter's
        /// last line break, a hidden rule) would inherit its invisible
        /// font and colour until the next highlight pass; type in the
        /// body style instead.
        func textView(_ textView: NSTextView,
                      shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:])
            -> [NSAttributedString.Key: Any] {
            Self.visibleTypingAttributes(newTypingAttributes, theme: highlighter.theme)
        }

        static func visibleTypingAttributes(_ attributes: [NSAttributedString.Key: Any],
                                            theme: EditorTheme) -> [NSAttributedString.Key: Any] {
            let font = attributes[.font] as? NSFont
            let color = attributes[.foregroundColor] as? NSColor
            let concealed = (font.map { $0.pointSize <= EditorFont.concealedSize } ?? false)
                || color == .clear
            guard concealed else { return attributes }
            var visible = attributes
            visible[.font] = theme.resolvedBodyFont(size: theme.fontBaseSize)
            visible[.foregroundColor] = theme.palette.fg
            visible[.paragraphStyle] = nil
            visible[.kern] = nil
            visible[.underlineStyle] = nil
            return visible
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let str = textView.string
            writeBinding(str, undoManager: textView.undoManager)
            currentTextMirror.withLock { $0 = str }
            scheduleHighlight(delay: EditorTiming.highlightDebounceMs)
            scheduleSearchRefresh()
        }

        /// Hand the editor's text to the FileDocument binding without letting
        /// SwiftUI put an undo action of its own on the stack.
        ///
        /// DocumentGroup registers an undo for every write to a FileDocument
        /// binding, on the document's undo manager, which is the one the
        /// text view uses too. Every keystroke then added an unnamed SwiftUI
        /// step next to the text view's coalesced "Typing" step, so ⌘Z took
        /// back one character at a time and each step held a copy of the
        /// whole document. The text view already records every user edit and
        /// marks the document edited through it, so its stack is complete
        /// on its own; the binding only has to carry the value.
        private func writeBinding(_ text: String, undoManager: UndoManager?) {
            guard let undoManager else {
                parent.text = text
                return
            }
            undoManager.disableUndoRegistration()
            defer { undoManager.enableUndoRegistration() }
            parent.text = text
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
            // Only a caret is centred. Centring a whole selection made ⌘A
            // jump to the middle of the document and a drag-selection
            // bounce on every mouse move.
            guard cursor.length == 0 else { return }
            let total = textView.textStorage?.length ?? 0
            guard total > 0 else { return }
            // Probe one real character (clamped at the end of the
            // document) so the bounding rect is the caret's line.
            let probeRange = NSRange(location: min(cursor.location, total - 1), length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: probeRange,
                                                       actualCharacterRange: nil)
            let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                       in: textContainer)
            let inset = textView.textContainerInset
            let lineMidY = bounding.minY + inset.height + bounding.height / 2

            let clip = scrollView.contentView
            // Target: line centre at the centre of the unobscured viewport.
            let targetY = EditorScrollMath.centeredOrigin(lineMidY: lineMidY,
                                                          documentHeight: textView.frame.height,
                                                          viewportHeight: clip.bounds.height,
                                                          insetTop: clip.contentInsets.top,
                                                          insetBottom: clip.contentInsets.bottom)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Background sweep that repaints the off-screen part of the doc
        /// with a new theme/appearance, chunk by chunk, after the visible
        /// viewport has already been repainted. Cancelled by any edit or
        /// cursor move (via `scheduleHighlight`); whatever it didn't reach
        /// is restyled when scrolled into view.
        private var progressiveHighlightTask: Task<Void, Never>?

        func cancelProgressiveHighlight() {
            progressiveHighlightTask?.cancel()
            progressiveHighlightTask = nil
        }

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
            let heights = blockManager?.desiredHeights(for: blocks) ?? [:]
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
            // While a cell editor is open the caret is not conceptually in the
            // document — the user is editing inside an overlay. `NSNotFound`
            // is a range that `touchesBlock` can never match (its `location <=
            // end` test fails for any real block), so no block is treated as
            // active and the table stays rendered.
            //
            // Without this, committing an edit left the caret inside the table
            // (AppKit moves the insertion point to the end of a replacement),
            // the block collapsed back to raw pipes, and the overlay — with
            // the still-open editor parented to it — was hidden.
            let cursor = cellEditor.isOpen
                ? NSRange(location: NSNotFound, length: 0)
                : textView.selectedRange()

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
            let textChanged = scanCacheSource != source
            // Block extraction, task-list matches and protected ranges are
            // all full-document scans derived purely from the text. They
            // can't change unless the text changes, so memoise them by
            // source — a cursor move (the 16 ms-debounced hot path) reuses
            // the cache instead of re-scanning the whole document three
            // more times.
            let (blocks, taskMatches, protectedRanges) = textDerivedScans(for: source)

            // Refresh footnote-tooltip index so hover-popovers stay in
            // sync with the source — only when the text changed, not on
            // every caret move / scroll. Before the pre-layout return
            // below: the very first pass (from `makeNSView`, no width
            // yet) is the one that sees `textChanged`, and skipping it
            // left a freshly opened document without footnote hovers
            // until its first edit.
            if textChanged, let qmdView = textView as? PicaMDTextView {
                qmdView.footnoteTooltip.updateIndex(from: source)
            }

            // Must happen BEFORE any measuring: the reflow classification
            // decides where lines break, and every height and glyph rect
            // below is derived from that.
            publishReflowClassification(source: source)

            // Pre-layout: `makeNSView` calls us before SwiftUI has sized the
            // scroll view, so the text container has no width yet and no
            // block can be measured. Paint the text, leave every block as
            // plain source, and let the frame-change that follows layout do
            // the real pass. Reserving at a made-up width here is what used
            // to bake an 8x-too-tall band into every table in the document.
            guard let width = blockManager?.resolvedContentWidth() else {
                highlighter.highlight(
                    textStorage: storage,
                    isDark: isDark,
                    cursorRange: cursor,
                    blocks: blocks,
                    blockHeights: [:],
                    viewportRange: nil,
                    focusMode: focusMode,
                    taskMatches: taskMatches
                )
                checkboxManager?.theme = highlighter.theme
                checkboxManager?.update(matches: taskMatches,
                                        cursorActiveRanges: [cursor],
                                        protectedRanges: protectedRanges)
                updateFrontmatterMetaLine(source: source, protectedRanges: protectedRanges)
                return
            }

            // A width change invalidates EVERY reserved band, not just the
            // on-screen ones: the band is written per viewport slice, but
            // `reposition()` and `draw()` use the current width for every
            // block in the document. Scrolling never re-highlights, so
            // without this sweep an off-screen table keeps a band measured
            // at the old width until the caret happens to visit it — which
            // is exactly the "click into the table and it fixes itself"
            // behaviour. Quantised so sub-pixel jitter can't retrigger it.
            // Also catches sidebar toggles, full-screen and scroller changes,
            // which resize the container without a frame notification here.
            let quantisedWidth = Int(width.rounded())
            if quantisedWidth != lastSweptWidth {
                lastSweptWidth = quantisedWidth
                needsFullHighlight = true
            }

            let heights = blockManager?.desiredHeights(for: blocks) ?? [:]

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
            updateFrontmatterMetaLine(source: source, protectedRanges: protectedRanges)
        }

        /// Memoised text-derived scans (block overlays, task-list
        /// checkboxes, protected code/math ranges). Keyed on source
        /// identity so a cursor move reuses the cache; a text edit
        /// recomputes. See `textDerivedScans(for:)`.
        private var scanCacheSource: String?
        private var scanCacheBlocks: [ExtractedBlock] = []
        private var scanCacheTaskMatches: [TaskListMatch] = []
        private var scanCacheProtected: [NSRange] = []
        /// Reflow classification of `scanCacheSource`. Computed lazily and
        /// only while reflow is on — with the mode off (the default) the
        /// classifier would run on every edit for a result nobody reads.
        private(set) var scanCacheSoftNewlines: Set<Int> = []
        private var scanCacheSoftNewlinesValid = false

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
            scanCacheSoftNewlinesValid = false
            return (blocks, matches, protectedRanges)
        }

        /// Push the current soft-newline classification into the layout
        /// delegate and, if it actually changed, throw away the cached
        /// glyphs — NSLayoutManager caches the control-character decision
        /// alongside the glyph, so a changed classification is invisible
        /// until the glyphs are regenerated.
        /// The lines whose typesetting changes when the soft-newline set goes
        /// from `old` to `new`: from the line holding the first offset that
        /// flipped to the end of the line after the last one (a flipped
        /// newline joins or splits exactly those two lines). Nil when no
        /// offset flipped.
        nonisolated static func reflowInvalidationRange(old: Set<Int>, new: Set<Int>,
                                                        in text: NSString) -> NSRange? {
            let flipped = old.symmetricDifference(new).filter { $0 >= 0 && $0 < text.length }
            guard let first = flipped.min(), let last = flipped.max() else { return nil }
            let start = text.lineRange(for: NSRange(location: max(0, first - 1), length: 0)).location
            let afterLast = min(last + 1, text.length)
            let end = afterLast < text.length
                ? NSMaxRange(text.lineRange(for: NSRange(location: afterLast, length: 0)))
                : text.length
            return NSRange(location: start, length: end - start)
        }

        private func publishReflowClassification(source: String) {
            guard let delegate = reflowDelegate else { return }
            if reflowMode, !scanCacheSoftNewlinesValid {
                // Fourth product of the same source-keyed cache: the reflow
                // classifier needs exactly the block and protected ranges
                // the scans computed, and must never grow into a second,
                // subtly divergent markdown parser.
                scanCacheSoftNewlines = ReflowClassifier.softNewlineOffsets(
                    in: source, blocks: scanCacheBlocks, protectedRanges: scanCacheProtected
                )
                scanCacheSoftNewlinesValid = true
            }
            let wanted = reflowMode ? scanCacheSoftNewlines : []
            let enabledChanged = delegate.isEnabled != reflowMode
            let setChanged = delegate.softNewlines != wanted
            guard enabledChanged || setChanged else { return }
            let previous = delegate.softNewlines
            delegate.isEnabled = reflowMode
            delegate.publish(softNewlines: wanted)

            guard let layoutManager = textView?.layoutManager,
                  let storage = textView?.textStorage, storage.length > 0 else { return }
            // Toggling the mode changes every soft newline at once. A changed
            // classification inside the mode — a Return in a hard-wrapped
            // paragraph — only touches the lines around the offsets that
            // flipped; regenerating the whole document's glyphs for it cost a
            // full relayout of a long file after every such keystroke.
            let target = enabledChanged
                ? NSRange(location: 0, length: storage.length)
                : Self.reflowInvalidationRange(old: previous, new: wanted,
                                               in: storage.mutableString)
            guard let target, target.length > 0 else { return }
            layoutManager.invalidateGlyphs(forCharacterRange: target,
                                           changeInLength: 0,
                                           actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: target,
                                           actualCharacterRange: nil)
            blockManager?.reposition()
            checkboxManager?.reposition()
        }

        // MARK: - Table cell editing

        /// Wire the overlay manager's table interactions to the in-place cell
        /// editor. Called once, from `makeNSView`.
        func installTableCellEditing() {
            blockManager?.onEditTableCell = { [weak self] block, row, col, rect, view in
                self?.openCellEditor(block: block, row: row, col: col, rect: rect, in: view)
            }
            blockManager?.onCollapseBlockToSource = { [weak self] block in
                self?.collapseBlockToSource(block)
            }
            cellEditor.onCommit = { [weak self] range, newText, expectedOld in
                self?.commitCellEdit(range: range, newText: newText, expectedOld: expectedOld) ?? false
            }
            cellEditor.onMove = { [weak self] rowDelta, colDelta in
                self?.moveCellEditor(rowDelta: rowDelta, colDelta: colDelta)
            }
            cellEditor.restoreFocus = { [weak self] in
                guard let tv = self?.textView else { return }
                tv.window?.makeFirstResponder(tv)
            }
            cellEditor.onClose = { [weak self] in
                // One settling pass with the caret back where it was before
                // the click, so the table's rendered/collapsed state matches
                // the real caret again.
                self?.editingTableOrdinal = nil
                self?.applyHighlightingNow()
            }
        }

        /// Ordinal of `block` among the document's table blocks. Survives the
        /// range shifts that every edit causes.
        private func tableOrdinal(of block: ExtractedBlock, in blocks: [ExtractedBlock]) -> Int? {
            var n = 0
            for b in blocks where b.kind == .table {
                if b.range.location == block.range.location { return n }
                n += 1
            }
            return nil
        }

        private func tableBlock(atOrdinal ordinal: Int) -> ExtractedBlock? {
            guard let source = textView?.string else { return nil }
            let tables = BlockExtractor.extract(from: source).filter { $0.kind == .table }
            guard ordinal >= 0, ordinal < tables.count else { return nil }
            return tables[ordinal]
        }

        private func openCellEditor(block: ExtractedBlock, row: Int, col: Int,
                                    rect: NSRect, in view: TableBlockView) {
            guard let parsed = block.parseTableCells() else {
                collapseBlockToSource(block)
                return
            }
            guard let cell = cellFor(row: row, col: col, in: parsed) else { return }
            let source = textView?.string ?? ""
            editingTableOrdinal = tableOrdinal(of: block,
                                               in: BlockExtractor.extract(from: source))
            // A table wider than the column scrolls sideways; bring a partly
            // hidden cell fully into view before the editor covers it.
            view.scrollColumnToVisible(col)
            let rect = view.cellRect(row: row, col: col) ?? rect
            cellEditor.open(in: view, cell: cell, row: row, col: col, rect: rect,
                            font: NSFont.systemFont(ofSize: 13,
                                                     weight: row < 0 ? .semibold : .regular))
        }

        private func cellFor(row: Int, col: Int,
                             in parsed: (alignments: [TableAlignment?],
                                         header: [TableCell],
                                         rows: [[TableCell]])) -> TableCell? {
            let cells = row < 0 ? parsed.header : (row < parsed.rows.count ? parsed.rows[row] : [])
            guard col >= 0, col < cells.count else { return nil }
            return cells[col]
        }

        /// Replace a cell's source text. Modelled on `toggleCheckbox`: the
        /// same stale-range guard is required because highlighting is
        /// debounced, so the range can be a few tens of milliseconds old.
        private func commitCellEdit(range: NSRange, newText: String, expectedOld: String) -> Bool {
            guard let textView = textView, let storage = textView.textStorage else { return false }
            guard range.location >= 0,
                  range.location + range.length <= storage.length else { return false }
            let current = (storage.string as NSString).substring(with: range)
            guard current == expectedOld else {
                // The document moved under us — refuse rather than corrupt it.
                applyHighlightingNow()
                return false
            }
            let savedSelection = textView.selectedRange()
            textView.undoManager?.setActionName("Edit Table Cell")
            guard textView.shouldChangeText(in: range, replacementString: newText) else { return false }
            storage.replaceCharacters(in: range, with: newText)
            textView.didChangeText()

            // Map the caret through the replacement: clicking a cell does not
            // move it, so it usually sits below the table, and restoring the
            // old offset unshifted left it `delta` characters off — a caret on
            // the line under a table that grew landed inside the table, and
            // the table collapsed to raw pipes when the editor closed.
            let edit = TextEdit(range: range, replacement: newText, expected: current)
            let mapped = edit.adjustedSelection(savedSelection)
            let total = storage.length
            let loc = min(mapped.location, total)
            textView.setSelectedRange(NSRange(location: loc,
                                              length: min(mapped.length, total - loc)))
            // Synchronous, not the 50 ms debounce: the reserved band and the
            // overlay frame must be rebuilt before the next cell's rect is
            // derived from them.
            applyHighlightingNow()
            return true
        }

        private func moveCellEditor(rowDelta: Int, colDelta: Int) {
            guard let ordinal = editingTableOrdinal,
                  let current = cellEditor.openCell,
                  let block = tableBlock(atOrdinal: ordinal),
                  let parsed = block.parseTableCells(),
                  let view = blockManager?.view(for: block) as? TableBlockView else {
                cellEditor.close(commitFirst: false)
                return
            }
            var row = current.row + rowDelta
            var col = current.col + colDelta
            let columnCount = max(parsed.header.count, parsed.rows.map(\.count).max() ?? 0)

            // Tab past the last column wraps to the next row, as in a spreadsheet.
            if colDelta != 0 {
                if col >= columnCount { col = 0; row += 1 }
                else if col < 0 { col = columnCount - 1; row -= 1 }
            }
            if col >= 0, col < columnCount { view.scrollColumnToVisible(col) }
            guard row >= -1, row < parsed.rows.count,
                  col >= 0, col < columnCount,
                  let cell = cellFor(row: row, col: col, in: parsed),
                  let rect = view.cellRect(row: row, col: col) else {
                cellEditor.close(commitFirst: false)
                return
            }
            cellEditor.reopen(in: view, cell: cell, row: row, col: col, rect: rect)
        }

        /// The explicit "edit the whole table as markdown" gesture: put the
        /// caret in the block, which makes the existing collapse path reveal
        /// the source exactly as it does today.
        private func collapseBlockToSource(_ block: ExtractedBlock) {
            guard let textView = textView else { return }
            cellEditor.close(commitFirst: true)
            editingTableOrdinal = nil
            let total = (textView.string as NSString).length
            let loc = min(block.range.location, total)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            applyHighlightingNow()
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

        // MARK: - Find bar (SearchDriver)

        /// Attach to this window's search model. The model forwards query,
        /// option and command changes straight here — relying on
        /// `updateNSView` for that was unreliable, because SwiftUI doesn't
        /// re-run a representable's update when only a reference-type
        /// property's contents changed.
        func attachSearch(_ model: SearchModel?) {
            guard search !== model else { return }
            search = model
            model?.driver = self
        }

        func searchParametersChanged() {
            guard search?.isOpen == true else { return }
            scheduleSearch(resetToNearest: true, scroll: true,
                           delayMs: EditorTiming.searchQueryDebounceMs)
        }

        func performSearchAction(_ action: SearchModel.Action) {
            switch action {
            case .next: navigateSearch(by: 1)
            case .previous: navigateSearch(by: -1)
            case .replaceCurrent: replaceCurrentMatch()
            case .replaceAll: replaceAllMatches()
            case .useSelection:
                // The model already took the selection as its query
                // (`selectedTextForFind`); land on that occurrence now.
                runSearch(resetToNearest: true, scroll: true)
            case .jumpToSelection:
                if let tv = textView {
                    tv.scrollRangeToVisible(tv.selectedRange())
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }

        func selectedTextForFind() -> String? {
            guard let tv = textView else { return nil }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            guard sel.location != NSNotFound, sel.length > 0, NSMaxRange(sel) <= ns.length else { return nil }
            return ns.substring(with: sel)
        }

        func searchDidClose() {
            searchRefreshTask?.cancel()
            searchRefreshTask = nil
            // Leave the caret on the match the user was looking at, like
            // every Mac find bar — closing shouldn't snap back to where
            // the search started.
            let current = currentMatch
            searchMatches = []
            currentMatchIndex = 0
            visibleTextCache = nil
            pushHighlights(current: nil)
            guard let tv = textView else { return }
            if let current, NSMaxRange(current) <= (tv.string as NSString).length {
                tv.setSelectedRange(current)
                tv.scrollRangeToVisible(current)
            }
            tv.window?.makeFirstResponder(tv)
        }

        /// Keeps counts + highlights current while the user edits with the
        /// bar open, without jumping the viewport on every keystroke.
        func scheduleSearchRefresh() {
            guard search?.isOpen == true else { return }
            scheduleSearch(resetToNearest: false, scroll: false,
                           delayMs: EditorTiming.searchRefreshDebounceMs)
        }

        private func scheduleSearch(resetToNearest: Bool, scroll: Bool, delayMs: Int) {
            // Coalesce: a later lightweight refresh must not drop an
            // earlier request to reset / scroll to the nearest match.
            pendingSearchReset = pendingSearchReset || resetToNearest
            pendingSearchScroll = pendingSearchScroll || scroll
            searchMatchesStale = true
            searchRefreshTask?.cancel()
            searchRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self else { return }
                self.runSearch(resetToNearest: self.pendingSearchReset,
                               scroll: self.pendingSearchScroll)
            }
        }

        /// Commands must act on the live buffer: flush a pending
        /// (debounced) re-match first so ⌘G / Replace right after typing
        /// never works on stale ranges.
        private func flushPendingSearch() {
            if searchMatchesStale {
                runSearch(resetToNearest: pendingSearchReset, scroll: false)
            }
        }

        private var currentMatch: NSRange? {
            guard currentMatchIndex > 0, currentMatchIndex <= searchMatches.count else { return nil }
            return searchMatches[currentMatchIndex - 1]
        }

        /// Recompute matches over the live buffer, update highlights, the
        /// current-match index, and report counts back to the model.
        private func runSearch(resetToNearest: Bool, scroll: Bool) {
            searchRefreshTask?.cancel()
            searchRefreshTask = nil
            pendingSearchReset = false
            pendingSearchScroll = false
            searchMatchesStale = false
            guard let search = search, let tv = textView else { return }
            guard search.isOpen, !search.query.isEmpty else {
                searchMatches = []
                currentMatchIndex = 0
                pushHighlights(current: nil)
                search.report(count: 0, index: 0, invalidRegex: false)
                return
            }
            let query = search.query
            let options = search.options

            guard DocumentSearch.isValid(query: query, options: options) else {
                searchMatches = []
                currentMatchIndex = 0
                pushHighlights(current: nil)
                search.report(count: 0, index: 0, invalidRegex: true)
                return
            }

            let source = tv.string
            let matches: [NSRange]
            if options.ignoreFormatting {
                matches = DocumentSearch.matches(in: visibleText(for: source), query: query, options: options)
            } else {
                matches = DocumentSearch.matches(in: source, query: query, options: options)
            }
            let previous = currentMatch
            searchMatches = matches

            if matches.isEmpty {
                currentMatchIndex = 0
            } else if resetToNearest || previous == nil {
                currentMatchIndex = DocumentSearch.nearestMatchIndex(
                    in: matches, to: tv.selectedRange().location, wrapAround: options.wrapAround)
            } else if let previous {
                // Live edit: stay on the same occurrence (or the next one
                // if it was edited away) instead of drifting by index.
                currentMatchIndex = DocumentSearch.sameOccurrenceIndex(
                    in: matches, previous: previous, wrapAround: options.wrapAround)
            }

            let current = currentMatch
            pushHighlights(current: current)
            if scroll, let current { tv.scrollRangeToVisible(current) }
            search.report(count: matches.count, index: currentMatchIndex, invalidRegex: false)
        }

        /// Visible-text projection for ignore-formatting search, cached per
        /// source so typing a query doesn't re-run every markup regex over
        /// an unchanged document on each keystroke.
        private var visibleTextCache: (source: String, visible: DocumentSearch.VisibleText)?

        private func visibleText(for source: String) -> DocumentSearch.VisibleText {
            if let cache = visibleTextCache, cache.source == source { return cache.visible }
            let visible = DocumentSearch.visibleText(from: source)
            visibleTextCache = (source, visible)
            return visible
        }

        private func navigateSearch(by delta: Int) {
            guard let search, let tv = textView else { return }
            guard search.isOpen else {
                findAgainWithBarClosed(by: delta, query: search.query, options: search.options, in: tv)
                return
            }
            flushPendingSearch()
            guard !searchMatches.isEmpty else { return }
            let count = searchMatches.count
            // Wrap Around off: stop at either end — also from "no current
            // match" (nothing after the caret), which used to jump to the
            // first match regardless.
            guard let target = DocumentSearch.navigationTarget(
                current: currentMatchIndex, delta: delta, matches: searchMatches,
                selection: tv.selectedRange(), wrapAround: search.options.wrapAround) else {
                NSSound.beep()
                return
            }
            currentMatchIndex = target
            let current = searchMatches[target - 1]
            pushHighlights(current: current)
            // Move the selection onto the match (TextEdit / Xcode
            // behaviour): the outline and typewriter mode follow it, and
            // closing the bar leaves the caret where the user ended up.
            tv.setSelectedRange(current)
            tv.scrollRangeToVisible(current)
            search.report(count: count, index: currentMatchIndex, invalidRegex: false)
        }

        /// ⌘G / ⇧⌘G with the bar closed: one search over the live text,
        /// select the next match after (or the previous one before) the
        /// selection and flash the system find indicator on it. No
        /// highlights and no counts — nothing shows them. A match inside
        /// folded front matter opens the block, because the selection now
        /// starts inside it (`FrontmatterFold.isFolded`).
        private func findAgainWithBarClosed(by delta: Int, query: String,
                                            options: SearchOptions, in tv: NSTextView) {
            let matches = DocumentSearch.matches(in: tv.string, query: query, options: options)
            guard let target = DocumentSearch.navigationTarget(
                current: 0, delta: delta, matches: matches,
                selection: tv.selectedRange(), wrapAround: options.wrapAround) else {
                NSSound.beep()
                return
            }
            let match = matches[target - 1]
            tv.setSelectedRange(match)
            tv.scrollRangeToVisible(match)
            if tv.window != nil { tv.showFindIndicator(for: match) }
        }

        private func replaceCurrentMatch() {
            flushPendingSearch()
            guard let search = search, !search.options.ignoreFormatting,
                  let tv = textView, let storage = tv.textStorage else { return }
            // Return in the replace field reaches here even when the
            // button is off: no current match (Wrap Around off, caret
            // behind the last one) is a beep, not silence.
            guard let match = currentMatch else { NSSound.beep(); return }
            let source = tv.string
            guard NSMaxRange(match) <= (source as NSString).length else { return }
            let replacement = DocumentSearch.replacementText(
                forMatch: match, in: source, query: search.query,
                template: search.replaceText, options: search.options)
            guard tv.shouldChangeText(in: match, replacementString: replacement) else { return }
            storage.replaceCharacters(in: match, with: replacement)
            tv.didChangeText()
            tv.undoManager?.setActionName("Replace")
            let total = storage.length
            tv.setSelectedRange(NSRange(location: min(match.location + (replacement as NSString).length, total),
                                        length: 0))
            // Land on the next occurrence after the replaced text.
            runSearch(resetToNearest: true, scroll: false)
            if let next = currentMatch {
                tv.setSelectedRange(next)
                tv.scrollRangeToVisible(next)
            }
        }

        private func replaceAllMatches() {
            guard let search = search, !search.options.ignoreFormatting,
                  let tv = textView, let storage = tv.textStorage else { return }
            let source = tv.string
            let replacements = DocumentSearch.replacements(in: source, query: search.query,
                                                           template: search.replaceText,
                                                           options: search.options)
            guard !replacements.isEmpty else { return }
            // One multi-range change = one undo step that restores every
            // replaced span. (Announcing the whole document with a nil
            // replacement string, as before, registers an attributes-only
            // change, so Undo couldn't bring the original text back.)
            guard tv.shouldChangeText(inRanges: replacements.map { NSValue(range: $0.range) },
                                      replacementStrings: replacements.map(\.text)) else { return }
            storage.beginEditing()
            for replacement in replacements.reversed() {
                storage.replaceCharacters(in: replacement.range, with: replacement.text)
            }
            storage.endEditing()
            tv.didChangeText()
            tv.undoManager?.setActionName("Replace All")
            // Replacements can land anywhere in the document, including
            // off-screen, where the viewport-scoped highlighter wouldn't
            // restyle them.
            invalidateFullHighlight()
            scheduleHighlight(delay: 0)
            runSearch(resetToNearest: true, scroll: true)
        }

        private func pushHighlights(current: NSRange?) {
            // A current match inside folded front matter opens the block
            // (and a match leaving it lets the block fold again).
            if highlighter.searchMatchToReveal != current {
                let block = highlighter.frontmatterBlock
                let touchesBlock = [highlighter.searchMatchToReveal, current].contains { match in
                    guard let match, let block else { return false }
                    return match.location < NSMaxRange(block)
                }
                highlighter.searchMatchToReveal = current
                if touchesBlock { scheduleHighlight(delay: 0) }
            }
            // Colours live in the text view: system yellow, not the accent.
            guard let qmd = textView as? PicaMDTextView else { return }
            qmd.setSearchMatches(searchMatches, current: current)
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
