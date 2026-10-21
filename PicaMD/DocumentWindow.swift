import SwiftUI
import AppKit

/// The document window's file and its modification date, for the
/// inspector's File section and the Share button, and the window's width
/// for the column limits (`WindowColumnLimits`).
///
/// SwiftUI's `DocumentGroup` does not publish the file URL, but it sets
/// `NSWindow.representedURL` (on open, Save and Save As), so the URL is
/// observed there. The date is re-read when the URL changes, after any
/// save, and when the window becomes key (another app may have written
/// the file).
@MainActor
final class DocumentWindowObserver: ObservableObject {
    @Published private(set) var fileURL: URL?
    @Published private(set) var modified: Date?
    /// The window's own width. SwiftUI's views can't report it once the
    /// columns ask for more room than the window has: then the content
    /// is laid out wider than the window and overflows it.
    @Published private(set) var width: CGFloat?

    private weak var window: NSWindow?
    private var urlObservation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        urlObservation = window.observe(\.representedURL, options: [.initial, .new]) { [weak self] window, _ in
            // KVO fires on the thread that set the URL: AppKit sets it on
            // the main thread.
            MainActor.assumeIsolated {
                self?.update(url: window.representedURL)
            }
        }
        let center = NotificationCenter.default
        updateWidth(window.frame.width)
        tokens.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                         object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if let window { self?.updateWidth(window.frame.width) }
            }
        })
        tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                         object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModified() }
        })
        // Posted just before a write (possibly off the main thread); the
        // new date exists only once the write is done.
        tokens.append(center.addObserver(forName: .picaMDDocumentWillWrite,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModified(after: .milliseconds(600)) }
        })
    }

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func updateWidth(_ new: CGFloat) {
        if new != width { width = new }
    }

    private func update(url: URL?) {
        if url != fileURL { fileURL = url }
        refreshModified()
    }

    func refreshModified(after delay: Duration? = nil) {
        refreshTask?.cancel()
        let url = fileURL
        refreshTask = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            // A stat on a network or iCloud volume can stall, and this
            // runs on every window activation: read it off the main actor.
            let date = await Task.detached(priority: .utility) {
                (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.value
            guard !Task.isCancelled, let self, self.fileURL == url else { return }
            if date != self.modified { self.modified = date }
        }
    }
}

/// File ▸ New Tab (⌘T).
@MainActor
enum DocumentTabs {
    /// Creates an untitled document and puts its window into the tab
    /// group of the frontmost document window.
    ///
    /// ⌘N leaves tabbing to the system setting (System Settings ▸ Desktop
    /// & Dock ▸ Prefer tabs). `NSDocumentController.newDocument` builds
    /// and shows the window synchronously under `DocumentGroup` (probe on
    /// macOS 27.0.1), so the new window can be found right after the call.
    static func newTab() {
        let host = NSApp.mainWindow.flatMap { isDocumentWindow($0) ? $0 : nil }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSDocumentController.shared.newDocument(nil)
        guard let host,
              let created = NSApp.windows.first(where: {
                  !before.contains(ObjectIdentifier($0)) && isDocumentWindow($0)
              })
        else { return }
        // With "Prefer tabs: Always" the system already tabbed it.
        if host.tabbedWindows?.contains(created) == true { return }
        host.addTabbedWindow(created, ordered: .above)
        created.makeKeyAndOrderFront(nil)
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        NSDocumentController.shared.documents.contains { document in
            document.windowControllers.contains { $0.window === window }
        }
    }
}
