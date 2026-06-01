import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Application delegate that customises the cold-launch path.
///
/// Stock SwiftUI `DocumentGroup` opens a default `NSOpenPanel` when
/// the app starts with no document arguments and no restored state.
/// That panel only lets the user pick existing files — they have to
/// cancel out and press ⌘N to start fresh, which is friction.
///
/// We intercept that flow and present our own `NSOpenPanel` instead,
/// configured with an accessoryView carrying a **Create New File…**
/// button. The button cancels the open panel, runs an `NSSavePanel`
/// to pick where the new file should live, writes an empty `.md`
/// file there, and opens it as a regular document.
///
/// We deliberately do **not** install a custom `NSDocumentController`
/// subclass here. SwiftUI's `DocumentGroup` ships its own
/// `PlatformDocumentController` subclass and expects to be the
/// `.shared` singleton; pre-empting it crashes during launch.
@MainActor
final class PicaMDAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's DocumentGroup ignores the
        // `applicationShouldOpenUntitledFile` /
        // `applicationOpenUntitledFile` hooks at cold-launch — its
        // own internal launch path is what surfaces the default open
        // panel. So instead of relying on those hooks, we wait one
        // runloop turn (so SwiftUI's scene init has settled) and
        // then check whether anything actually opened. If nothing
        // did, we present our own NSOpenPanel with the
        // **Create New File…** accessoryView.
        // Never present the modal launch panel under XCTest: `runModal()`
        // blocks the host app's main thread, so the test runner can't
        // establish its connection and the whole suite times out.
        guard !Self.isRunningTests else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if NSDocumentController.shared.documents.isEmpty {
                self.runLaunchOpenPanel()
            }
        }
    }

    /// True when the process is hosting an XCTest bundle.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Kept for completeness — fires when the user double-clicks the
    /// dock icon and there are no open windows. Tells NSApp we want
    /// to take over the path; the actual panel goes through the same
    /// `runLaunchOpenPanel()` as the cold-launch case.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        runLaunchOpenPanel()
        return true
    }

    /// Don't quit while no windows are open yet — between launch and
    /// the user picking a file in our panel, there's a brief no-window
    /// window that would otherwise trigger termination.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Launch open panel

    /// Guards against re-entrant invocations (e.g. dock-icon tap while
    /// the panel is already visible on screen).
    private var isPresentingLaunchPanel = false

    private func runLaunchOpenPanel() {
        guard !Self.isRunningTests else { return }
        guard !isPresentingLaunchPanel else { return }
        isPresentingLaunchPanel = true
        defer { isPresentingLaunchPanel = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open an existing Markdown file or create a new one."
        panel.prompt = "Open"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.accessoryView = makeAccessoryView()
        panel.isAccessoryViewDisclosed = true

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            NSDocumentController.shared.openDocument(withContentsOf: url,
                                                       display: true) { _, _, _ in }
        }
        // Cancelled or "Create New" path: app stays in dock,
        // user can keep working via menu File > Open / File > New.
    }

    private func makeAccessoryView() -> NSView {
        let label = NSTextField(labelWithString: "or")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let button = NSButton(title: "Create New File…",
                               target: self,
                               action: #selector(createNewClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular

        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        return container
    }

    // MARK: - Create-new flow

    @objc private func createNewClicked(_ sender: NSButton) {
        guard let openPanel = sender.window as? NSOpenPanel else { return }
        let initialDirectory = openPanel.directoryURL
        // Cancel the open panel — `cancel(_:)` triggers the system
        // Cancel button programmatically. `runModal()` returns
        // `.cancel`; we then fall into the post-runModal branch in
        // `runLaunchOpenPanel` and proceed to the save flow here.
        openPanel.cancel(sender)

        // Bounce one runloop turn so the cancel propagates fully
        // before the save panel comes up.
        DispatchQueue.main.async { [weak self] in
            self?.runCreateNewFlow(startingAt: initialDirectory)
        }
    }

    private func runCreateNewFlow(startingAt initialDirectory: URL?) {
        let savePanel = NSSavePanel()
        savePanel.title = "Create New Markdown File"
        savePanel.message = "Choose where to save the new file."
        savePanel.prompt = "Create"
        savePanel.nameFieldStringValue = "Untitled.md"
        savePanel.canCreateDirectories = true
        savePanel.showsHiddenFiles = false
        if let dir = initialDirectory {
            savePanel.directoryURL = dir
        }
        if let mdType = UTType(filenameExtension: "md") {
            savePanel.allowedContentTypes = [mdType]
        }

        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }
        createAndOpen(at: url)
    }

    private func createAndOpen(at url: URL) {
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url,
                                                   display: true) { doc, _, error in
            if doc == nil {
                // PicaMD: orphan guard — remove zero-byte file if open failed
                try? FileManager.default.removeItem(at: url)
            }
            if let error = error {
                NSAlert(error: error).runModal()
            }
        }
    }
}
