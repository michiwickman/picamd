import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var headings: [DocumentHeading] = []
    @State private var jumpToken: EditorJumpToken?
    @State private var activeHeadingID: Int?
    @State private var cursorLocation: Int = 0
    @State private var frontmatter: Frontmatter = .empty

    @SceneStorage("PicaMD.showOutline") private var showOutline: Bool = true
    @SceneStorage("PicaMD.focusMode") private var focusMode: Bool = false
    @SceneStorage("PicaMD.typewriterMode") private var typewriterMode: Bool = false
    @State private var commandPaletteOpen: Bool = false
    /// Find/replace bar state for this window. Published to the Find
    /// command menu via `.focusedSceneValue(\.searchModel, …)`.
    @StateObject private var search = SearchModel()
    /// Live accessors for the File ▸ Export commands (see
    /// `ActiveDocumentContext`). One stable instance per window.
    @State private var exportContext = ActiveDocumentContext()
    /// Word / character / line counts for the status bar, and the
    /// outline + frontmatter, are recomputed shortly after typing pauses
    /// rather than on every keystroke (each is a full-document pass).
    @State private var stats = TextStats()
    @State private var derivedStateTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            FrontmatterBar(frontmatter: frontmatter)
            mainSplit
            if themeStore.theme.showStatusBar {
                Divider()
                StatusBar(stats: stats)
            }
        }
        .background(Color(themeStore.theme.palette.bg))
        // Wire up document-window tabbing — every PicaMD window shares
        // the same tabbing identifier, so ⌘T (or "Window → Show Next
        // Tab" etc.) automatically merges new documents into a single
        // tab group instead of always opening detached windows.
        .background(WindowAccessor { window in
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "de.michaelwittmann.PicaMD.document"
            // Export reads the window's representedURL at export time,
            // so a document saved after opening exports under its name.
            exportContext.window = window
        })
        // Publish per-window mode flags to the App's `Commands` block
        // via `@FocusedBinding`. The active window's bindings drive
        // ⌃⌘F (Focus), ⌃⌘Y (Typewriter), ⌘⇧P (Command Palette).
        .focusedSceneValue(\.focusModeBinding, $focusMode)
        .focusedSceneValue(\.typewriterModeBinding, $typewriterMode)
        .focusedSceneValue(\.commandPaletteBinding, $commandPaletteOpen)
        .focusedSceneValue(\.searchModel, search)
        // Stable reference with live accessors for the Export commands.
        .focusedSceneValue(\.activeDocumentContext, exportContext)
        .sheet(isPresented: $commandPaletteOpen) {
            CommandPalette(isPresented: $commandPaletteOpen,
                            actions: commandPaletteActions)
                .environmentObject(themeStore)
        }
        .frame(minWidth: 700, idealWidth: 1100, minHeight: 400, idealHeight: 750)
        .onAppear {
            recomputeDerivedState(document.text)
            let binding = $document
            let store = themeStore
            exportContext.source = { binding.wrappedValue.text }
            exportContext.palette = { store.theme.palette }
        }
        .onChange(of: document.text) { _, new in
            derivedStateTask?.cancel()
            derivedStateTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(EditorTiming.derivedStateDebounceMs))
                guard !Task.isCancelled else { return }
                recomputeDerivedState(new)
            }
        }
        .onChange(of: cursorLocation) { _, _ in updateActiveHeading() }
        .onChange(of: headings) { _, _ in updateActiveHeading() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showOutline.toggle()
                    }
                } label: {
                    Image(systemName: showOutline ? "sidebar.left" : "sidebar.leading")
                }
                // ⌃⌘S is the standard Mac "Show/Hide Sidebar" shortcut.
                // (It used to be ⌃⌘1, which silently swallowed the first
                // AI-preset hotkey — ⌃⌘1…⌃⌘9 are reserved for those.)
                .help("Show/Hide Outline (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
    }

    @ViewBuilder
    private var mainSplit: some View {
        HSplitView {
            if showOutline {
                OutlineSidebar(
                    headings: headings,
                    activeHeadingID: activeHeadingID,
                    onSelect: { h in
                        activeHeadingID = h.id
                        jumpToken = EditorJumpToken(
                            NSRange(location: h.titleLocation, length: 0)
                        )
                    }
                )
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 380)
            }
            editorPane
                .frame(minWidth: 360)
        }
    }

    /// Editor surface. The Tahoe preset wraps it in a tinted card so
    /// the document looks like it floats; the other presets render
    /// edge-to-edge.
    @ViewBuilder
    private var editorPane: some View {
        let theme = themeStore.theme
        // One view tree for every preset. Switching between an if/else
        // pair of branches gave the editor a new SwiftUI identity, which
        // rebuilt it in every window — caret, scroll position and undo
        // history lost on each Tahoe ⇄ other-preset change.
        let isCard = theme.preset == .tahoe
        let radius: CGFloat = isCard ? EditorLayout.tahoeCardCornerRadius : 0
        MarkdownTextView(text: $document.text,
                         jumpToken: $jumpToken,
                         cursorLocation: $cursorLocation,
                         theme: theme,
                         focusMode: focusMode,
                         typewriterMode: typewriterMode,
                         search: search)
            .background(Color(theme.palette.bg))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isCard ? Color(theme.palette.rule) : .clear, lineWidth: 1)
            )
            .padding(isCard
                     ? EdgeInsets(top: EditorLayout.tahoeCardPaddingTop,
                                  leading: EditorLayout.tahoeCardPaddingHorizontal,
                                  bottom: EditorLayout.tahoeCardPaddingTop,
                                  trailing: EditorLayout.tahoeCardPaddingHorizontal)
                     : EdgeInsets())
            .background(Color(isCard ? theme.palette.bgTint : theme.palette.bg))
        .overlay(alignment: .topTrailing) {
            if search.isOpen {
                SearchBarView(model: search)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: search.isOpen)
    }

    private func recomputeDerivedState(_ text: String) {
        recomputeHeadings(text)
        recomputeFrontmatter(text)
        let new = TextStats(text)
        if new != stats { stats = new }
    }

    private func recomputeHeadings(_ text: String) {
        headings = HeadingExtractor.extract(from: text)
        // Drop the active highlight if the corresponding heading is gone.
        if let id = activeHeadingID, !headings.contains(where: { $0.id == id }) {
            activeHeadingID = nil
        }
    }

    private func recomputeFrontmatter(_ text: String) {
        let new = Frontmatter.build(from: text)
        if new != frontmatter { frontmatter = new }
    }

    /// Aggregates every action the command palette can offer:
    ///
    ///   1. One entry per heading — selecting jumps to it.
    ///   2. View-mode toggles (outline, focus, typewriter, status bar).
    ///   3. Frequent edits (heading-level shortcuts) for discoverability.
    private var commandPaletteActions: [CommandPaletteAction] {
        var actions: [CommandPaletteAction] = []

        // Headings → jump tokens
        let lineNumbers = TextStats.lineNumbers(at: headings.map(\.lineRange.location),
                                                in: document.text)
        for (i, h) in headings.enumerated() {
            let prefix = String(repeating: "#", count: h.level) + " "
            actions.append(.init(
                title: h.text,
                subtitle: prefix + "(line \(lineNumbers[i]))",
                icon: "number",
                perform: {
                    activeHeadingID = h.id
                    jumpToken = EditorJumpToken(
                        NSRange(location: h.titleLocation, length: 0)
                    )
                }
            ))
        }

        // View toggles
        actions.append(contentsOf: [
            .init(title: "Toggle Outline Sidebar",
                   subtitle: showOutline ? "Currently shown · ⌃⌘S" : "Currently hidden · ⌃⌘S",
                   icon: "sidebar.left",
                   perform: { withAnimation(.easeInOut(duration: 0.18)) { showOutline.toggle() } }),
            .init(title: "Toggle Focus Mode",
                   subtitle: focusMode ? "Currently on · ⌃⌘F" : "Currently off · ⌃⌘F",
                   icon: "scope",
                   perform: { focusMode.toggle() }),
            .init(title: "Toggle Typewriter Mode",
                   subtitle: typewriterMode ? "Currently on · ⌃⌘Y" : "Currently off · ⌃⌘Y",
                   icon: "text.cursor",
                   perform: { typewriterMode.toggle() }),
            .init(title: "Open Settings…",
                   subtitle: "Theme, palette, accent, typography · ⌘,",
                   icon: "gear",
                   perform: { SettingsOpener.open() }),
        ])

        return actions
    }

    /// Find the heading whose line the caret is on (or the most recent
    /// one above it), and mark it active in the outline.
    private func updateActiveHeading() {
        guard !headings.isEmpty else { activeHeadingID = nil; return }
        // Walk backwards: pick the last heading whose lineRange.location
        // is <= cursorLocation.
        var match: DocumentHeading?
        for h in headings {
            if h.lineRange.location <= cursorLocation {
                match = h
            } else {
                break
            }
        }
        if activeHeadingID != match?.id {
            activeHeadingID = match?.id
        }
    }
}

/// Document counts for the status bar, computed in one pass.
struct TextStats: Equatable {
    var words = 0
    var characters = 0
    var lines = 0

    init() {}

    init(_ text: String) {
        characters = text.count
        guard !text.isEmpty else { return }
        var inWord = false
        var newlines = 0
        for scalar in text.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if !isSpace && !inWord { words += 1 }
            inWord = !isSpace
            if scalar == "\n" { newlines += 1 }
        }
        lines = newlines + 1
    }

    /// 1-based line numbers for ascending UTF-16 `offsets`, in one pass.
    static func lineNumbers(at offsets: [Int], in text: String) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(offsets.count)
        var line = 1
        var position = 0
        var iterator = text.utf16.makeIterator()
        for offset in offsets {
            while position < offset, let unit = iterator.next() {
                if unit == 0x0A { line += 1 }
                position += 1
            }
            result.append(line)
        }
        return result
    }
}

private struct StatusBar: View {
    let stats: TextStats

    var body: some View {
        HStack(spacing: 16) {
            Text("\(stats.words) words")
            Text("\(stats.characters) chars")
            Text("\(stats.lines) lines")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

}
