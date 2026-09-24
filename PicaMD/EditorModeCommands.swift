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

/// What the File menu's export actions need from the active window,
/// surfaced via `@FocusedValue`. A stable reference whose accessors read
/// the live values at export time: publishing a struct with the whole
/// document text changed the focused value on every keystroke (menu
/// updates each time), and the filename captured once at window-open
/// stayed "Untitled" after the first save.
@MainActor
final class ActiveDocumentContext {
    var source: () -> String = { "" }
    var palette: () -> Palette? = { nil }
    weak var window: NSWindow?

    /// The document's current file URL (nil while untitled).
    var fileURL: URL? { window?.representedURL }
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
