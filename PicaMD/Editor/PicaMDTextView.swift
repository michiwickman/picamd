import AppKit
import UniformTypeIdentifiers

/// `NSTextView` subclass that runs the Markdown-editor commands
/// (`KeybindingAction`): headings, Bold/Italic/Strikethrough/Inline
/// Code/Link, Checklist/Quote/Table, Move/Duplicate/Select Line.
///
/// They arrive three ways. The Format menu calls
/// `performEditorCommand(_:)` on the key window's editor; menu key
/// equivalents are matched before `keyDown`, so ⌘1, ⌘B, ⇧⌘D … reach
/// the editor only that way. Combos without a menu item (⌘4–⌘6, ⌘L, and
/// any menu combo while its item is disabled) arrive in `keyDown` through
/// `KeybindingMap`. The command palette calls `runCommand(_:)` directly.
final class PicaMDTextView: NSTextView {

    /// Smart punctuation (`--` → –, `...` → …, curly quotes). Off by
    /// default: Markdown syntax is built from exactly these characters.
    /// Settings ▸ Editor ▸ Typing. Read per keystroke (a cheap defaults
    /// lookup) so toggling applies to every open window immediately.
    var smartPunctuationEnabled: Bool {
        UserDefaults.standard.bool(forKey: EditorPreferences.smartPunctuationKey)
    }

    /// Auto-pairing of brackets, quotes and backticks. On by default.
    var autoPairEnabled: Bool {
        UserDefaults.standard.bool(forKey: EditorPreferences.autoPairKey)
    }

    // MARK: - Find-bar match highlighting

