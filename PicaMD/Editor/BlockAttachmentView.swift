import AppKit

/// Base class for an inline-rendered block (table / image / math / mermaid).
/// Lives as a subview of NSTextView so it scrolls naturally with the document.
///
/// Concrete subclasses live in their own files:
///   `TableBlockView`   — pipe-tables drawn natively
///   `ImageBlockView`   — `![](src)` images, file:// or http(s)
///   `MathBlockView`    — `$$…$$` via KaTeX in a WKWebView
///   `MermaidBlockView` — ` ```mermaid…``` ` via mermaid.js in a WKWebView
class BlockAttachmentView: NSView {
    let block: ExtractedBlock
    var documentURL: URL?

    init(block: ExtractedBlock, documentURL: URL?) {
        self.block = block
        self.documentURL = documentURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setupContent()
        // React to the user changing palette/accent in Settings: WKWebView-backed
        // subclasses need to rebuild their HTML with the new colours. Plain
        // AppKit subclasses (Table/Image) override `appearanceChanged` to
        // re-tint via `applyColors()`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeStore.themeChangedNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Subclasses implement layout/content here.
    func setupContent() {}

    /// Subclasses report a desired height for the given proposed width.
    func desiredHeight(for width: CGFloat) -> CGFloat { 60 }

    /// Subclasses get a chance to reload when appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged()
    }

    func appearanceChanged() {}

    @objc nonisolated private func themeDidChange() {
        // Notification can fire on any thread. `@objc nonisolated` lets the
        // ObjC runtime invoke this from any queue without tripping the
        // @MainActor entry assertion that Swift 6 strict-concurrency inserts
        // for NSView-derived classes — the same assertion that crashed
        // `documentWillWrite` with `_dispatch_assert_queue_fail`. Hopping
        // into a @MainActor Task does what the old `Thread.isMainThread`
        // branch tried to do, but survives the entry-time isolation check.
        Task { @MainActor [weak self] in
            self?.appearanceChanged()
        }
    }

    /// Mirrors the user's selected palette (set by `ThemeStore`). Falls
    /// back to system appearance if the palette mirror hasn't been
    /// initialised yet (shouldn't happen — `ThemeStore` is created at
    /// app startup before any block views — but stays defensive).
    var isDark: Bool {
        ThemeStore.currentPalette.isDark
    }
}
