import SwiftUI

/// The slide of the outline and inspector columns. An explicit
/// `withAnimation` is not softened by the system, so with System Settings ▸
/// Accessibility ▸ Display ▸ Reduce motion on the columns appear and
/// disappear without sliding.
@MainActor
enum PanelMotion {
    static func toggle(_ animation: Animation,
                       reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Animation? {
        reduceMotion ? nil : animation
    }
}

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var headings: [DocumentHeading] = []
    @State private var jumpToken: EditorJumpToken?
    @State private var activeHeadingID: Int?
    @State private var cursorLocation: Int = 0
    @State private var frontmatter: Frontmatter = .empty
    /// Inspector fields the front matter can't take a write for.
    @State private var frontmatterLocks: [Frontmatter.Field: String] = [:]
    /// The inspector's way into the editor: front matter writes land on
    /// the text view's undo stack instead of replacing `document.text`.
    @State private var editorBridge = EditorBridge()

    /// Source of truth for the outline column; the split view's column
    /// visibility is derived from it (`outlineVisibility`), so the menu,
    /// the palette and the system sidebar button all agree.
    @SceneStorage("PicaMD.showOutline") private var showOutline: Bool = true
    /// The inspector column (⌥⌘I). Every window starts with it closed.
    @State private var showInspector: Bool = false
    @SceneStorage("PicaMD.focusMode") private var focusMode: Bool = false
    @SceneStorage("PicaMD.typewriterMode") private var typewriterMode: Bool = false
    /// Lay hard-wrapped paragraphs out to the window width instead of to the
    /// column their newlines happen to sit at. Off by default: it changes what
    /// a "line" means for caret movement, which should be an opt-in for an
    /// editor that shows its own source.
    @SceneStorage("PicaMD.reflowMode") private var reflowMode: Bool = false
    @State private var commandPaletteOpen: Bool = false
    /// Find/replace bar state for this window. Published to the Find
    /// command menu via `.focusedSceneValue(\.searchModel, …)`.
    @StateObject private var search = SearchModel()
    /// Live accessors for the File ▸ Export commands (see
    /// `ActiveDocumentContext`). One stable instance per window.
    @State private var exportContext = ActiveDocumentContext()
    /// The window's file URL and modification date (inspector, Share).
    @StateObject private var windowObserver = DocumentWindowObserver()
    /// Counts for the word count and the inspector, and the outline +
    /// front matter, are recomputed shortly after typing pauses rather
    /// than on every keystroke (each is a full-document pass).
    @State private var stats = TextStats()
    @State private var derivedStateTask: Task<Void, Never>?
    @State private var statsTask: Task<Void, Never>?
    /// Where the editor sits in the window, for the column limits that
    /// keep it at its floor (the window's width is `windowObserver`'s).
    @State private var editorFrame: CGRect = .zero

