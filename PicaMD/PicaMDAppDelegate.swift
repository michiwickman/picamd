import AppKit
import SwiftUI

/// Application delegate that customises the cold-launch path.
///
/// Stock SwiftUI `DocumentGroup` would surface a Finder open panel when
/// the app starts with no document and no restored state — friction.
/// Instead we present a **welcome window** (recents + New + Open),
/// PicaTeX-style, so a double-click lands on a hub. New documents are
/// untitled / in-memory until the first ⌘S (standard DocumentGroup
/// behaviour via `newDocument(nil)`).
///
/// We deliberately do **not** install a custom `NSDocumentController`
/// subclass: SwiftUI's `DocumentGroup` ships its own
/// `PlatformDocumentController` and expects to be the `.shared`
/// singleton; pre-empting it crashes during launch.
@MainActor
final class PicaMDAppDelegate: NSObject, NSApplicationDelegate {

    private var welcomeController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never show the welcome window under XCTest: it would hijack the
        // launch path and (if it ran anything modal) hang the test runner.
        guard !Self.isRunningTests else { return }
        // Let the DocumentGroup launch path settle (auto-untitled creation,
        // state restoration, and any file passed via Finder/`open` args all
        // resolve within a couple hundred ms).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            let controller = NSDocumentController.shared
            // DocumentGroup auto-creates ONE blank untitled document at cold
            // launch (and ignores the delegate untitled hooks). We show the
            // welcome hub ONLY when every open document is such a fresh
            // untitled/unedited one — i.e. nothing real was opened or
            // restored. Requiring `!isEmpty` avoids a race where a file
            // launched from Finder hasn't finished opening yet (documents
            // momentarily empty) — in that case we must NOT pop the welcome
            // window in front of the document that's about to appear.
            let autoUntitled = controller.documents.filter {
                $0.fileURL == nil && !$0.isDocumentEdited
            }
            guard !controller.documents.isEmpty,
                  controller.documents.count == autoUntitled.count else { return }
            autoUntitled.forEach { $0.close() }
            self.showWelcomeWindow()
        }
    }

    /// True when the process is hosting an XCTest bundle.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Don't let AppKit auto-create a blank untitled document at launch or
    /// reopen. Combined with `NSShowAppCentricOpenPanelInsteadOfUntitledFile
    /// = false` (set in PicaMDApp.init), the launch creates NOTHING — no
    /// open panel, no blank doc — so the deferred check in
    /// `applicationDidFinishLaunching` / `applicationShouldHandleReopen`
    /// can show the welcome window cleanly. (The welcome "New Document"
    /// button calls `newDocument(nil)` directly, which is unaffected.)
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Dock-icon click / reopen with no visible windows → show the hub.
    /// (Per design, we do NOT re-show the welcome window automatically
    /// when the last document window closes — only here and at launch.)
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return true }
        if !flag && NSDocumentController.shared.documents.isEmpty {
            showWelcomeWindow()
        }
        return true
    }

    /// Stay alive with no windows (the welcome window is transient and the
    /// app is a hub between documents). Quit is via ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Welcome window

    private func showWelcomeWindow() {
        guard !Self.isRunningTests else { return }
        if welcomeController == nil {
            welcomeController = WelcomeWindowController()
        }
        welcomeController?.present()
    }
}
