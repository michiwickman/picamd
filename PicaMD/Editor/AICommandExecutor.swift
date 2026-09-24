import AppKit

/// Runs an `AIPreset` against the user's current selection in an
/// `NSTextView` and applies the response according to the preset's
/// `insertionMode`. Pulled out of `PicaMDTextView` so the logic
/// (selection-extraction, prompt-resolution, insertion) is testable
/// without a live view.
@MainActor
struct AICommandExecutor {

    enum FailureReason: LocalizedError {
        case aiDisabled
        case noTextView
        case invalidEndpoint
        case emptyPrompt
        case providerError(Error)

        var errorDescription: String? {
            switch self {
            case .aiDisabled:           return "AI is off — enable it in Settings → AI"
            case .noTextView:           return "No active editor"
            case .invalidEndpoint:      return "AI endpoint URL is invalid — check Settings → AI"
            case .emptyPrompt:          return "There's no text to send — select some text or put the cursor in a paragraph."
            case .providerError(let e): return e.localizedDescription
            }
        }
    }

    /// Read the current selection (or the cursor's paragraph if no
    /// selection), build the prompt, send it to the configured
    /// provider, and apply the response according to `preset.insertionMode`.
    ///
    /// Long-running: the network call is awaited inside the function.
    /// Caller should provide visual feedback (cursor dim, spinner)
    /// before invoking.
    static func run(preset: AIPreset, instruction: String? = nil, in textView: NSTextView) async throws {
        let config = AIConfig.load()
        guard config.enabled else { throw FailureReason.aiDisabled }

        let provider = preset.providerOverride ?? config.defaultProvider
        let model = preset.modelOverride ?? config.model(for: provider)
        let endpoint = config.endpoint(for: provider)
        let apiKey = Keychain.get(account: provider.keychainAccount)

        guard let client = AIClient(
            provider: provider,
            endpointString: endpoint,
            model: model,
            apiKey: apiKey
        ) else {
            throw FailureReason.invalidEndpoint
        }

        guard let storage = textView.textStorage else { throw FailureReason.noTextView }
        let source = storage.string
        let selection = textView.selectedRange()
        let context = SelectionContext.derive(from: source, range: selection)
        guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FailureReason.emptyPrompt
        }