    var body: some View {
        let theme = themeStore.theme
        let limits = WindowColumnLimits(windowWidth: windowObserver.width, editorFrame: editorFrame,
                                        inspectorShown: showInspector)
        NavigationSplitView(columnVisibility: outlineVisibility) {
            OutlineSidebar(
                headings: headings,
                activeHeadingID: activeHeadingID,
                accent: Color(nsColor: theme.effectiveAccent),
                onSelect: jump(to:)
            )
            .navigationSplitViewColumnWidth(min: WindowColumnLimits.outline.lowerBound,
                                            ideal: min(248, limits.outlineMax),
                                            max: limits.outlineMax)
        } detail: {
            // The editor sits in the detail column unconditionally; the
            // word count and the inspector hang off it as modifiers, so
            // showing or hiding any column never rebuilds MarkdownTextView
            // (caret, scroll position and undo history survive).
            //
            // No minimum width here: the detail column runs under the
            // floating outline, so SwiftUI adds the outline's width to
            // any minimum set on the editor, and the outer split adds
            // the outline again. With the inspector open that asked for
            // more than a 1100 pt window has and never settled (AppKit
            // gives up after too many constraint passes): the content
            // overflowed the window on both sides. The editor's floor
            // comes from the column maxima instead (`WindowColumnLimits`),
            // which the split views honor on their own.
            editorPane
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    // After the layout pass: new column limits inside it
                    // ask AppKit for another constraint pass, again and
                    // again, until it gives up.
                    DispatchQueue.main.async { editorFrame = frame }
                }
                .overlay(alignment: .bottomTrailing) { wordCount }
                // The find bar docks under the toolbar across the editor
                // column and pushes the text down (board `FindReplace`).
                // Safe-area content, not a branch around the editor, so
                // opening it keeps the editor's identity.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if search.isOpen {
                        SearchBarView(model: search)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: search.isOpen)
                .inspector(isPresented: $showInspector) {
                    InspectorView(
                        title: frontmatter.title,
                        tags: frontmatter.tags,
                        date: frontmatter.date,
                        locks: frontmatterLocks,
                        stats: stats,
                        headingCount: headings.count,
                        fileURL: windowObserver.fileURL,
                        modified: windowObserver.modified,
                        bridge: editorBridge
                    )
                    .equatable()
                    .inspectorColumnWidth(min: WindowColumnLimits.inspector.lowerBound,
                                          ideal: min(300, limits.inspectorMax),
                                          max: limits.inspectorMax)
                }
        }
        .toolbar {
            // One group: macOS 27 draws it as a single glass capsule.
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: shareItem, preview: SharePreview(shareItem.displayName))
                    .help("Share")
                inspectorToggle(accent: Color(nsColor: theme.effectiveAccent))
            }
        }
        .background(WindowAccessor { window in
            // Export reads the window's representedURL at export time,
            // so a document saved after opening exports under its name.
            exportContext.window = window
            windowObserver.attach(to: window)
        })
        // Publish per-window flags to the App's `Commands` block via
        // `@FocusedBinding`. The active window's bindings drive ⌃⌘S
        // (Outline), ⌥⌘I (Inspector), ⌃⌘F (Focus), ⌃⌘Y (Typewriter),
        // ⌃⌘R (Reflow), ⇧⌘P (Command Palette).
        .focusedSceneValue(\.outlineVisibleBinding, $showOutline)
        .focusedSceneValue(\.inspectorVisibleBinding, $showInspector)
        .focusedSceneValue(\.focusModeBinding, $focusMode)
        .focusedSceneValue(\.typewriterModeBinding, $typewriterMode)
        .focusedSceneValue(\.reflowModeBinding, $reflowMode)
        .focusedSceneValue(\.commandPaletteBinding, commandPaletteToggle)
        .focusedSceneValue(\.searchModel, search)
        // Stable reference with live accessors for the Export commands.
        .focusedSceneValue(\.activeDocumentContext, exportContext)
        // ⇧⌘P: floats over the whole window, toolbar row included.
        .overlay {
            if commandPaletteOpen {
                CommandPaletteOverlay(items: commandPaletteItems,
                                      accent: themeStore.theme.effectiveAccent,
                                      finish: finishCommandPalette)
            }
        }
        // Outline (200) + editor (360) + inspector (260): the window can
        // never get too narrow to show all three.
        .frame(minWidth: Self.minimumWindowWidth, minHeight: 400)
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
        // Counts are skipped while nothing shows them; catch up when the
        // word count or the inspector appears.
        .onChange(of: statsVisible) { _, visible in
            if visible { recomputeStats(document.text) }
        }
        .onChange(of: cursorLocation) { _, _ in updateActiveHeading() }
        .onChange(of: headings) { _, _ in updateActiveHeading() }
    }

    /// Sidebar 200 + editor 360 + inspector 260 (both columns at their
    /// minimum widths).
    static let minimumWindowWidth: CGFloat = WindowColumnLimits.outline.lowerBound
        + WindowColumnLimits.editorFloor + WindowColumnLimits.inspector.lowerBound

    /// `showOutline` as the split view's column visibility.
    static func columnVisibility(showOutline: Bool) -> NavigationSplitViewVisibility {
        showOutline ? .all : .detailOnly
    }

    /// Back from the split view (system sidebar button, drag to collapse).
    static func showsOutline(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
    }

    private var outlineVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { Self.columnVisibility(showOutline: showOutline) },
            set: { showOutline = Self.showsOutline($0) }
        )
    }

    private var statsVisible: Bool {
        themeStore.theme.showStatusBar || showInspector
    }

    /// Share the .md file: the saved file, or a temporary copy named
    /// after the document's title while it is untitled.
    private var shareItem: MarkdownShareItem {
        MarkdownShareItem(
            savedURL: windowObserver.fileURL,
            text: document.text,
            untitledName: frontmatter.title
                ?? headings.first(where: { $0.level == 1 })?.text
                ?? "Untitled"
        )
    }

    /// Inspector button: neutral like the rest of the toolbar, accent
    /// only while the inspector is open (board `Inspector`). The ⌥⌘I
    /// shortcut lives in the View menu (`ViewCommands`).
    private func inspectorToggle(accent: Color) -> some View {
        Button {
            withAnimation(PanelMotion.toggle(.easeInOut(duration: 0.2))) { showInspector.toggle() }
        } label: {
            Label {
                Text("Inspector")
            } icon: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(showInspector ? accent : Color.primary)
            }
        }
        .help(showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .accessibilityAddTraits(showInspector ? .isSelected : [])
    }

    /// The quiet word count in the editor's bottom-right corner (Settings
    /// ▸ Editor ▸ Show word count). Palette colours, because it sits on
    /// the editor surface, not on the chrome; quiet, but readable.
    @ViewBuilder
    private var wordCount: some View {
        if themeStore.theme.showStatusBar {
            Text(InspectorFormat.wordCount(stats.words))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Color(themeStore.theme.palette.wordCountColor))
                .padding(.trailing, 18)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
    }

    private func jump(to heading: DocumentHeading) {
        activeHeadingID = heading.id
        jumpToken = EditorJumpToken(NSRange(location: heading.titleLocation, length: 0))
    }

    /// Editor surface. "Card layout" (on by default in the Tahoe preset)
    /// wraps it in a tinted card so the document looks like it floats;
    /// otherwise it renders edge-to-edge.
    @ViewBuilder
    private var editorPane: some View {
        let theme = themeStore.theme
        // One view tree for every preset. Switching between an if/else
        // pair of branches gave the editor a new SwiftUI identity, which
        // rebuilt it in every window — caret, scroll position and undo
        // history lost on each Tahoe ⇄ other-preset change.
        let isCard = theme.cardLayout
        let radius: CGFloat = isCard ? EditorLayout.tahoeCardCornerRadius : 0
        MarkdownTextView(text: $document.text,
                         jumpToken: $jumpToken,
                         cursorLocation: $cursorLocation,
                         theme: theme,
                         focusMode: focusMode,
                         typewriterMode: typewriterMode,
                         reflowMode: reflowMode,
                         search: search,
                         editorBridge: editorBridge)
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
    }

    private func recomputeDerivedState(_ text: String) {
        recomputeHeadings(text)
        recomputeFrontmatter(text)
        recomputeStats(text)
    }

    /// Visible-word counting is a full-document pass with a dozen
    /// patterns, so it runs off the main actor and only while the word
    /// count or the inspector is on screen.
    private func recomputeStats(_ text: String) {
        guard statsVisible else { return }
        statsTask?.cancel()
        statsTask = Task(priority: .utility) { @MainActor in
            guard let new = await Self.countStats(text), !Task.isCancelled else { return }
            if new != stats { stats = new }
        }
    }

    /// Runs on the concurrent pool but inside `statsTask` (a detached
    /// task would not see its cancellation), so a pass superseded by a
    /// newer edit stops between its regex passes.
    @concurrent
    nonisolated private static func countStats(_ text: String) async -> TextStats? {
        TextStats.compute(text, isCancelled: { Task.isCancelled })
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
        var locks: [Frontmatter.Field: String] = [:]
        for field in Frontmatter.Field.allCases {
            locks[field] = Frontmatter.lockReason(for: field, in: text, frontmatter: new)
        }
        if locks != frontmatterLocks { frontmatterLocks = locks }
    }

    /// The palette flag as the View menu sees it. Opening just sets it;
    /// closing with ⇧⌘P goes through `finishCommandPalette` like Esc, so
    /// the editor gets the keyboard focus back from the search field.
    private var commandPaletteToggle: Binding<Bool> {
        Binding(get: { commandPaletteOpen },
                set: { open in
                    if open { commandPaletteOpen = true } else { finishCommandPalette(nil) }
                })
    }

    /// Close the palette, give the editor its focus back, then run the
    /// chosen item. The editor must be first responder again before a
    /// command runs: Format commands work on its selection. Esc and a
    /// second close are no-ops.
    private func finishCommandPalette(_ item: CommandPaletteItem?) {
        guard commandPaletteOpen else { return }
        commandPaletteOpen = false
        let bridge = editorBridge
        Task { @MainActor in
            // Let the overlay leave the view tree before focus moves.
            await Task.yield()
            bridge.focusEditor()
            item?.perform()
        }
    }

    /// What the command palette offers: every heading (jump to it), then
    /// the View and Format menu commands, Find, Export, Settings and the
    /// AI presets, with the shortcuts the menus show.
    private var commandPaletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        let lineNumbers = TextStats.lineNumbers(at: headings.map(\.lineRange.location),
                                                in: document.text)
        for (i, h) in headings.enumerated() {
            items.append(.init(id: "heading-\(h.id)", section: .headings, title: h.text,
                               subtitle: "Heading \(h.level) · line \(lineNumbers[i])",
                               icon: "number", perform: { jump(to: h) }))
        }

        func toggle(_ id: String, _ title: String, icon: String, shortcut: KeyCombo?,
                    isOn: Bool, perform: @escaping @MainActor () -> Void) -> CommandPaletteItem {
            CommandPaletteItem(id: id, section: .commands, title: title, icon: icon,
                               shortcut: shortcut?.displayString, isOn: isOn, perform: perform)
        }
        func command(_ id: String, _ title: String, icon: String, shortcut: String? = nil,
                     perform: @escaping @MainActor () -> Void) -> CommandPaletteItem {
            CommandPaletteItem(id: id, section: .commands, title: title, icon: icon,
                               shortcut: shortcut, perform: perform)
        }

        let store = themeStore
        items += [
            toggle("showOutline", "Show Outline", icon: "sidebar.left",
                   shortcut: ViewShortcut.showOutline, isOn: showOutline) {
                withAnimation(PanelMotion.toggle(.easeInOut(duration: 0.18))) { showOutline.toggle() }
            },
            toggle("showInspector", "Show Inspector", icon: "sidebar.right",
                   shortcut: ViewShortcut.showInspector, isOn: showInspector) {
                withAnimation(PanelMotion.toggle(.easeInOut(duration: 0.2))) { showInspector.toggle() }
            },
            toggle("showWordCount", "Show Word Count", icon: "textformat.123",
                   shortcut: nil, isOn: store.theme.showStatusBar) {
                store.setShowStatusBar(!store.theme.showStatusBar)
            },
            toggle("focusMode", "Focus Mode", icon: "scope",
                   shortcut: ViewShortcut.focusMode, isOn: focusMode) { focusMode.toggle() },
            toggle("typewriterMode", "Typewriter Mode", icon: "text.cursor",
                   shortcut: ViewShortcut.typewriterMode, isOn: typewriterMode) { typewriterMode.toggle() },
            toggle("reflowMode", "Reflow Mode", icon: "arrow.left.and.right.text.vertical",
                   shortcut: ViewShortcut.reflowMode, isOn: reflowMode) { reflowMode.toggle() },
        ]

        let bridge = editorBridge
        let keybindings = PicaMDTextView.keybindings
        for action in FormatMenuLayout.paletteOrder {
            items.append(command("format-\(action.rawValue)", action.title, icon: action.symbolName,
                                 shortcut: keybindings.combo(for: action)?.displayString) {
                bridge.perform(action)
            })
        }

        let search = search
        items += [
            command("find", "Find…", icon: "magnifyingglass", shortcut: "⌘F") {
                search.open(replace: false)
            },
            command("findReplace", "Find and Replace…", icon: "arrow.left.arrow.right", shortcut: "⌥⌘F") {
                search.open(replace: true)
            },
        ]

        let context = exportContext
        items.append(command("exportHTML", "Export as HTML…", icon: "doc.richtext") {
            ExportCoordinator.exportHTML(source: context.source(), documentURL: context.fileURL,
                                         paletteForStyling: context.palette())
        })
        for (format, name) in [(PandocBridge.Format.pdf, "PDF"), (.docx, "Word Document"), (.epub, "EPUB")] {
            items.append(command("export-\(name)", "Export as \(name)…", icon: "doc") {
                ExportCoordinator.exportViaPandoc(source: context.source(), documentURL: context.fileURL,
                                                  format: format)
            })
        }

        items.append(command("settings", "Settings…", icon: "gearshape", shortcut: "⌘,") {
            SettingsOpener.open()
        })
        for pane in SettingsPane.allCases {
            items.append(command("settings-\(pane.rawValue)", "\(pane.title) Settings…",
                                 icon: pane.systemImage) {
                SettingsOpener.open(pane)
            })
        }

        // AI presets only while AI is on: otherwise each would only
        // explain that AI is off.
        if AIConfig.load().enabled {
            for preset in PicaMDTextView.presetStore.presets {
                let shortcut = preset.hotkey.map { "⌃⌘\($0)" }
                items.append(command("ai-\(preset.id.uuidString)", "AI: \(preset.name)",
                                     icon: "sparkles", shortcut: shortcut) {
                    bridge.runAIPreset(preset)
                })
            }
        }
        return items
    }

    /// Mark the heading at the caret active in the outline.
    private func updateActiveHeading() {
        let id = Self.activeHeadingID(in: headings, cursor: cursorLocation)
        if activeHeadingID != id {
            activeHeadingID = id
        }
    }

    /// The heading whose line the caret is on, or the nearest one above
    /// it: the last heading whose line starts at or before `cursor`.
    static func activeHeadingID(in headings: [DocumentHeading], cursor: Int) -> Int? {
        var match: DocumentHeading?
        for h in headings {
            if h.lineRange.location <= cursor {
                match = h
            } else {
                break
            }
        }
        return match?.id
    }
}

