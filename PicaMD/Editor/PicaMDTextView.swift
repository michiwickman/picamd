import AppKit
import UniformTypeIdentifiers

/// `NSTextView` subclass that intercepts Markdown-editor shortcuts
/// before they reach the standard text-input pipeline:
///
///   ⌘1…6      Set heading level (toggle off when same level)
///   ⌘0        Make the current line a paragraph
///   ⌘⌥↑/↓     Move the current line(s) up / down
///   ⌘⇧D       Duplicate the current line / selection
///   ⌘L        Select the whole current line
///
/// All other keys fall through to the default behaviour.
final class PicaMDTextView: NSTextView {

    /// Master toggle for the smart-punctuation rewrites done in
    /// `insertText(_:replacementRange:)`. Defaults to `true`; can be
    /// disabled by user preference later.
    var smartPunctuationEnabled: Bool = true

    /// Master toggle for auto-pairing brackets/quotes. Defaults to `true`.
    var autoPairEnabled: Bool = true

    // MARK: - Find-bar match highlighting

    /// Match ranges from the find bar, in document order. Drawn as
    /// translucent rounded rects ON TOP of the glyphs in `draw(_:)` so
    /// they stay visible regardless of any concealed markup or attribute
    /// backgrounds (inline code, table rows) underneath. The coordinator
    /// keeps these in sync with the `SearchModel`.
    private var searchMatchRanges: [NSRange] = []
    /// The currently-focused match — stronger fill + a solid border.
    private var currentSearchMatch: NSRange?
    /// Fill for non-current matches; set from the theme accent by the
    /// coordinator. Translucent so the text reads through it.
    var searchHighlightColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.30)
    /// Fill + border for the current match.
    var currentSearchHighlightColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.45)
    var currentSearchBorderColor: NSColor = NSColor.systemOrange

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
        drawSearchHighlights(in: dirtyRect)
    }

    /// Paint translucent rects over the current match set. Restricted to
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
        let dirtyGlyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        let dirtyChars = layoutManager.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)
        let lo = dirtyChars.location
        let hi = NSMaxRange(dirtyChars)

        let notSelected = NSRange(location: NSNotFound, length: 0)

        for match in searchMatchRanges {
            guard match.length > 0, NSMaxRange(match) <= total else { continue }
            if match.location > hi { break }            // sorted — nothing left on screen
            if NSMaxRange(match) < lo { continue }       // before the dirty range
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
                let path = NSBezierPath(roundedRect: hr, xRadius: 2.5, yRadius: 2.5)
                fill.setFill()
                path.fill()
                if isCurrent {
                    self.currentSearchBorderColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }

    private func registerForImageDrops() {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        if #available(macOS 10.14, *) {
            types.append(NSPasteboard.PasteboardType("public.image"))
        }
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
            performAction(action)
            return
        }
        super.keyDown(with: event)
    }

    /// `⌃Space` — fuzzy picker over all AI presets. Hard-coded
    /// (doesn't go through the keybindings.json override) because the
    /// AI hook is opt-in and shouldn't surface in the override list
    /// before the user has explicitly enabled it.
    private func isAIPickerShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods == .control && event.keyCode == 0x31  // 0x31 = space
    }

    /// `⌃⌘1`…`⌃⌘9` — direct invocation of AI presets bound to the
    /// matching hotkey. Returns the digit (1…9) or `nil` if the
    /// event isn't one of these combos. macOS keyCodes for the
    /// number row: 18=1, 19=2, 20=3, 21=4, 23=5, 22=6, 26=7,
    /// 28=8, 25=9.
    private func aiPresetDigit(for event: NSEvent) -> Int? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        let busyColor = NSColor.disabledControlTextColor
        let originalColor = self.insertionPointColor
        self.insertionPointColor = busyColor

        Task { @MainActor [weak self] in
            defer { self?.insertionPointColor = originalColor }
            guard let self = self else { return }
            do {
                try await AICommandExecutor.run(preset: preset, in: self)
            } catch {
                self.presentAlert(title: "AI command failed",
                                   info: error.localizedDescription)
            }
        }
    }

    private func presentAIDisabledHint() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AI is off"
        alert.informativeText = """
            Enable AI in Settings → AI to use ⌃Space and ⌃⌘1…⌃⌘9.

            PicaMD supports Anthropic, OpenAI, and local OpenAI-compatible
            servers (LM Studio, Ollama). API keys are stored in the macOS
            keychain. Local-only setups never reach the network.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

    private func performAction(_ action: KeybindingAction) {
        guard let storage = textStorage else { return }
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
        }

        applyResult(result, oldText: oldText)
    }

    /// Applies a `MarkdownEdits.Result` to the text view through
    /// `shouldChangeText` / `didChangeText` so that undo is preserved.
    private func applyResult(_ result: MarkdownEdits.Result, oldText: String) {
        guard result.text != oldText else {
            setSelectedRange(result.selection)
            return
        }
        let fullRange = NSRange(location: 0, length: (oldText as NSString).length)
        guard shouldChangeText(in: fullRange, replacementString: result.text) else { return }
        textStorage?.replaceCharacters(in: fullRange, with: result.text)
        setSelectedRange(result.selection)
        didChangeText()
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

        // Auto-pair openings.
        if autoPairEnabled, str.count == 1,
           let pair = MarkdownEdits.autoPair(input: str,
                                              in: textStorage?.string ?? "",
                                              selection: effectiveRange) {
            applyResult(pair, oldText: textStorage?.string ?? "")
            return
        }

        // Default insertion path
        super.insertText(string, replacementRange: replacementRange)

        // After the default insert, try smart punctuation rewrites.
        if smartPunctuationEnabled, str.count == 1,
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
