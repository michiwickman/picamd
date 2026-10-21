import AppKit

/// No icons in the menu bar's menus (board `MenuSpec`, macOS 27 look).
///
/// Linked against the macOS 27 SDK, AppKit hides most menu images by
/// itself (visibility `.automatic`). Items AppKit adds on its own still
/// come with a visible image: Edit ▸ Find, AutoFill, Emoji & Symbols,
/// Share and the window list (measured on macOS 27.0.1). SwiftUI has no
/// switch for this, so one pass over the
/// main menu sets `preferredImageVisibility = .hidden` everywhere, again
/// whenever items are added (SwiftUI rebuilds menus when the focused
/// window changes) and when a menu opens (AppKit fills in the View and
/// Edit additions then). Menus outside the menu bar (context menus, pop-up
/// buttons) are left alone. The same passes hide the File menu's stock
/// duplicate of Open… (`hideStockOpenDuplicate`).
@MainActor
final class MenuIconSuppressor: NSObject {
    private var passScheduled = false

    func install() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(itemsAdded(_:)),
                           name: NSMenu.didAddItemNotification, object: nil)
        center.addObserver(self, selector: #selector(trackingBegan(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        hideMainMenuImages()
    }

    /// Hide every item's image in `menu` and its submenus. Only items
    /// whose setting differs are touched: each change posts a menu
    /// change notification, and a pass that always wrote would keep
    /// AppKit busy.
    /// - Returns: the number of items changed.
    @discardableResult
    static func hideImages(in menu: NSMenu) -> Int {
        var changed = 0
        for item in menu.items {
            if item.preferredImageVisibility != .hidden {
                item.preferredImageVisibility = .hidden
                changed += 1
            }
            if let submenu = item.submenu {
                changed += hideImages(in: submenu)
            }
        }
        return changed
    }

    /// Hide the File menu's second "Open…". Built against the macOS 27
    /// SDK, `DocumentGroup` adds a stock Open… (`openDocument:`) in a
    /// section of its own after the New group, and drops its ⌘O there
    /// because PicaMD's own Open… ⌘O (in the New group, next to Open
    /// Recent) already claims it. SwiftUI has no placement that names
    /// that section, so the stock item is hidden instead, together with
    /// the separator that would otherwise double the one before it.
    /// - Returns: the number of items changed.
    @discardableResult
    static func hideStockOpenDuplicate(in menu: NSMenu) -> Int {
        let openDocument = #selector(NSDocumentController.openDocument(_:))
        let items = menu.items
        let hasOwnOpen = items.contains {
            $0.action != openDocument && !$0.isHidden
                && $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == .command
        }
        guard hasOwnOpen else { return 0 }
        var changed = 0
        for (index, item) in items.enumerated() where item.action == openDocument && !item.isHidden {
            item.isHidden = true
            changed += 1
            let before = items[..<index].last { !$0.isHidden }
            let after = items[(index + 1)...].first { !$0.isHidden }
            if let before, let after, before.isSeparatorItem, after.isSeparatorItem {
                after.isHidden = true
                changed += 1
            }
        }
        return changed
    }

    private func hideMainMenuImages() {
        guard let mainMenu = NSApp.mainMenu else { return }
        Self.hideImages(in: mainMenu)
        for item in mainMenu.items {
            if let submenu = item.submenu { Self.hideStockOpenDuplicate(in: submenu) }
        }
    }

    @objc private func itemsAdded(_ note: Notification) {
        // Many items arrive at once when SwiftUI rebuilds a menu: one
        // pass after the burst.
        guard !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.passScheduled = false
                self?.hideMainMenuImages()
            }
        }
    }

    @objc private func trackingBegan(_ note: Notification) {
        // Before the menu draws, for the items AppKit added just now.
        hideMainMenuImages()
    }
}