        let prompt = preset.resolvePrompt(selection: context.text, instruction: instruction)
        let response: String
        do {
            response = try await client.complete(
                userPrompt: prompt,
                systemPrompt: preset.systemPrompt
            )
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()   // Esc — not a failure to report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FailureReason.providerError(error)
        }
        try Task.checkCancellation()

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // The editor stays editable while the request is in flight (up
        // to two minutes). Re-find the text the prompt was built from
        // before touching the buffer: inserting at the old offsets
        // after the user typed elsewhere would overwrite their new text,
        // and after a deletion the range could run past the end.
        guard let anchor = relocate(context, in: storage.string) else {
            showResponsePopover(trimmed, near: textView, anchor: textView.selectedRange(),
                                note: "The text changed while waiting, so the response wasn't inserted.")
            return
        }
        var current = context
        current.anchorRange = anchor
        applyResponse(trimmed, preset: preset, context: current, in: textView)
    }

    /// Where the context's text lives now: the original range if it's
    /// untouched, else the occurrence closest to it. `nil` if it's gone.
    static func relocate(_ context: SelectionContext, in source: String) -> NSRange? {
        let ns = source as NSString
        let original = context.anchorRange
        if NSMaxRange(original) <= ns.length, ns.substring(with: original) == context.text {
            return original
        }
        guard !context.text.isEmpty else { return nil }
        var best: NSRange?
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: context.text, options: [.literal], range: searchRange)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - original.location) < abs(best!.location - original.location) {
                best = found
            }
            let next = found.location + 1
            guard next < ns.length else { break }
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return best
    }

    // MARK: - Selection extraction

    struct SelectionContext {
        /// The text the user prompt was derived from. Either the
        /// explicit selection, or the cursor's paragraph if none.
        var text: String
        /// Range to use as the "anchor" for insertion. Equals the
        /// selection when there was one, otherwise the paragraph
        /// range so "append below" puts the response after the
        /// paragraph.
        var anchorRange: NSRange
        /// `true` if the user explicitly selected something. When
        /// `false`, replace-modes downgrade to append-modes
        /// automatically (we never wipe an unselected paragraph).
        var hasExplicitSelection: Bool

        static func derive(from source: String, range: NSRange) -> SelectionContext {
            let nsSource = source as NSString
            if range.length > 0 {
                return SelectionContext(
                    text: nsSource.substring(with: range),
                    anchorRange: range,
                    hasExplicitSelection: true
                )
            }
            // Empty selection → use the paragraph the cursor sits in.
            let paragraph = nsSource.paragraphRange(for: range)
            return SelectionContext(
                text: nsSource.substring(with: paragraph),
                anchorRange: paragraph,
                hasExplicitSelection: false
            )
        }
    }

    // MARK: - Insertion

    /// Apply `response` to `textView` according to `preset.insertionMode`.
    /// Goes through `shouldChangeText`/`didChangeText` so undo + the
    /// highlighter pick the change up properly.
    private static func applyResponse(
        _ response: String,
        preset: AIPreset,
        context: SelectionContext,
        in textView: NSTextView
    ) {
        // Resolve effective insertion mode. If the user invoked a
        // replace-mode preset without an explicit selection, downgrade
        // to "appendBelow" — we won't risk wiping a whole paragraph
        // they didn't intentionally highlight.
        let mode: AIPreset.InsertionMode
        if preset.insertionMode == .replaceSelection && !context.hasExplicitSelection {
            mode = .appendBelow
        } else {
            mode = preset.insertionMode
        }

        let source = textView.string
        switch mode {
        case .replaceSelection:
            // The response comes back trimmed; keep the selection's own
            // leading/trailing whitespace so replacing `Line A\n` (a
            // triple-click or ⌘L selection) doesn't glue the result onto
            // the next line.
            let (lead, trail) = surroundingWhitespace(of: context.text)
            replace(in: textView, range: context.anchorRange, with: lead + response + trail)
        case .appendBelow:
            insertBlock(response, after: context.anchorRange, in: source, textView: textView)
        case .asBlockquote:
            let quoted = response
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
            insertBlock(quoted, after: context.anchorRange, in: source, textView: textView)
        case .asHTMLComment:
            let escaped = response
                .replacingOccurrences(of: "-->", with: "-- >")
            insertBlock("<!--\n\(escaped)\n-->", after: context.anchorRange, in: source, textView: textView)
        case .showInPopover:
            showResponsePopover(response, near: textView, anchor: context.anchorRange)
        }
    }

    /// Leading and trailing whitespace (incl. newlines) of `text`.
    static func surroundingWhitespace(of text: String) -> (String, String) {
        let lead = text.prefix { $0.isWhitespace || $0.isNewline }
        guard lead.count < text.count else { return (String(lead), "") }
        let trail = text.reversed().prefix { $0.isWhitespace || $0.isNewline }
        return (String(lead), String(trail.reversed()))
    }

    /// Insert `block` as its own Markdown block after the block that
    /// contains the end of `anchor` — never mid-sentence (partial
    /// selection) or between the lines of a hard-wrapped paragraph —
    /// with a blank line on both sides so it can't merge into its
    /// neighbours (a quote would otherwise swallow the next line).
    private static func insertBlock(_ block: String, after anchor: NSRange,
                                    in source: String, textView: NSTextView) {
        let target = blockEnd(after: anchor, in: source)
        let ns = source as NSString
        let rest = ns.substring(from: target)
        let trailer: String
        if rest.isEmpty {
            trailer = "\n"
        } else if rest.hasPrefix("\n\n") || rest.hasPrefix("\n\r\n")
                    || rest.trimmingCharacters(in: .newlines).isEmpty {
            trailer = ""   // a blank line follows already, or only the final newline
        } else {
            trailer = "\n"
        }
        let insertion = "\n\n" + block + trailer
        replace(in: textView, range: NSRange(location: target, length: 0), with: insertion)
    }

    /// Offset of the end of the Markdown block (paragraph, list, quote…)
    /// that contains the end of `anchor`: the newline before the next
    /// blank line, or the end of the document.
    static func blockEnd(after anchor: NSRange, in source: String) -> Int {
        let ns = source as NSString
        let length = ns.length
        // Start inside the anchor's last line, even when the anchor is a
        // whole paragraph range that already includes its newline.
        var start = min(NSMaxRange(anchor), length)
        if start > anchor.location, start > 0, ns.character(at: start - 1) == 0x0A {
            start -= 1
        }
        var lineStart = start
        while lineStart < length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentEnd = lineContentEnd(lineRange, in: ns)
            let nextStart = NSMaxRange(lineRange)
            if nextStart >= length { return contentEnd }
            let nextLine = ns.substring(with: ns.lineRange(for: NSRange(location: nextStart, length: 0)))
            if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return contentEnd
            }
            lineStart = nextStart
        }
        return length
    }

    private static func lineContentEnd(_ lineRange: NSRange, in ns: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let c = ns.character(at: end - 1)
            guard c == 0x0A || c == 0x0D else { break }
            end -= 1
        }
        return end
    }

    private static func replace(in textView: NSTextView, range: NSRange, with text: String) {
        // Keep the AI edit its own undo step, separate from whatever the
        // user typed just before triggering it.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.undoManager?.setActionName("AI Edit")
        let nsText = text as NSString
        let newCursor = NSRange(location: range.location + nsText.length, length: 0)
        textView.setSelectedRange(newCursor)
    }

    /// Floating popover for the "Show in popover" insertion mode —
    /// lets the user read the response without committing to inserting
    /// it. Anchored to the bounding rect of the selection (or
    /// paragraph) so it appears next to the relevant text.
    private static func showResponsePopover(
        _ text: String,
        near textView: NSTextView,
        anchor: NSRange,
        note: String? = nil
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: anchor,
                                                    actualCharacterRange: nil)
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                    in: textContainer)
        let inset = textView.textContainerInset
        let positioningRect = NSRect(
            x: bounding.midX + inset.width,
            y: bounding.maxY + inset.height,
            width: 1,
            height: 1
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 220)

        // `scrollableTextView()` wires the text view's frame, resizing
        // and container tracking; a bare `NSTextView()` inside a scroll
        // view stays zero-sized, which left this popover empty.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        scroll.drawsBackground = false
        if let label = scroll.documentView as? NSTextView {
            label.isEditable = false
            label.isSelectable = true
            label.drawsBackground = false
            label.textContainerInset = NSSize(width: 12, height: 12)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.string = note.map { $0 + "\n\n" + text } ?? text
        }

        let host = NSViewController()
        host.view = scroll
        popover.contentViewController = host
        popover.show(relativeTo: positioningRect, of: textView, preferredEdge: .maxY)
    }
}
