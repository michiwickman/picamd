import SwiftUI

/// `FocusedBinding` keys that let the App's `Commands` block reach
/// into the active document window's per-scene state (outline,
/// inspector, Focus / Typewriter / Reflow Mode, Command Palette).
///
/// This is the SwiftUI-blessed way to drive per-window menu items
/// from a global `Commands` definition: each `ContentView` publishes
/// its bindings via `.focusedSceneValue(\.…, $flag)`, and the menu
/// reads them via `@FocusedBinding(\.…)`. The shortcut becomes a
/// no-op (and the menu item disabled) when there's no active window.
/// The menus themselves are in `ViewCommands` and `FormatCommands`.

private struct FocusModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct TypewriterModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct ReflowModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct OutlineVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
private struct InspectorVisibleKey: FocusedValueKey {
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
    var reflowModeBinding: Binding<Bool>? {
        get { self[ReflowModeKey.self] }
        set { self[ReflowModeKey.self] = newValue }
    }
    /// Outline sidebar shown in the active window (`@SceneStorage`).
    var outlineVisibleBinding: Binding<Bool>? {
        get { self[OutlineVisibleKey.self] }
        set { self[OutlineVisibleKey.self] = newValue }
    }
    /// Inspector column shown in the active window.
    var inspectorVisibleBinding: Binding<Bool>? {
        get { self[InspectorVisibleKey.self] }
        set { self[InspectorVisibleKey.self] = newValue }
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
