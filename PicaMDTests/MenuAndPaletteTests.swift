import XCTest
import SwiftUI
import AppKit
@testable import PicaMD

/// Format and View menu shortcuts (board `MenuSpec`), the menu icon pass
/// and the command palette's list logic (board `Palette`).
@MainActor
final class MenuAndPaletteTests: XCTestCase {

    // MARK: - Shortcut table

    /// Shortcuts the app's menus claim besides Format and View (File,
    /// Edit ▸ Find, Settings).
    private let otherMenuCombos = [
        "⌘N", "⌘T", "⌘O", "⌘F", "⌥⌘F", "⌘G", "⇧⌘G", "⌘E", "⌘J", "⌘,",
    ]

    func testFormatMenuHasTheBoardsItemsAndShortcuts() {
        let map = KeybindingMap.default
        let rows = FormatMenuLayout.groups.map { group in
            group.map { action in [action.title, map.combo(for: action)?.displayString ?? ""] }
        }
        XCTAssertEqual(rows, [
            [["Heading 1", "⌘1"], ["Heading 2", "⌘2"], ["Heading 3", "⌘3"], ["Body", "⌘0"]],
            [["Bold", "⌘B"], ["Italic", "⌘I"], ["Strikethrough", ""], ["Inline Code", ""], ["Link…", "⌘K"]],
            [["Checklist", ""], ["Quote", ""], ["Table", ""]],
            [["Move Line Up", "⌥⌘↑"], ["Move Line Down", "⌥⌘↓"], ["Duplicate Line", "⇧⌘D"]],
        ])
    }

    func testViewMenuShortcutsMatchTheBoard() {
        XCTAssertEqual(ViewShortcut.all.map(\.displayString), ["⌃⌘S", "⌥⌘I", "⌃⌘F", "⌃⌘Y", "⌃⌘R", "⇧⌘P"])
    }

    func testNoShortcutIsClaimedTwice() {
        // Every default editor combo (menu items and the keyDown-only
        // ones: ⌘4–⌘6, ⌘L), the View menu and the rest of the menus.
        let editor = KeybindingAction.allCases.compactMap { KeybindingMap.default.combo(for: $0)?.displayString }
        let all = editor + ViewShortcut.all.map(\.displayString) + otherMenuCombos
        let duplicates = Dictionary(grouping: all, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "claimed twice: \(duplicates.sorted())")
    }

    func testEveryEditorCommandIsInThePaletteOnce() {
        XCTAssertEqual(FormatMenuLayout.paletteOrder.count, KeybindingAction.allCases.count)
        XCTAssertEqual(Set(FormatMenuLayout.paletteOrder), Set(KeybindingAction.allCases))
        XCTAssertEqual(Array(FormatMenuLayout.paletteOrder.suffix(4)),
                       [.headingH4, .headingH5, .headingH6, .selectLine], "palette-only commands last")
    }

    func testUndoNames() {
        XCTAssertEqual(KeybindingAction.bold.undoActionName, "Bold")
        XCTAssertEqual(KeybindingAction.link.undoActionName, "Link")
        XCTAssertEqual(KeybindingAction.table.undoActionName, "Insert Table")
        XCTAssertNil(KeybindingAction.selectLine.undoActionName)
    }

    // MARK: - keybindings.json moves the menu shortcut

    func testUserBindingMovesTheMenuShortcut() {
        let merged = KeybindingMap.merging(userJSON: ["bold": "cmd+shift+b", "quote": "ctrl+cmd+q"])
        XCTAssertEqual(merged.combo(for: .bold)?.displayString, "⇧⌘B")
        XCTAssertEqual(merged.combo(for: .quote)?.displayString, "⌃⌘Q")
        XCTAssertNil(KeybindingMap.default.combo(for: .quote))
        let shortcut = merged.combo(for: .bold)?.keyboardShortcut
        XCTAssertEqual(shortcut?.key, KeyEquivalent("b"))
        XCTAssertEqual(shortcut?.modifiers, [.command, .shift])
    }

    func testKeyComboAsMenuShortcut() {
        let up = KeybindingMap.default.combo(for: .moveLineUp)?.keyboardShortcut
        XCTAssertEqual(up?.key, .upArrow)
        XCTAssertEqual(up?.modifiers, [.command, .option])
        XCTAssertNil(KeyCombo(key: "f13", modifiers: .command).keyboardShortcut, "no menu key for that")
    }

