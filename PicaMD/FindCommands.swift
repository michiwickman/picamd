import SwiftUI

/// The Find menu (⌘F find, ⌘⌥F find & replace, ⌘G next, ⇧⌘G previous,
/// ⌘E use-selection). Drives the active window's `SearchModel`, published
/// via `focusedSceneValue(\.searchModel, …)` by `ContentView`. Items
/// disable when there's no active editor window (`search == nil`).
struct FindCommands: Commands {
    @FocusedValue(\.searchModel) private var search: SearchModel?

    var body: some Commands {
        // Replace the system's default Find group so our shortcuts win
        // over AppKit's stock find-bar wiring.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                search?.toggle(replace: false)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(search == nil)

            Button("Find & Replace…") {
                search?.open(replace: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(search == nil)

            Button("Find Next") {
                search?.next()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(search == nil)

            Button("Find Previous") {
                search?.previous()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(search == nil)

            Button("Use Selection for Find") {
                search?.useSelection()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(search == nil)
        }
    }
}
