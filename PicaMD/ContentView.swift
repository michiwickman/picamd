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
    /// Updated whenever the WindowAccessor's window's representedURL
    /// changes — i.e. every time the user saves an Untitled doc or
    /// opens a fresh file. Used to provide the suggested export
    /// filename via `ActiveDocumentContext`.
    @State private var documentURL: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            FrontmatterBar(frontmatter: frontmatter)
            mainSplit
            if themeStore.theme.showStatusBar {
                Divider()
                StatusBar(text: document.text)
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
            // Snapshot the URL once on first hookup; after that the
            // window's `representedURL` is updated by AppKit's save
            // pipeline. We don't poll — the export commands always
            // use the latest `document.text`, and an "Untitled" name
            // is fine while the doc has no on-disk URL yet.
            documentURL = window.representedURL
        })
        // Publish per-window mode flags to the App's `Commands` block
        // via `@FocusedBinding`. The active window's bindings drive
        // ⌃⌘F (Focus), ⌃⌘Y (Typewriter), ⌘⇧P (Command Palette).
        .focusedSceneValue(\.focusModeBinding, $focusMode)
        .focusedSceneValue(\.typewriterModeBinding, $typewriterMode)
        .focusedSceneValue(\.commandPaletteBinding, $commandPaletteOpen)
        .focusedSceneValue(\.searchModel, search)
        // Publish a snapshot of the active doc's source + URL +
        // palette so the File menu's Export commands can read them.
        .focusedSceneValue(\.activeDocumentContext, ActiveDocumentContext(
            source: document.text,
            filename: documentURL?.lastPathComponent,
            palette: themeStore.theme.palette
        ))
        .sheet(isPresented: $commandPaletteOpen) {
            CommandPalette(isPresented: $commandPaletteOpen,
                            actions: commandPaletteActions)
                .environmentObject(themeStore)
        }
        .frame(minWidth: 700, idealWidth: 1100, minHeight: 400, idealHeight: 750)
        .onAppear {
            recomputeHeadings(document.text)
            recomputeFrontmatter(document.text)
        }
        .onChange(of: document.text) { _, new in
            recomputeHeadings(new)
            recomputeFrontmatter(new)
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
                .help("Toggle Outline (⌃⌘1)")
                .keyboardShortcut("1", modifiers: [.control, .command])
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
        let editor = MarkdownTextView(text: $document.text,
                                       jumpToken: $jumpToken,
                                       cursorLocation: $cursorLocation,
                                       theme: theme,
                                       focusMode: focusMode,
                                       typewriterMode: typewriterMode,
                                       search: search)
        Group {
            if theme.preset == .tahoe {
                editor
                    .background(Color(theme.palette.bg))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(theme.palette.rule), lineWidth: 1)
                    )
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .background(Color(theme.palette.bgTint))
            } else {
                editor
            }
        }
        .overlay(alignment: .topTrailing) {
            if search.isOpen {
                SearchBarView(model: search)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        for h in headings {
            let prefix = String(repeating: "#", count: h.level) + " "
            actions.append(.init(
                title: h.text,
                subtitle: prefix + "(line \(h.lineRange.location))",
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
                   subtitle: showOutline ? "Currently shown · ⌃⌘1" : "Currently hidden · ⌃⌘1",
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
                   perform: {
                       NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                   }),
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

private struct StatusBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Text("\(wordCount) words")
            Text("\(charCount) chars")
            Text("\(lineCount) lines")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { !$0.isEmpty }
            .count
    }
    private var charCount: Int { text.count }
    private var lineCount: Int {
        if text.isEmpty { return 0 }
        return text.components(separatedBy: "\n").count
    }
}
