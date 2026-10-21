import Foundation
import CoreGraphics

/// Tuning knobs that used to live as magic numbers scattered through
/// the editor. Centralised so the team can tweak feel without hunt-
/// and-peck across files.
///
/// Group conventions:
///   `Timing`   — debounce / throttle delays (milliseconds)
///   `Layout`   — paddings, margins, line-spacings, container insets
///   `Buffer`   — viewport / scroll-buffer sizes
///   `Font`     — base sizes, conceal sizes
///   `Block`    — overlay defaults
enum EditorTiming {
    /// Highlighter pass after a text change. Fast-but-not-flicker.
    static let highlightDebounceMs: Int = 50
    /// Highlighter pass after a cursor move (concealment refresh).
    /// Snappier than text-change because users expect markup to
    /// appear/disappear immediately when stepping in/out of a span.
    static let cursorMoveHighlightDebounceMs: Int = 16
    /// Highlighter pass after a window/frame resize.
    static let frameChangeHighlightDebounceMs: Int = 30
    /// FileWatcher: vnode events within this window of our own save
    /// are treated as our own (not as external edits).
    static let selfWriteIgnoreInterval: TimeInterval = 1.5
    /// `BlockOverlayManager.refreshLiveSet()` debounce after the user
    /// stops scrolling. Long enough to coalesce a 60-Hz scroll burst
    /// into a single re-evaluation, short enough that promoted blocks
    /// pop in before the user notices the placeholder. 150 ms feels
    /// right in testing.
    static let lazyLiveSetDebounceMs: Int = 150
    /// Find bar: re-match after the query or options change. Short enough
    /// to feel live, long enough to skip intermediate keystrokes on big docs.
    static let searchQueryDebounceMs: Int = 30
    /// Find bar: refresh counts/highlights after the document is edited
    /// while the bar is open.
    static let searchRefreshDebounceMs: Int = 80
    /// Outline, front matter and the word/character counts after an edit.
    static let derivedStateDebounceMs: Int = 150
}

enum EditorLayout {
    /// Inset of the text container inside the NSTextView.
    static let textContainerInsetWidth: CGFloat = 24
    static let textContainerInsetHeight: CGFloat = 20
    /// Padding around the editor card in the Tahoe preset.
    static let tahoeCardPaddingTop: CGFloat = 14
    static let tahoeCardPaddingHorizontal: CGFloat = 16
    static let tahoeCardCornerRadius: CGFloat = 12
    /// Default minimum width per overlay block view.
    static let blockOverlayMinWidth: CGFloat = 120
    /// The ONLY vertical padding in the block-overlay pipeline. The three
    /// stages must stay in this exact relationship:
    ///   * the block view reports **pure content height** `C`;
    ///   * the highlighter reserves a line band of `C + blockOverlayHeightPadding`;
    ///   * `reposition()` insets the frame by half of it top and bottom,
    ///     giving a frame of exactly `C` with equal air above and below.
    /// Previously each stage carried its own literal (+8 in the view, +8 in
    /// the highlighter, +2/−6 in the frame), which did not cancel: every
    /// table ended up with 10 pt of dead space inside its border box and sat
    /// 6 pt above the optical centre of the space it occupied.
    static let blockOverlayHeightPadding: CGFloat = 8
    /// Horizontal breathing room subtracted from the usable line-fragment
    /// width to get an overlay's frame width, so a block doesn't touch the
    /// text's right edge. This is the ONLY place the inset is defined —
    /// `BlockOverlayManager.contentWidth()` derives both the measured and
    /// the drawn width from it, and they must never diverge (see there).
    static let blockOverlayHorizontalInset: CGFloat = 4

    /// Side inset of the text container that centres a column of
    /// `columnWidth` points of text (Settings ▸ Appearance ▸ Line width)
    /// in a text view `containerWidth` points wide. The line fragment
    /// padding sits inside the container on both sides, so it is
    /// subtracted to make the text itself — not the container —
    /// `columnWidth` wide. Rounded down to whole points; never below
    /// `minInset`, so a narrow window or `.infinity` (Full) keeps the
    /// fixed margin of 0.9.
    static func horizontalInset(containerWidth: CGFloat,
                                columnWidth: CGFloat,
                                minInset: CGFloat = textContainerInsetWidth,
                                lineFragmentPadding: CGFloat) -> CGFloat {
        guard columnWidth.isFinite, containerWidth.isFinite else { return minInset }
        let centred = ((containerWidth - columnWidth) / 2 - lineFragmentPadding).rounded(.down)
        return max(minInset, centred)
    }
}

enum EditorBuffer {
    /// Characters of context kept on each side of the visible viewport
    /// when running an incremental highlight pass. Large enough to
    /// cover any inline-markup or block boundary that crosses the
    /// viewport edge in real-world docs.
    static let viewportContext: Int = 4000
    /// Target chunk size (characters) for the progressive full-document
    /// re-highlight that runs after a theme / dark-mode change. Small
    /// enough that each chunk's inline passes finish in well under a
    /// frame so the `Task.yield()` between chunks keeps typing and
    /// scrolling responsive; the actual chunk end snaps to the next
    /// newline so an inline construct is never split across a boundary.
    static let progressiveChunkChars: Int = 8000
}

enum EditorFont {
    /// Default body size when no theme has overridden it.
    static let defaultBaseSize: CGFloat = 15
    /// Tiny size used to "conceal" markup characters without removing
    /// them from the buffer.
    static let concealedSize: CGFloat = 0.01
}

enum EditorBlockDefaults {
    /// Heights reserved for overlay blocks before their real size is
    /// reported (web views measure async; tables / images measure sync).
    static let table: CGFloat = 100
    static let image: CGFloat = 220
    static let mathBlock: CGFloat = 100
    static let mermaid: CGFloat = 200
}

/// User-facing editor and launch toggles (Settings ▸ Editor and
/// General), stored in `UserDefaults` and read directly where they apply
/// (the text view reads the typing toggles per keystroke).
enum EditorPreferences {
    static let autoPairKey = "PicaMD.editor.autoPair"
    static let smartPunctuationKey = "PicaMD.editor.smartPunctuation"
    /// Settings ▸ General ▸ "Show welcome window when PicaMD opens".
    /// Read by the launch path that decides whether to present the
    /// welcome window.
    static let showWelcomeWindowKey = "PicaMD.general.showWelcomeWindow"

    /// Call once at launch, before any editor reads the keys.
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            autoPairKey: true,
            smartPunctuationKey: false,
            showWelcomeWindowKey: true,
        ])
    }
}
