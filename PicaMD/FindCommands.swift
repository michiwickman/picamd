import SwiftUI

/// Edit ▸ Find, laid out like every Mac app's: Find… ⌘F, Find and
/// Replace… ⌥⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for
/// Find ⌘E, Jump to Selection ⌘J. Drives the active window's
/// `SearchModel`, published via `focusedSceneValue(\.searchModel, …)` by
/// `ContentView`. Items disable when there's no editor window.
struct FindCommands: Commands {
    @FocusedValue(\.searchModel) private var search: SearchModel?

    var body: some Commands {
        // Replace the system's default text-editing group so our shortcuts
        // win over AppKit's stock find-bar wiring (which can't see through
        // the editor's marker concealment).
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") {
                    search?.open(replace: false)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find and Replace…") {
                    search?.open(replace: true)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button("Find Next") {
                    search?.next()
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    search?.previous()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Use Selection for Find") {
                    search?.useSelection()
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Jump to Selection") {
                    search?.jumpToSelection()
                }
                .keyboardShortcut("j", modifiers: .command)
            }
            .disabled(search == nil)
        }
    }
}