    /// Match ranges from the find bar, in document order. Drawn as
    /// rounded rects ON TOP of the glyphs in `draw(_:)` so they stay
    /// visible regardless of any concealed markup or attribute
    /// backgrounds (inline code, table rows) underneath. The coordinator
    /// keeps these in sync with the `SearchModel`.
    private var searchMatchRanges: [NSRange] = []
    /// The currently-focused match — solid fill, redrawn text, outline.
    private var currentSearchMatch: NSRange?
    /// Fill for non-current matches (board `FindReplace`: yellow at
    /// 0.42). System yellow, not the accent: the find highlight is the
    /// same colour in every Mac app, whatever the editor palette.
    /// Dynamic, so it resolves against the view's appearance per draw.
    var searchHighlightColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.42)
    /// Solid fill for the current match; its text is redrawn on top in
    /// `currentSearchTextColor`.
    var currentSearchHighlightColor: NSColor = NSColor.systemYellow
    /// The current match's hairline outline (board: black at 0.18).
    var currentSearchBorderColor: NSColor = NSColor.black.withAlphaComponent(0.18)
    /// Text on the solid yellow: always dark (board `#1D1D1F`), because
    /// a light text colour from a dark palette would vanish on yellow.
    var currentSearchTextColor: NSColor = NSColor(srgbRed: 0x1D / 255.0, green: 0x1D / 255.0,
                                                  blue: 0x1F / 255.0, alpha: 1)

    /// Read-only view for tests.
    var searchHighlightState: (matches: [NSRange], current: NSRange?) {
        (searchMatchRanges, currentSearchMatch)
    }

    /// The matches `drawSearchHighlights` paints: all but those inside
    /// folded front matter. Their glyphs are 0.01 pt wide and clear, so a
    /// highlight there is a stray yellow sliver over the meta line. The
    /// count still includes them, and making one current opens the block.
    var drawnSearchMatches: [NSRange] {
        searchMatchRanges.filter { !Self.isHidden($0, byFold: frontmatterMetaLine?.block) }
    }

    nonisolated static func isHidden(_ match: NSRange, byFold fold: NSRange?) -> Bool {
        guard let fold else { return false }
        return match.location < NSMaxRange(fold) && NSMaxRange(match) > fold.location
    }

    /// Replace the highlighted match set and force a repaint.
    func setSearchMatches(_ matches: [NSRange], current: NSRange?) {
        searchMatchRanges = matches
        currentSearchMatch = current
        needsDisplay = true
    }

    /// Loaded once at first instance; subsequent text views share the
    /// same map so a runtime keybindings.json edit takes effect on the
    /// next launch (we don't watch the file — `KeybindingLoader.load()`
    /// re-runs cheaply if you ever wire that). Static-let initialiser
    /// is thread-safe under Swift's lazy-static semantics.
    static let keybindings: KeybindingMap = KeybindingLoader.load()

    /// URL of the document this view is editing. Set by the SwiftUI
    /// coordinator once `window.representedURL` becomes known. Used to
    /// resolve where dragged-in image files should be copied.
    var documentURL: URL? {
        didSet { registerForImageDrops() }
    }

    /// Hover-tooltip for `[^id]` footnote references. Lazily created
    /// the first time the view enters a window so we have something to
    /// add a tracking area to.
    private(set) lazy var footnoteTooltip: FootnoteTooltipController = {
        FootnoteTooltipController(textView: self)
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            footnoteTooltip.refreshTrackingArea()
            if !observesUndoGroups {
                observesUndoGroups = true
                NotificationCenter.default.addObserver(self, selector: #selector(undoGroupDidClose(_:)),
                                                       name: .NSUndoManagerDidCloseUndoGroup, object: nil)
            }
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        footnoteTooltip.refreshTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        footnoteTooltip.mouseMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        footnoteTooltip.hide()
    }

    // MARK: - Find-bar highlight drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFrontmatterMetaLine(in: dirtyRect)
        drawSearchHighlights(in: dirtyRect)
    }

    // MARK: - Front matter meta line

    /// The grey line drawn for a collapsed front matter block.
    struct MetaLine: Equatable {
        let text: String
        /// The folded block: 0.01 pt clear text. Without `anchor` the line
        /// is drawn on its first line fragment, whose height the
        /// highlighter reserved.
        let block: NSRange
        var location: Int { block.location }
        /// The H1 right after the block, when there is one: the line is
        /// drawn `gap` below it, in the paragraph spacing the highlighter
        /// added under the H1, and the block takes no height.
        var anchor: NSRange? = nil
        var gap: CGFloat = 0
        let font: NSFont
        let color: NSColor
    }

    /// Set by the coordinator after each highlight pass; nil while the
    /// block is open (caret inside) or absent.
    var frontmatterMetaLine: MetaLine? {
        didSet { if frontmatterMetaLine != oldValue { needsDisplay = true } }
    }

    /// Where the meta line is drawn, in view coordinates.
    func frontmatterMetaLineRect() -> NSRect? {
        guard let meta = frontmatterMetaLine,
              let layoutManager, let textContainer, let storage = textStorage,
              meta.location < storage.length else { return nil }
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        if let anchor = meta.anchor, anchor.length > 0, NSMaxRange(anchor) <= storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(anchor) - 1)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let height = ceil(layoutManager.defaultLineHeight(for: meta.font))
            return NSRect(x: fragment.minX + padding + origin.x, y: used.maxY + meta.gap + origin.y,
                          width: max(0, fragment.width - 2 * padding), height: height)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: meta.location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: fragment.minX + padding + origin.x, y: fragment.minY + origin.y,
                      width: max(0, fragment.width - 2 * padding), height: fragment.height)
    }

    /// A click on a meta line drawn under the H1 opens the YAML, as a
    /// click on one in the block's own place does: there, the click
    /// lands inside the block by itself.
    override func mouseDown(with event: NSEvent) {
        if let meta = frontmatterMetaLine, meta.anchor != nil,
           let rect = frontmatterMetaLineRect(),
           rect.contains(convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: meta.block.location, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    private func drawFrontmatterMetaLine(in dirtyRect: NSRect) {
        guard let meta = frontmatterMetaLine, let rect = frontmatterMetaLineRect(),
              rect.intersects(dirtyRect) else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: meta.text, attributes: [
            .font: meta.font,
            .foregroundColor: meta.color,
            .paragraphStyle: para,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Paint the match set: translucent yellow over the other matches,
    /// solid yellow with the text redrawn dark and a hairline outline over
    /// the current one. Restricted to
    /// the glyphs intersecting `dirtyRect`, and — since matches are in
    /// document order — bailing out once we pass the dirty range, so a
    /// document with thousands of matches still only does layout work for
    /// the handful on screen.
    private func drawSearchHighlights(in dirtyRect: NSRect) {
        guard !searchMatchRanges.isEmpty,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let storage = textStorage else { return }
        let total = storage.length
        guard total > 0 else { return }
        let origin = textContainerOrigin

        // Character range covered by the area being drawn — used to skip
        // off-screen matches before doing any per-match layout math.
        let dirtyChars = Self.characterRange(coveredBy: dirtyRect, origin: origin,
                                             layoutManager: layoutManager,
                                             textContainer: textContainer)
        let lo = dirtyChars.location
        let hi = NSMaxRange(dirtyChars)

        let notSelected = NSRange(location: NSNotFound, length: 0)
        let folded = frontmatterMetaLine?.block

        for match in searchMatchRanges {
            guard match.length > 0, NSMaxRange(match) <= total else { continue }
            if match.location > hi { break }            // sorted — nothing left on screen
            if NSMaxRange(match) < lo { continue }       // before the dirty range
            if Self.isHidden(match, byFold: folded) { continue }
            let isCurrent = currentSearchMatch.map { NSEqualRanges($0, match) } ?? false
            let glyphRange = layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            let fill = isCurrent ? currentSearchHighlightColor : searchHighlightColor

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: notSelected,
                in: textContainer
            ) { r, _ in
                var hr = r
                hr.origin.x += origin.x
                hr.origin.y += origin.y
                hr = hr.insetBy(dx: -1, dy: 0.5)
                guard hr.intersects(dirtyRect) else { return }
                let path = NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3)
                fill.setFill()
                path.fill()
                if isCurrent {
                    self.redrawGlyphs(glyphRange, clippedTo: path, origin: origin)
                    self.currentSearchBorderColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }

    /// Characters whose glyphs lie in `rect`, given in VIEW coordinates.
    /// `glyphRange(forBoundingRect:in:)` takes container coordinates, so the
    /// container origin comes off first. Passing the view rect as is shifted
    /// the window down by the top inset (20 pt, more than a line): on a
    /// partial redraw — the strip a scroll exposes — matches in the top line
    /// of the strip were skipped and lost their highlight.
    static func characterRange(coveredBy rect: NSRect, origin: NSPoint,
                               layoutManager: NSLayoutManager,
                               textContainer: NSTextContainer) -> NSRange {
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: local, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// The solid fill covers the match's glyphs, so draw them again on top,
    /// recoloured: the glyphs go into a transparency layer, and a
    /// `sourceIn` fill keeps their shapes in `currentSearchTextColor`.
    /// Recolouring the drawn pixels (instead of a temporary foreground
    /// attribute) leaves concealed markers alone — they are drawn in
    /// `.clear`, have no coverage, and stay invisible.
    private func redrawGlyphs(_ glyphRange: NSRange, clippedTo path: NSBezierPath, origin: NSPoint) {
        guard let layoutManager, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        path.addClip()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(currentSearchTextColor.cgColor)
        ctx.fill(path.bounds)
        ctx.endTransparencyLayer()
    }

    private func registerForImageDrops() {
        let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.image")]
        registerForDraggedTypes(types)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        // ⌃Space → AI quick-picker. ⌃⌘1…⌃⌘9 → AI presets directly.
        // Both check `AIConfig.enabled` inside the handler so the
        // shortcut path is dead-cheap when AI is off (one bool fetch).
        if isAIPickerShortcut(event) {
            openAIPickerSheet()
            return
        }
        if let digit = aiPresetDigit(for: event) {
            triggerAIPreset(hotkey: digit)
            return
        }
        if let action = Self.keybindings.action(for: event) {
            runCommand(action)
            return
        }
        super.keyDown(with: event)
    }

    /// `⌃Space` — fuzzy picker over all AI presets. Hard-coded
    /// (doesn't go through the keybindings.json override) because the
    /// AI hook is opt-in and shouldn't surface in the override list
    /// before the user has explicitly enabled it.
    private func isAIPickerShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        return mods == .control && event.keyCode == 0x31  // 0x31 = space
    }

    /// `⌃⌘1`…`⌃⌘9` — direct invocation of AI presets bound to the
    /// matching hotkey. Returns the digit (1…9) or `nil` if the
    /// event isn't one of these combos. macOS keyCodes for the
    /// number row: 18=1, 19=2, 20=3, 21=4, 23=5, 22=6, 26=7,
    /// 28=8, 25=9.
    private func aiPresetDigit(for event: NSEvent) -> Int? {
        let mods = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        guard mods == [.control, .command] else { return nil }
        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    // MARK: - AI presets (opt-in)

    /// Statically-shared store. SwiftUI views in Settings use the
    /// same instance via `@StateObject`/`@EnvironmentObject`; the
    /// editor's keyDown path reads it directly. Keeping a single
    /// instance avoids two stores writing the same UserDefaults blob.
    @MainActor static let presetStore = AIPresetStore()

    /// Look up the preset bound to the given digit and execute it.
    /// No-ops when AI is off (with a friendly hint) or when no preset
    /// claims that hotkey.
    private func triggerAIPreset(hotkey: Int) {
        let cfg = AIConfig.load()
        guard cfg.enabled else {
            presentAIDisabledHint()
            return
        }
        guard let preset = Self.presetStore.preset(forHotkey: hotkey) else {
            // No preset assigned to this hotkey — silently no-op.
            // Don't bug the user with an alert for what's an empty slot.
            return
        }
        runPreset(preset)
    }

    /// The in-flight AI request, if any. One at a time per editor: a
    /// second hotkey press while waiting used to start a parallel request
    /// that inserted twice (and left the caret stuck in its "busy" grey).
    private var aiTask: Task<Void, Never>?
    /// Identifies the running request, so a cancelled one that finishes
    /// late can't clear the state of a newer one.
    private var aiRequestID: UUID?
    private var caretColorBeforeAI: NSColor?

    /// Esc cancels a running AI request; otherwise it's the usual
    /// NSTextView behaviour (completion).
    override func cancelOperation(_ sender: Any?) {
        if let task = aiTask {
            task.cancel()
            finishAIRequest(aiRequestID)
            return
        }
        super.cancelOperation(sender)
    }

    private func finishAIRequest(_ id: UUID?) {
        guard id == aiRequestID else { return }
        aiTask = nil
        aiRequestID = nil
        if let color = caretColorBeforeAI {
            insertionPointColor = color
            caretColorBeforeAI = nil
        }
    }

    /// `⌃Space` opens the fuzzy picker. The picker dismisses itself,
    /// then calls back here with the chosen preset.
    private func openAIPickerSheet() {
        let cfg = AIConfig.load()
        guard cfg.enabled else {
            presentAIDisabledHint()
            return
        }
        let presets = Self.presetStore.presets
        guard !presets.isEmpty else {
            presentAlert(title: "No AI presets",
                          info: "Add at least one preset in Settings → AI.")
            return
        }
        AIPickerSheet.present(over: self, presets: presets) { [weak self] picked in
            self?.runPreset(picked)
        }
    }

    /// Shared entry point for both hotkey + picker invocation paths.
    /// Dims the caret while the network call is in flight; restores
    /// it on completion / error.
    private func runPreset(_ preset: AIPreset) {
        guard aiTask == nil else {
            NSSound.beep()   // one request at a time; Esc cancels the running one
            return
        }
        var instruction: String?
        if preset.needsInstruction {
            guard let asked = askForInstruction(presetName: preset.name) else { return }
            instruction = asked
        }

        caretColorBeforeAI = insertionPointColor
        insertionPointColor = NSColor.disabledControlTextColor

        let requestID = UUID()
        aiRequestID = requestID
        aiTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await AICommandExecutor.run(preset: preset, instruction: instruction, in: self)
                self.finishAIRequest(requestID)
            } catch is CancellationError {
                self?.finishAIRequest(requestID)
            } catch {
                guard let self else { return }
                let wasCurrent = self.aiRequestID == requestID
                self.finishAIRequest(requestID)
                guard wasCurrent else { return }
                // Don't pop an alert for a window the user already closed.
                guard self.window != nil else { return }
                self.presentAlert(title: "AI command failed",
                                  info: error.localizedDescription)
            }
        }
    }

    /// "What should the AI do?" — for presets that carry no instruction of
    /// their own (like the starter "Custom Prompt"). `nil` on Cancel.
    private func askForInstruction(presetName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = presetName
        alert.informativeText = "What should the AI do with the selected text?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. Turn this into a table"
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func presentAIDisabledHint() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AI is off"
        alert.informativeText = """
            Enable AI in Settings → AI to use ⌃Space and ⌃⌘1…⌃⌘9.

            PicaMD supports Anthropic, OpenAI, Apple Intelligence (on this
            Mac, nothing leaves it) and your own OpenAI-compatible servers.
            API keys are stored in the macOS keychain.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsOpener.open()
        }
    }

    private func presentAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: - Action plumbing

    /// The editor a Format menu item acts on: the key window's first
    /// responder when that is an editor, else nil. Not
    /// `NSApp.sendAction(_:to:nil:from:)`: with another window key (the
    /// Link… sheet, Settings) it falls back to the main window's chain
    /// and reaches the editor behind it, so ⌘B typed in the sheet's URL
    /// field would bold the document. While the find field or the
    /// palette has the focus, the document is left alone too.
    static func formatMenuTarget(in keyWindow: NSWindow?) -> PicaMDTextView? {
        keyWindow?.firstResponder as? PicaMDTextView
    }

    /// Entry point of the Format menu (see `formatMenuTarget(in:)`).
    @objc func performEditorCommand(_ sender: Any?) {
        guard let command = sender as? EditorCommandSender else { return }
        runCommand(command.action)
    }

    /// Run one editor command on the selection as one undo step named
    /// after it (Edit ▸ Undo Bold).
    func runCommand(_ action: KeybindingAction) {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return }
        let oldText = storage.string
        let oldSelection = selectedRange()

        let result: MarkdownEdits.Result
        switch action {
        case .headingParagraph:
            result = MarkdownEdits.setHeading(level: 0, in: oldText, selection: oldSelection)
        case .headingH1:
            result = MarkdownEdits.setHeading(level: 1, in: oldText, selection: oldSelection)
        case .headingH2:
            result = MarkdownEdits.setHeading(level: 2, in: oldText, selection: oldSelection)
        case .headingH3:
            result = MarkdownEdits.setHeading(level: 3, in: oldText, selection: oldSelection)
        case .headingH4:
            result = MarkdownEdits.setHeading(level: 4, in: oldText, selection: oldSelection)
        case .headingH5:
            result = MarkdownEdits.setHeading(level: 5, in: oldText, selection: oldSelection)
        case .headingH6:
            result = MarkdownEdits.setHeading(level: 6, in: oldText, selection: oldSelection)
        case .moveLineUp:
            result = MarkdownEdits.moveLine(direction: .up, in: oldText, selection: oldSelection)
        case .moveLineDown:
            result = MarkdownEdits.moveLine(direction: .down, in: oldText, selection: oldSelection)
        case .duplicateLine:
            result = MarkdownEdits.duplicate(in: oldText, selection: oldSelection)
        case .selectLine:
            // Select-line doesn't change text — apply selection only.
            let r = MarkdownEdits.selectLine(in: oldText, selection: oldSelection)
            setSelectedRange(r.selection)
            return
        case .bold:
            result = MarkdownEdits.toggleInline(.bold, in: oldText, selection: oldSelection)
        case .italic:
            result = MarkdownEdits.toggleInline(.italic, in: oldText, selection: oldSelection)
        case .strikethrough:
            result = MarkdownEdits.toggleInline(.strikethrough, in: oldText, selection: oldSelection)
        case .inlineCode:
            result = MarkdownEdits.toggleInline(.code, in: oldText, selection: oldSelection)
        case .checklist:
            result = MarkdownEdits.toggleChecklist(in: oldText, selection: oldSelection)
        case .quote:
            result = MarkdownEdits.toggleQuote(in: oldText, selection: oldSelection)
        case .table:
            result = MarkdownEdits.insertTable(in: oldText, selection: oldSelection)
        case .link:
            promptForLink()
            return
        }
        applyCommandResult(result, oldText: oldText, actionName: action.undoActionName)
    }

    /// `applyResult` as its own undo step: never merged into the typing
    /// run before it, and named for Edit ▸ Undo.
    private func applyCommandResult(_ result: MarkdownEdits.Result, oldText: String, actionName: String?) {
        let changes = result.text != oldText
        if changes { breakUndoCoalescing() }
        applyResult(result, oldText: oldText)
        if changes, let actionName { undoManager?.setActionName(actionName) }
    }

    /// Format ▸ Link…: asks for the address in a sheet, prefilled with the
    /// URL of the link the caret is in, or with a URL on the pasteboard.
    private func promptForLink() {
        let text = string
        let selection = selectedRange()
        let existing = MarkdownEdits.link(enclosing: selection, in: text)
        let prefill = existing.map { (text as NSString).substring(with: $0.url) }
            ?? MarkdownEdits.linkCandidate(fromPasteboard: NSPasteboard.general.string(forType: .string))
            ?? ""

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Link" : "Edit Link"
        alert.informativeText = "Enter the address the link points to."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        field.stringValue = prefill
        alert.accessoryView = field
        alert.addButton(withTitle: existing == nil ? "Add Link" : "Change Link")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.window?.makeFirstResponder(self) }
            let url: String
            switch response {
            case .alertFirstButtonReturn: url = field.stringValue
            case .alertThirdButtonReturn: url = ""
            default: return
            }
            // The sheet only blocks this window: a reload from disk or an
            // AI insertion may have changed the text in the meantime.
            guard self.string == text else { NSSound.beep(); return }
            let result = MarkdownEdits.setLink(url: url, in: text, selection: selection)
            self.applyCommandResult(result, oldText: text,
                                    actionName: KeybindingAction.link.undoActionName)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Run an AI preset from the command palette, like ⌃⌘1…⌃⌘9.
    func runAIPresetFromPalette(_ preset: AIPreset) {
        guard AIConfig.load().enabled else {
            presentAIDisabledHint()
            return
        }
        runPreset(preset)
    }

    /// Applies a `MarkdownEdits.Result` to the text view through
    /// `shouldChangeText` / `didChangeText` so that undo is preserved.
    ///
    /// Only the span that actually differs is replaced. Replacing the
    /// whole storage (as this used to) gave every character the
    /// attributes of character 0 — a concealed `#` made the entire
    /// document invisible outside the re-highlighted viewport — and put a
    /// full copy of the document on the undo stack for every `(` typed.
    private func applyResult(_ result: MarkdownEdits.Result, oldText: String) {
        guard result.text != oldText else {
            setSelectedRange(result.selection)
            return
        }
        let change = Self.minimalChange(from: oldText, to: result.text)
        guard shouldChangeText(in: change.range, replacementString: change.replacement) else { return }
        textStorage?.replaceCharacters(in: change.range, with: change.replacement)
        setSelectedRange(result.selection)
        didChangeText()
    }

    /// The smallest UTF-16 range of `old` that must be replaced (and with
    /// what) to produce `new`: strip the common prefix and suffix.
    static func minimalChange(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let a = old as NSString
        let b = new as NSString
        let aLen = a.length, bLen = b.length
        var prefix = 0
        let maxPrefix = min(aLen, bLen)
        while prefix < maxPrefix, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        let maxSuffix = min(aLen, bLen) - prefix
        while suffix < maxSuffix,
              a.character(at: aLen - 1 - suffix) == b.character(at: bLen - 1 - suffix) { suffix += 1 }
        // Never split a surrogate pair at either edge.
        if prefix > 0, prefix < aLen, CFStringIsSurrogateLowCharacter(a.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, aLen - suffix > prefix,
           CFStringIsSurrogateLowCharacter(a.character(at: aLen - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: aLen - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix, length: bLen - prefix - suffix))
        return (range, replacement)
    }

    // MARK: - Readable column (Settings ▸ Appearance ▸ Line width)

    /// Width of the text column in points; `.infinity` = edge to edge
    /// (the fixed `EditorLayout.textContainerInsetWidth` margin). Set from
    /// the theme's line width and body font.
    var readableColumnWidth: CGFloat = .infinity {
        didSet {
            if readableColumnWidth != oldValue { updateReadableInset() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadableInset()
    }

    /// Centres the column by widening the container's side inset. Every
    /// consumer (overlays, checkboxes, typewriter scrolling, AI ghost
    /// text) reads `textContainerInset` at run time, so nothing else needs
    /// to know about the column. Applied only on a change of more than
    /// half a point: setting the inset relayouts the text, which can
    /// resize this view vertically and call back in here.
    /// - Returns: whether the inset changed.
    @discardableResult
    func updateReadableInset() -> Bool {
        let target = EditorLayout.horizontalInset(
            containerWidth: bounds.width,
            columnWidth: readableColumnWidth,
            lineFragmentPadding: textContainer?.lineFragmentPadding ?? 0)
        guard abs(target - textContainerInset.width) > 0.5 else { return false }
        textContainerInset = NSSize(width: target, height: textContainerInset.height)
        return true
    }

    // MARK: - Exact edit spans for Reflow Mode

    /// Gets the exact spans of every allowed change, which the text storage's
    /// own edit notification widens (see `ReflowLayoutDelegate`).
    weak var reflowDelegate: ReflowLayoutDelegate?

    override func shouldChangeText(inRanges affectedRanges: [NSValue],
                                   replacementStrings: [String]?) -> Bool {
        startNewTypingActionAfterSave()
        let allowed = super.shouldChangeText(inRanges: affectedRanges,
                                             replacementStrings: replacementStrings)
        // A nil replacement announces an attributes-only change.
        if allowed, let strings = replacementStrings, strings.count == affectedRanges.count {
            reflowDelegate?.noteUpcomingEdit(zip(affectedRanges, strings).map {
                .init(range: $0.rangeValue, replacementLength: ($1 as NSString).length)
            })
        }
        return allowed
    }

    /// NSDocument counts a change only when an undo group closes with an
    /// action in it, and the text view folds typing that continues without
    /// a caret move into its open "Typing" action, registering nothing.
    /// Typing that went on after a save or an autosave therefore left the
    /// document clean: no save prompt on close, nothing for the next
    /// autosave to write, and a silent revert on an external change.
    /// (SwiftUI's own undo registration on every binding write used to hide
    /// this.) Breaking the coalescing once the document has nothing pending
    /// makes the edit a new action, as TextEdit does on save; undoing it
    /// then lands exactly on the saved text. One break per undo group:
    /// later changes before the group closes (auto-pairing, a second
    /// keystroke in the same event) join the action the first one started,
    /// and once the group closes the document is edited again.
    private func startNewTypingActionAfterSave() {
        guard !brokeCoalescingInOpenGroup,
              let undoManager, !undoManager.isUndoing, !undoManager.isRedoing,
              let window,
              let document = NSDocumentController.shared.document(for: window),
              !document.isDocumentEdited || !document.hasUnautosavedChanges else { return }
        breakUndoCoalescing()
        brokeCoalescingInOpenGroup = true
    }

    private var brokeCoalescingInOpenGroup = false
    private var observesUndoGroups = false

    @objc private func undoGroupDidClose(_ note: Notification) {
        guard let undoManager, (note.object as AnyObject?) === undoManager else { return }
        brokeCoalescingInOpenGroup = false
    }

    override func didChangeText() {
        reflowDelegate?.discardPendingEdit()
        super.didChangeText()
    }

    /// Return types the document's own line break. AppKit inserts a bare
    /// "\n", which in a CRLF file gives mixed line endings that the
    /// CRLF-aware line edits and other Windows tools then
    /// see as a different kind of line.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage,
              MarkdownEdits.documentLineBreak(in: storage.string as NSString) == "\r\n" else {
            super.insertNewline(sender)
            return
        }
        insertText("\r\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Auto-pair + smart-punctuation hooks

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String, !str.isEmpty else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Compute the effective replacement range. If the caller passes
        // an empty range, NSTextView wants us to use selectedRange().
        let effectiveRange = replacementRange.location == NSNotFound
            ? selectedRange()
            : replacementRange

        // Auto-skip closing bracket if the next char is the same.
        if autoPairEnabled,
           let skip = MarkdownEdits.autoSkip(closing: str,
                                             in: textStorage?.string ?? "",
                                             selection: effectiveRange) {
            setSelectedRange(skip.selection)
            return
        }

        // Auto-pair openings. Skipped while composing (dead keys / IME:
        // the backtick is a dead key on German layouts).
        if autoPairEnabled, str.count == 1, !hasMarkedText(),
           let pair = MarkdownEdits.autoPair(input: str,
                                              in: textStorage?.string ?? "",
                                              selection: effectiveRange) {
            applyResult(pair, oldText: textStorage?.string ?? "")
            return
        }

        // Default insertion path
        super.insertText(string, replacementRange: replacementRange)

        // After the default insert, try smart punctuation rewrites.
        // The trigger test comes first: `smartPunctuationAllowed` scans every
        // line above the caret, and must not run for each typed letter.
        if smartPunctuationEnabled, MarkdownEdits.isSmartPunctuationTrigger(str), !hasMarkedText(),
           MarkdownEdits.smartPunctuationAllowed(in: textStorage?.string ?? "",
                                                  at: selectedRange().location),
           let smart = MarkdownEdits.smartPunctuation(after: str,
                                                       in: textStorage?.string ?? "",
                                                       selection: selectedRange()) {
            applyResult(smart, oldText: textStorage?.string ?? "")
        }
    }

    // MARK: - Image drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if pasteboardHasImage(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if pasteboardHasImage(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let dropIndex = charIndexForDrop(at: dropPoint)

        // 1. File URLs (drag from Finder, Photos, browsers, etc.)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let imageURLs = urls.filter { isImageFile($0) }
            if !imageURLs.isEmpty {
                guard documentURL != nil else {
                    presentSaveFirstAlert()
                    return false
                }
                insertImages(from: imageURLs, at: dropIndex)
                return true
            }
        }

        // 2. Raw image data on the pasteboard (drag-out from Preview, screenshots)
        if let (data, kind) = pasteboardImageData(pb) {
            guard documentURL != nil else {
                presentSaveFirstAlert()
                return false
            }
            insertImageData(data, kind: kind, at: dropIndex)
            return true
        }

        return super.performDragOperation(sender)
    }

    /// Compute the character index inside the text view for a drop point
    /// in the view's own coordinates.
    private func charIndexForDrop(at point: NSPoint) -> Int {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return selectedRange().location
        }
        // Compensate for the text container's origin within the view.
        let originAdjusted = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: originAdjusted, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    private func pasteboardHasImage(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: nil) {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               urls.contains(where: { isImageFile($0) }) {
                return true
            }
        }
        if pb.data(forType: .png) != nil { return true }
        if pb.data(forType: .tiff) != nil { return true }
        return false
    }

    private func pasteboardImageData(_ pb: NSPasteboard) -> (Data, MarkdownAssets.ImageKind)? {
        // Prefer PNG (lossless, smaller for screenshots).
        if let png = pb.data(forType: .png) {
            return (png, .pasted)
        }
        // Fall back to TIFF, convert to PNG for stability.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, .pasted)
        }
        return nil
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return UTType.isImage(type)
        }
        // Fallback: extension match
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "tiff", "heic", "bmp", "webp"].contains(ext)
    }

    /// Show a polite "save first" alert when the user drops an image
    /// into an untitled document. Without a document URL we have no
    /// folder to copy assets into.
    private func presentSaveFirstAlert() {
        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save the document first"
        alert.informativeText = "Images are copied into a `./assets/` folder next to the document. Save this file (⌘S) so PicaMD knows where to put them."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window) { _ in }
    }

    private func insertImages(from urls: [URL], at index: Int) {
        // Filesystem copy on the main thread freezes the UI for big
        // PNGs (F5 in adversarial review). Hop to a background queue
        // for the I/O, then come back to main to insert the markdown.
        let docURL = documentURL
        Task.detached(priority: .userInitiated) { [weak self] in
            var insertion = ""
            for (i, url) in urls.enumerated() {
                do {
                    if let saved = try MarkdownAssets.copyImage(from: url, nextTo: docURL) {
                        if i > 0 { insertion += "\n\n" }
                        insertion += MarkdownAssets.markdownSyntax(for: saved)
                    }
                } catch {
                    NSLog("PicaMD: image copy failed for \(url): \(error)")
                }
            }
            guard !insertion.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.safeInsert(insertion, at: index)
            }
        }
    }

    private func insertImageData(_ data: Data, kind: MarkdownAssets.ImageKind, at index: Int) {
        let docURL = documentURL
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if let saved = try MarkdownAssets.saveImageData(data, kind: kind, nextTo: docURL) {
                    let md = MarkdownAssets.markdownSyntax(for: saved)
                    await MainActor.run { [weak self] in
                        self?.safeInsert(md, at: index)
                    }
                }
            } catch {
                NSLog("PicaMD: image save failed: \(error)")
            }
        }
    }

    /// Insert text at `requestedIndex`, but clamp to the storage's
    /// current length — by the time the async copy returns, the user
    /// may have edited or deleted enough text that the original index
    /// is past the end of the buffer.
    private func safeInsert(_ string: String, at requestedIndex: Int) {
        let total = (textStorage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(requestedIndex, total))
        insertText(string, replacementRange: NSRange(location: clamped, length: 0))
    }

    // MARK: - Image-aware paste (Cmd+V)

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let (data, kind) = pasteboardImageData(pb) {
            insertImageData(data, kind: kind, at: selectedRange().location)
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { isImageFile($0) }
            if !imageURLs.isEmpty {
                insertImages(from: imageURLs, at: selectedRange().location)
                return
            }
        }
        super.paste(sender)
    }

    // MARK: - Factory: scrollable view holding a PicaMDTextView

    /// Builds an `NSScrollView` wrapping a `PicaMDTextView` configured
    /// the same way as `NSTextView.scrollableTextView()` would.
    static func makeScrollable() -> (NSScrollView, PicaMDTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            size: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = PicaMDTextView(
            frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return (scrollView, textView)
    }
}

/// The sender of `PicaMDTextView.performEditorCommand(_:)`: SwiftUI menu
/// buttons have no sender of their own, so the command rides along.
final class EditorCommandSender: NSObject {
    let action: KeybindingAction

    init(_ action: KeybindingAction) {
        self.action = action
    }
}
