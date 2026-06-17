import SwiftUI

/// `FocusedBinding` keys that let the App's `Commands` block reach
/// into the active document window's per-scene `@SceneStorage` flags
/// (Focus Mode / Typewriter Mode / Command Palette open-state).
///
/// This is the SwiftUI-blessed way to drive per-window menu items
/// from a global `Commands` definition: each `ContentView` publishes
/// its bindings via `.focusedSceneValue(\.…, $flag)`, and the menu
/// reads them via `@FocusedBinding(\.…)`. The shortcut becomes a
/// no-op (and the menu item disabled) when there's no active window.

private struct FocusModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct TypewriterModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct CommandPaletteKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct ActiveDocumentContextKey: FocusedValueKey {
    typealias Value = ActiveDocumentContext
}
private struct SearchModelKey: FocusedValueKey {
    typealias Value = SearchModel
}

/// Read-only snapshot of what the active window's editor is currently
/// holding, surfaced to the App's `Commands` block via `@FocusedValue`
/// so the File menu's export actions can reach the source text without
/// having to bridge through `NSDocumentController`.
struct ActiveDocumentContext {
    let source: String
    let filename: String?
    let palette: Palette
}

extension FocusedValues {
    var focusModeBinding: Binding<Bool>? {
        get { self[FocusModeKey.self] }
        set { self[FocusModeKey.self] = newValue }
    }
    var typewriterModeBinding: Binding<Bool>? {
        get { self[TypewriterModeKey.self] }
        set { self[TypewriterModeKey.self] = newValue }
    }
    var commandPaletteBinding: Binding<Bool>? {
        get { self[CommandPaletteKey.self] }
        set { self[CommandPaletteKey.self] = newValue }
    }
    var activeDocumentContext: ActiveDocumentContext? {
        get { self[ActiveDocumentContextKey.self] }
        set { self[ActiveDocumentContextKey.self] = newValue }
    }
    /// The active editor window's find/replace model, so the Find menu
    /// can drive ⌘F / ⌘G / Replace on whichever window is frontmost.
    var searchModel: SearchModel? {
        get { self[SearchModelKey.self] }
        set { self[SearchModelKey.self] = newValue }
    }
}

/// View-menu entries for editor modes that toggle per-document state.
struct EditorModeCommands: Commands {
    @FocusedBinding(\.focusModeBinding) private var focusMode: Bool?
    @FocusedBinding(\.typewriterModeBinding) private var typewriterMode: Bool?
    @FocusedBinding(\.commandPaletteBinding) private var commandPalette: Bool?

    var body: some Commands {
        CommandMenu("Edit Mode") {
            Button("Toggle Focus Mode") {
                focusMode?.toggle()
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
            .disabled(focusMode == nil)

            Button("Toggle Typewriter Mode") {
                typewriterMode?.toggle()
            }
            .keyboardShortcut("y", modifiers: [.control, .command])
            .disabled(typewriterMode == nil)

            Divider()

            Button("Command Palette…") {
                // `commandPalette` is the unwrapped Bool projection of
                // a `Binding<Bool>?`. Setting `commandPalette = true`
                // updates the binding on the active scene (which then
                // drives the `.sheet(isPresented:)` in ContentView).
                commandPalette = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(commandPalette == nil)
        }
    }
}
