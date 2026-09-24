import AppKit

/// macOS Services-menu provider. Lets the user select text in any
/// other app, right-click → Services → "Open Selection in PicaMD",
/// and have a fresh PicaMD document open with that text as its body.
///
/// Wired up via `NSApplication.shared.servicesProvider` at app launch
/// (see `PicaMDApp.init`). Apple's Services system invokes the
/// `@objc` method named in `NSServices.NSMessage` from `Info.plist`.
final class ServicesProvider: NSObject {

    /// Match `NSMessage = openSelectionInPicaMD` in Info.plist.
    /// Selector signature is the standard one Apple's services API
    /// expects: (pasteboard, userData, errorOut).
    @objc func openSelectionInPicaMD(_ pasteboard: NSPasteboard,
                                       userData: String,
                                       error errorOut: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pasteboard.string(forType: .string) else {
            errorOut?.pointee = NSString(string: "No text on the pasteboard")
            return
        }
        do {
            // Drop the selection into a temp .md file and let the
            // standard document-open path turn it into an editable doc.
            // Going through `NSWorkspace.open` means the SwiftUI
            // DocumentGroup creates a normal PicaMD window for it,
            // tabs join the active group, all the editor wiring lights
            // up — same shape as opening any other .md.
            // Use a guaranteed-fresh, non-symlinked working directory to
            // avoid TOCTOU / symlink-planting on the predictable path.
            // `itemReplacementDirectory` always returns a new unique dir
            // beneath the system temp hierarchy for the given volume.
            let appropriateFor = FileManager.default.temporaryDirectory
            let baseDir = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: appropriateFor,
                create: true)
            // UUID filename prevents any predictable-name collision.
            let tempURL = baseDir.appendingPathComponent("Selection-\(UUID().uuidString).md")
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            // Open it in PicaMD itself (`NSWorkspace.open` used whatever
            // app is the default for .md) and as an *untitled* copy, so
            // ⌘S asks where to save instead of silently writing into a
            // temp folder the system may purge.
            MainActor.assumeIsolated {
                let controller = NSDocumentController.shared
                do {
                    _ = try controller.duplicateDocument(withContentsOf: tempURL,
                                                         copying: true,
                                                         displayName: "Selection")
                    try? FileManager.default.removeItem(at: baseDir)
                } catch {
                    controller.openDocument(withContentsOf: tempURL, display: true) { _, _, _ in }
                }
                NSApp.activate()
            }
        } catch let writeError {
            errorOut?.pointee = NSString(string: writeError.localizedDescription)
        }
    }
}
