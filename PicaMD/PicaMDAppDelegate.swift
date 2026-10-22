import AppKit
import SwiftUI
import os

/// What the app shows once launching has finished.
enum LaunchAction: Equatable {
    /// Something is already on screen or on its way: a file opened from
    /// Finder, a Service, or windows restored from the last session.
    case none
    case showWelcome
    case newDocument
}

/// The launch decision, kept free of AppKit so it can be tested.
enum LaunchDecision {
    /// - Parameters:
    ///   - showWelcomeOnLaunch: Settings ▸ General / the welcome window's
    ///     checkbox.
    ///   - launchedWithContent: AppKit's `NSApplicationLaunchIsDefaultLaunchKey`
    ///     was false: the launch opens files, runs a Service or restores
    ///     windows. Those documents arrive after `didFinishLaunching`.
    ///   - hasOpenWindows: a document (or another window) is already open.
    static func action(showWelcomeOnLaunch: Bool,
                       launchedWithContent: Bool,
                       hasOpenWindows: Bool) -> LaunchAction {
        if launchedWithContent || hasOpenWindows { return .none }
        return showWelcomeOnLaunch ? .showWelcome : .newDocument
    }

    /// What a file or restore launch falls back to when no window is up
    /// after the grace period. Never a new document: the open may simply
    /// still be reading (an iCloud file that downloads, a slow share), and
    /// a document is listed only once it has been read, so a slow open
    /// looks the same as a failed one. An untitled document then stood
    /// next to the file for good; the welcome window closes by itself when
    /// the document's window arrives.
    static func fallbackAction(hasOpenWindows: Bool) -> LaunchAction {
        hasOpenWindows ? .none : .showWelcome
    }
}

/// Application delegate that customises the cold-launch path.
///
/// `DocumentGroup` is told not to present anything at launch
/// (`.defaultLaunchBehavior(.suppressed)` in `PicaMDApp`), so a plain
/// launch starts with no window at all. This delegate then shows the
/// **welcome window** (recents + New + Open), or a new untitled document
/// when Settings ▸ General ▸ "Show welcome window…" is off. Files opened
/// from Finder, Services and restored windows are left alone.
///
/// Measured on macOS 27.0.1 with a DocumentGroup probe app (no PicaMD
/// launch): without `.suppressed`, DocumentGroup creates and shows an
/// untitled window before `applicationDidFinishLaunching` and never calls
/// `applicationShouldOpenUntitledFile`, so the old "close it after 0.2 s,
/// then show welcome" path flashed an empty window on every launch. With
/// `.suppressed` there is no window and no open panel (also without the
/// undocumented `NSShowAppCentricOpenPanelInsteadOfUntitledFile` default),
/// a Finder open and state restoration still open their documents, and
/// both report `NSApplicationLaunchIsDefaultLaunchKey` = false.
///
/// We deliberately do **not** install a custom `NSDocumentController`
/// subclass: SwiftUI's `DocumentGroup` ships its own
/// `PlatformDocumentController` and expects to be the `.shared`
/// singleton; pre-empting it crashes during launch.
@MainActor
final class PicaMDAppDelegate: NSObject, NSApplicationDelegate {

    private var welcomeController: WelcomeWindowController?
    private let menuIconSuppressor = MenuIconSuppressor()
    /// `log stream --level info --predicate 'subsystem == "de.michaelwittmann.PicaMD" AND category == "launch"'`
    private static let log = Logger(subsystem: "de.michaelwittmann.PicaMD", category: "launch")
    /// How long a file or restore launch gets to put a window up before
    /// the app falls back to the plain-launch behaviour (a file that
    /// fails to open would otherwise leave no window at all).
    private static let contentLaunchGrace: TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuIconSuppressor.install()
        // Never show the welcome window under XCTest: it would hijack the
        // launch path and (if it ran anything modal) hang the test runner.
        guard !Self.isRunningTests else { return }
        // Drop whatever a crashed or killed previous session left in the
        // MCP registry; documents re-register as their windows open.
        ActiveDocumentsRegistry.shared.reset(synchronously: false)

        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let action = LaunchDecision.action(
            showWelcomeOnLaunch: Self.showWelcomeOnLaunch,
            launchedWithContent: !isDefaultLaunch,
            hasOpenWindows: !NSDocumentController.shared.documents.isEmpty)
        Self.log.info("launch: default=\(isDefaultLaunch) documents=\(NSDocumentController.shared.documents.count) visibleWindows=\(Self.visibleWindowCount) action=\(String(describing: action), privacy: .public)")
        perform(action)

        guard !isDefaultLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentLaunchGrace) { [weak self] in
            guard let self else { return }
            let fallback = LaunchDecision.fallbackAction(
                hasOpenWindows: !NSDocumentController.shared.documents.isEmpty
                    || Self.visibleWindowCount > 0)
            Self.log.info("launch fallback: documents=\(NSDocumentController.shared.documents.count) visibleWindows=\(Self.visibleWindowCount) action=\(String(describing: fallback), privacy: .public)")
            self.perform(fallback)
        }
    }

    private func perform(_ action: LaunchAction) {
        switch action {
        case .none: break
        case .showWelcome: showWelcomeWindow()
        case .newDocument: NSDocumentController.shared.newDocument(nil)
        }
    }

    private static var showWelcomeOnLaunch: Bool {
        UserDefaults.standard.bool(forKey: EditorPreferences.showWelcomeWindowKey)
    }

    /// Titled windows on screen: documents, Settings, an error alert.
    private static var visibleWindowCount: Int {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count
    }

    /// True when the process is hosting an XCTest bundle.
    private static var isRunningTests: Bool { AppEnvironment.isHostingTests }

    /// Dock-icon click with no visible window and no document → the
    /// welcome window, whatever the launch setting says.
    /// Returning false tells AppKit the click is handled, so it doesn't
    /// add an untitled document behind the welcome window. With documents
    /// open but none visible (all minimised), AppKit restores one.
    /// (Per design, we do NOT re-show the welcome window automatically
    /// when the last document window closes — only here and at launch.)
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return true }
        guard !flag, NSDocumentController.shared.documents.isEmpty else { return true }
        Self.log.info("reopen: showing welcome")
        showWelcomeWindow()
        return false
    }

    /// Nothing is open once we're gone — tell the MCP sidecar.
    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        ActiveDocumentsRegistry.shared.reset(synchronously: true)
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