/// How wide the outline and the inspector may get so the editor between
/// them keeps `editorFloor`. Neither split view knows about the other
/// (both columns float over the detail column on macOS 27), and a minimum
/// width on the editor itself makes SwiftUI count the outline twice. So
/// the maxima come from the window width instead: the inspector may take
/// what the outline and the floor leave; the outline what the floor and
/// an inspector at its minimum leave. A narrowing window therefore takes
/// the inspector down first and the outline only after it, one column at
/// a time: lowering both maxima below their columns' widths at once sends
/// the constraint passes into the loop AppKit gives up on (the V-1
/// overflow). The editor also has to stay at least as wide as the
/// outline, or the passes never settle either (measured: an editor
/// narrower than the outline loops, one as wide does not). The outline's
/// maximum stays 40 pt under the floor, so a resize step that squeezes
/// the editor before the limits catch up still leaves it wider.
struct WindowColumnLimits: Equatable {
    static let outline: ClosedRange<CGFloat> = 200...320
    static let inspector: ClosedRange<CGFloat> = 260...360
    /// Room for the find bar's field next to its fixed controls.
    static let editorFloor: CGFloat = 360

    var outlineMax: CGFloat
    var inspectorMax: CGFloat

    /// `editorFrame` in window coordinates: the outline ends at its left
    /// edge (0 while it is hidden). Without a measured window the static
    /// maxima apply.
    init(windowWidth: CGFloat?, editorFrame: CGRect, inspectorShown: Bool) {
        guard let width = windowWidth, width > 0, editorFrame.width > 0 else {
            outlineMax = Self.outline.upperBound
            inspectorMax = Self.inspector.upperBound
            return
        }
        let room = width - Self.editorFloor
        let outlineWidth = max(0, editorFrame.minX)
        outlineMax = Self.clamp(room - (inspectorShown ? Self.inspector.lowerBound : 0), to: Self.outline)
        inspectorMax = Self.clamp(room - outlineWidth, to: Self.inspector)
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound).rounded(.down)
    }
}
