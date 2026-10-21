import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the welcome/launch window (a SwiftUI `WelcomeView` hosted via
/// `NSHostingView`). A single instance is held by `PicaMDAppDelegate`;
/// `present()` shows or re-fronts it, and it auto-dismisses (orders out)
/// when a real document window becomes main. All actions route through
/// `NSDocumentController.shared`, exactly like ⌘N / File > Open.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to PicaMD"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // Close only: the board draws all three lights, but a fixed-size
        // launcher has nothing to zoom, and minimising it would leave the
        // app without a visible window (Xcode's welcome window does the same).
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isRestorable = false                 // never resurrected on relaunch
        window.tabbingMode = .disallowed            // never join the document tab group
        window.isExcludedFromWindowsMenu = true
        window.level = .normal
        window.center()

        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: makeView())

        // Dismiss the launcher once a real document window takes focus.
        // Selector-based + `@objc nonisolated` (the notification can be
        // delivered before Swift 6 considers us main-actor-isolated), then
        // hop to the main actor — same pattern as `documentWillWrite`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentWindowBecameMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func documentWindowBecameMain(_ note: Notification) {
        // Don't capture `note`/its window (non-Sendable) across the hop —
        // re-query NSApp.mainWindow on the main actor instead.
        Task { @MainActor [weak self] in
            guard let self = self, let welcome = self.window else { return }
            // Only a *document* window replaces the hub. Settings (⌘,)
            // becoming main used to hide it too, leaving no window at all
            // once Settings was closed.
            if let main = NSApp.mainWindow, main !== welcome {
                let isDocument = NSDocumentController.shared.document(for: main) != nil
                let isSettings = main.identifier?.rawValue.contains("Settings") == true
                if isDocument || !isSettings {
                    welcome.orderOut(nil)
                }
            }
        }
    }

    /// Show (or re-front) the welcome window and bring the app forward.
    func present() {
        // Re-read recents (files trashed or deleted since) and rebuild the
        // view so the accent and the first-row selection are current.
        RecentDocumentsMenuModel.shared.refresh()
        window?.contentView = NSHostingView(rootView: makeView())
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The document's own types, as File ▸ Open (⌘O) uses: Markdown and
    /// plain text. Only `.md` used to be selectable here.
    static var openContentTypes: [UTType] { MarkdownDocument.readableContentTypes }

    // MARK: - View

    private func makeView() -> WelcomeView {
        WelcomeView(
            onNew: { [weak self] in self?.newDocument() },
            onOpen: { [weak self] in self?.openDocument() },
            onOpenRecent: { RecentDocumentsStore.open($0) },
            recents: RecentDocumentsMenuModel.shared
        )
    }

    // MARK: - Actions

    private func newDocument() {
        // Untitled, in-memory MarkdownDocument — no file path until ⌘S.
        NSDocumentController.shared.newDocument(nil)
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Markdown file to open."
        panel.prompt = "Open"
        panel.allowedContentTypes = Self.openContentTypes
        // Sheet on the welcome window — NOT runModal() — so we never block
        // the runloop (and never trip the XCTest hang the old modal panel did).
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error { NSAlert(error: error).runModal() }
            }
        }
    }
}
