import SwiftUI
import AppKit

/// Shortcuts of the View menu items, shared with the command palette so
/// both show the same combo. The Format menu's combos come from
/// `KeybindingMap` instead, because keybindings.json can move them.
enum ViewShortcut {
    static let showOutline = KeyCombo(key: "s", modifiers: [.control, .command])
    static let showInspector = KeyCombo(key: "i", modifiers: [.option, .command])
    static let focusMode = KeyCombo(key: "f", modifiers: [.control, .command])
    static let typewriterMode = KeyCombo(key: "y", modifiers: [.control, .command])
    static let reflowMode = KeyCombo(key: "r", modifiers: [.control, .command])
    static let commandPalette = KeyCombo(key: "p", modifiers: [.shift, .command])

    static let all: [KeyCombo] = [showOutline, showInspector, focusMode, typewriterMode,
                                  reflowMode, commandPalette]
}

/// The Format menu's items in board order (`MenuSpec`), one array per
/// group between separators. Heading 4–6 and Select Line keep their key
/// bindings and are in the command palette, not in the menu.
enum FormatMenuLayout {
    static let groups: [[KeybindingAction]] = [
        [.headingH1, .headingH2, .headingH3, .headingParagraph],
        [.bold, .italic, .strikethrough, .inlineCode, .link],
        [.checklist, .quote, .table],
        [.moveLineUp, .moveLineDown, .duplicateLine],
    ]

    /// Every editor command, menu order first, then the palette-only ones.
    static let paletteOrder: [KeybindingAction] = groups.flatMap { $0 }
        + [.headingH4, .headingH5, .headingH6, .selectLine]
}

extension KeyCombo {
    /// The combo as a SwiftUI menu shortcut; nil for a key a menu can't
    /// show (a keybindings.json typo like `cmd+f13`).
    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "escape": equivalent = .escape
        case "return": equivalent = .return
        case "tab": equivalent = .tab
        case "space": equivalent = .space
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }
}

/// Format menu between Edit and View (board `MenuSpec`). Replacing
/// `.textFormatting` creates the menu; SwiftUI's own
/// `TextFormattingCommands` would put rich-text Bold/Italic and a Font
/// submenu there, which a Markdown editor can't use.
///
/// Each item runs on the key window's first responder, and only when
/// that is the editor (not the find field, the palette or the Link…
/// sheet): see `PicaMDTextView.formatMenuTarget(in:)`. Menu key
/// equivalents win over `keyDown`, so a combo here never also runs
/// through `KeybindingMap`.
struct FormatCommands: Commands {
    @FocusedValue(\.activeDocumentContext) private var document: ActiveDocumentContext?
    let keybindings: KeybindingMap

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            ForEach(Array(FormatMenuLayout.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { action in
                    Button(action.title) {
                        PicaMDTextView.formatMenuTarget(in: NSApp.keyWindow)?
                            .performEditorCommand(EditorCommandSender(action))
                    }
                    .keyboardShortcut(keybindings.combo(for: action)?.keyboardShortcut)
                    .disabled(document == nil)
                }
            }
        }
    }
}

/// View menu (board `MenuSpec`): Show Outline, Show Inspector, Show Word
/// Count | Focus, Typewriter, Reflow Mode | Command Palette…. AppKit adds
/// Show Tab Bar / Show All Tabs above and Enter Full Screen below; that
/// order is the system's and stays.
///
/// Replaces the `.sidebar` group, which is where `SidebarCommands` would
/// put its "Toggle Sidebar". Neither `SidebarCommands` nor
/// `InspectorCommands` is registered, and the toolbar buttons carry no
/// shortcut of their own, so each shortcut exists exactly once.
struct ViewCommands: Commands {
    /// Show Word Count is the global Settings ▸ Editor switch.
    @ObservedObject var themeStore: ThemeStore

    @FocusedBinding(\.outlineVisibleBinding) private var outlineVisible: Bool?
    @FocusedBinding(\.inspectorVisibleBinding) private var inspectorVisible: Bool?
    @FocusedBinding(\.focusModeBinding) private var focusMode: Bool?
    @FocusedBinding(\.typewriterModeBinding) private var typewriterMode: Bool?
    @FocusedBinding(\.reflowModeBinding) private var reflowMode: Bool?
    @FocusedBinding(\.commandPaletteBinding) private var commandPalette: Bool?

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Toggle("Show Outline", isOn: Binding(
                get: { outlineVisible ?? false },
                set: { new in withAnimation(PanelMotion.toggle(.easeInOut(duration: 0.18))) { outlineVisible = new } }))
                .keyboardShortcut(ViewShortcut.showOutline.keyboardShortcut)
                .disabled(outlineVisible == nil)

            Toggle("Show Inspector", isOn: Binding(
                get: { inspectorVisible ?? false },
                set: { new in withAnimation(PanelMotion.toggle(.easeInOut(duration: 0.2))) { inspectorVisible = new } }))
                .keyboardShortcut(ViewShortcut.showInspector.keyboardShortcut)
                .disabled(inspectorVisible == nil)

            Toggle("Show Word Count", isOn: Binding(
                get: { themeStore.theme.showStatusBar },
                set: { themeStore.setShowStatusBar($0) }))

            Divider()

            Toggle("Focus Mode", isOn: Binding(
                get: { focusMode ?? false }, set: { focusMode = $0 }))
                .keyboardShortcut(ViewShortcut.focusMode.keyboardShortcut)
                .disabled(focusMode == nil)

            Toggle("Typewriter Mode", isOn: Binding(
                get: { typewriterMode ?? false }, set: { typewriterMode = $0 }))
                .keyboardShortcut(ViewShortcut.typewriterMode.keyboardShortcut)
                .disabled(typewriterMode == nil)

            // Reflow: hard-wrapped paragraphs are laid out to the window
            // width instead of to the column their newlines were typed at.
            // The file on disk is not touched.
            Toggle("Reflow Mode", isOn: Binding(
                get: { reflowMode ?? false }, set: { reflowMode = $0 }))
                .keyboardShortcut(ViewShortcut.reflowMode.keyboardShortcut)
                .disabled(reflowMode == nil)

            Divider()

            Button("Command Palette…") {
                // ⇧⌘P again closes it, like Spotlight's hotkey.
                commandPalette = !(commandPalette ?? false)
            }
            .keyboardShortcut(ViewShortcut.commandPalette.keyboardShortcut)
            .disabled(commandPalette == nil)
        }
    }
}