    func testDoubleBoundComboRunsTheSameActionEveryTime() throws {
        // Before: the table was walked in dictionary order, which changes
        // with each launch's hash seed.
        let merged = KeybindingMap.merging(userJSON: ["selectLine": "cmd+1"])
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
            isARepeat: false, keyCode: 0x12))
        XCTAssertEqual(merged.action(for: event), .headingH1, "declaration order decides")
    }

    // MARK: - Menu icons

    func testIconPassHidesEveryImageOnce() {
        let menu = NSMenu()
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        find.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        find.preferredImageVisibility = .visible
        let sub = NSMenu()
        let emoji = NSMenuItem(title: "Emoji & Symbols", action: nil, keyEquivalent: "")
        emoji.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        sub.addItem(emoji)
        find.submenu = sub
        menu.addItem(find)
        menu.addItem(.separator())

        XCTAssertEqual(MenuIconSuppressor.hideImages(in: menu), 3)
        XCTAssertEqual(find.preferredImageVisibility, .hidden)
        XCTAssertEqual(emoji.preferredImageVisibility, .hidden)
        XCTAssertEqual(MenuIconSuppressor.hideImages(in: menu), 0, "nothing rewritten on the next pass")
    }

    // MARK: - File ▸ Open…

    /// The File menu as SwiftUI builds it on macOS 27: PicaMD's Open… ⌘O
    /// in the New group, then DocumentGroup's own Open… without ⌘O in a
    /// section of its own.
    private func fileMenu() -> (menu: NSMenu, stock: NSMenuItem, separatorAfter: NSMenuItem) {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New", action: nil, keyEquivalent: "n")
        menu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let stock = menu.addItem(withTitle: "Open…",
                                 action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "")
        let separatorAfter = NSMenuItem.separator()
        menu.addItem(separatorAfter)
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return (menu, stock, separatorAfter)
    }

    func testStockOpenDuplicateIsHiddenWithItsSeparator() {
        let (menu, stock, separatorAfter) = fileMenu()
        XCTAssertEqual(MenuIconSuppressor.hideStockOpenDuplicate(in: menu), 2)
        XCTAssertTrue(stock.isHidden)
        XCTAssertTrue(separatorAfter.isHidden, "no doubled separator before Close")
        let visible = menu.items.filter { !$0.isHidden }
        XCTAssertEqual(visible.filter { $0.title == "Open…" }.map(\.keyEquivalent), ["o"])
        XCTAssertEqual(visible.filter(\.isSeparatorItem).count, 1)
        XCTAssertEqual(MenuIconSuppressor.hideStockOpenDuplicate(in: menu), 0, "nothing rewritten on the next pass")
    }

    func testStockOpenStaysWithoutAnOwnOpen() {
        let menu = NSMenu(title: "File")
        let stock = menu.addItem(withTitle: "Open…",
                                 action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        XCTAssertEqual(MenuIconSuppressor.hideStockOpenDuplicate(in: menu), 0)
        XCTAssertFalse(stock.isHidden)
    }

    /// The live File menu of the test host.
    func testFileMenuShowsOneOpenWithCommandO() throws {
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        // The pass runs on the next turn after SwiftUI adds menu items.
        HostedDocument.spin(until: {
            file.items.filter { !$0.isHidden && $0.title == "Open…" }.count == 1
        })
        let opens = file.items.filter { !$0.isHidden && $0.title == "Open…" }
        XCTAssertEqual(opens.map(\.keyEquivalent), ["o"])
        XCTAssertEqual(opens.first?.keyEquivalentModifierMask, .command)
    }

    // MARK: - Palette list

    private func item(_ title: String, _ section: CommandPaletteItem.Section) -> CommandPaletteItem {
        CommandPaletteItem(id: title, section: section, title: title, perform: {})
    }

    func testEmptyQueryListsEverythingBySection() {
        let items = [item("Show Outline", .commands), item("Plan", .headings), item("Focus Mode", .commands),
                     item("Places", .headings)]
        let groups = CommandPaletteFilter.groups(items, query: "  ")
        XCTAssertEqual(groups.map(\.section), [.headings, .commands])
        XCTAssertEqual(groups.map { $0.items.map(\.title) },
                       [["Plan", "Places"], ["Show Outline", "Focus Mode"]])
    }

    func testOnlyMatchingItemsAreListed() {
        let items = [item("Plan", .headings), item("Places", .headings), item("Show Outline", .commands),
                     item("Export as PDF…", .commands), item("Appearance Settings…", .commands)]
        let groups = CommandPaletteFilter.groups(items, query: "pla")
        XCTAssertEqual(groups.map(\.section), [.headings], "a section without matches is left out")
        XCTAssertEqual(groups[0].items.map(\.title), ["Plan", "Places"])
        XCTAssertTrue(CommandPaletteFilter.groups(items, query: "zzz").isEmpty)
    }

    func testBetterMatchesComeFirstAndTiesKeepTheirOrder() {
        let items = [item("Refresh", .commands), item("Show Outline", .commands)]
        XCTAssertEqual(CommandPaletteFilter.groups(items, query: "sh")[0].items.map(\.title),
                       ["Show Outline", "Refresh"], "a match at a word start scores higher")
        let ties = [item("Quote Block", .commands), item("Quote", .commands), item("Quote Mark", .commands)]
        XCTAssertEqual(CommandPaletteFilter.groups(ties, query: "quote")[0].items.map(\.title),
                       ["Quote Block", "Quote", "Quote Mark"], "equal scores keep the given order")
    }

    func testSelectionStaysInTheList() {
        XCTAssertEqual(CommandPaletteFilter.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(CommandPaletteFilter.moved(1, by: 1, count: 3), 2)
        XCTAssertEqual(CommandPaletteFilter.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(CommandPaletteFilter.moved(5, by: 1, count: 0), 0)
    }

    /// VoiceOver gets one phrase per row (title, subtitle, state) and hears
    /// the shortcut as its value; moving the selection speaks the same.
    func testPaletteRowsReadAsOnePhrase() {
        let toggle = CommandPaletteItem(id: "o", section: .commands, title: "Show Outline",
                                        shortcut: "⌃⌘S", isOn: true, perform: {})
        XCTAssertEqual(toggle.accessibilityLabel, "Show Outline, on")
        XCTAssertEqual(toggle.accessibilityValue, "⌃⌘S")
        XCTAssertEqual(toggle.selectionAnnouncement, "Show Outline, on, ⌃⌘S")

        let heading = CommandPaletteItem(id: "h", section: .headings, title: "Plan",
                                         subtitle: "H2", perform: {})
        XCTAssertEqual(heading.accessibilityLabel, "Plan, H2")
        XCTAssertEqual(heading.selectionAnnouncement, "Plan, H2")
        XCTAssertEqual(item("Focus Mode", .commands).accessibilityValue, "")
    }

    func testSelectionTextIsReadableOnEveryAccent() {
        let dark: [AccentChoice] = AccentChoice.allCases.filter {
            PaletteSelectionStyle.usesDarkText(on: $0.color)
        }
        XCTAssertEqual(dark, [.orange, .green], "white text on the others, as on the board's blue")
        XCTAssertTrue(PaletteSelectionStyle.usesDarkText(on: .white))
        XCTAssertFalse(PaletteSelectionStyle.usesDarkText(on: .black))
        for accent in AccentChoice.allCases {
            let l = PaletteSelectionStyle.relativeLuminance(accent.color)
            let contrast = PaletteSelectionStyle.usesDarkText(on: accent.color)
                ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 3, "\(accent)")
        }
    }

    /// Subtitle and shortcut (12 pt) on the selected row need 3:1 as well,
    /// after their opacity blends them into the accent.
    func testSecondarySelectionTextIsReadableOnEveryAccent() throws {
        let alpha = PaletteSelectionStyle.selectedSecondaryOpacity
        for accent in AccentChoice.allCases {
            let fill = try XCTUnwrap(accent.color.usingColorSpace(.sRGB))
            let text: CGFloat = PaletteSelectionStyle.usesDarkText(on: accent.color) ? 0 : 1
            func blend(_ c: CGFloat) -> CGFloat { alpha * text + (1 - alpha) * c }
            let blended = NSColor(srgbRed: blend(fill.redComponent), green: blend(fill.greenComponent),
                                  blue: blend(fill.blueComponent), alpha: 1)
            let a = PaletteSelectionStyle.relativeLuminance(blended)
            let b = PaletteSelectionStyle.relativeLuminance(fill)
            let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 3, "\(accent)")
        }
    }
}
