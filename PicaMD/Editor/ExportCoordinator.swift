import AppKit
import UniformTypeIdentifiers

/// Drives the "Export As…" actions from the File menu. Each format
/// gets its own menu item so the user picks the format from the menu
/// itself — no extra "pick format" sheet, no extra clicks. Pandoc
/// formats explain how to install pandoc when it's missing.
@MainActor
enum ExportCoordinator {

    /// Exports the active document's source string to HTML using the
    /// in-process renderer. Always available (no external dep).
    static func exportHTML(source: String,
                            documentURL: URL?,
                            paletteForStyling: Palette? = nil) {
        let suggested = baseName(for: documentURL) + ".html"
        runSavePanel(
            suggestedFilename: suggested,
            allowedTypes: [.html],
            tag: "HTML",
            directory: documentURL?.deletingLastPathComponent()
        ) { url in
            let html = MarkdownToHTML.render(source, palette: paletteForStyling)
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentError(error,
                              title: "HTML export failed")
            }
        }
    }

    /// Pandoc-driven PDF export. Surfaces a "pandoc not installed"
    /// alert with a Homebrew hint instead of failing silently.
    static func exportViaPandoc(source: String,
                                 documentURL: URL?,
                                 format: PandocBridge.Format) {
        // Locating pandoc spawns `which`; keep that off the main thread.
        Task.detached(priority: .userInitiated) {
            let found = PandocBridge.locate() != nil
            await MainActor.run {
                if found {
                    runPandocSavePanel(source: source, documentURL: documentURL, format: format)
                } else {
                    presentPandocMissingAlert(format: format)
                }
            }
        }
    }

    /// `notes.md` → `notes`, `README.markdown` → `README`. (Replacing
    /// ".md" anywhere in the name turned `a.md.notes.md` into `anotes`.)
    static func baseName(for documentURL: URL?) -> String {
        guard let url = documentURL else { return "Untitled" }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func runPandocSavePanel(source: String,
                                           documentURL: URL?,
                                           format: PandocBridge.Format) {
        let suggested = "\(baseName(for: documentURL)).\(format.fileExtension)"
        let resourceDirectory = documentURL?.deletingLastPathComponent()
        let allowedTypes: [UTType] = {
            switch format {
            case .pdf:  return [.pdf]
            case .docx: return [UTType(filenameExtension: "docx") ?? .data]
            case .epub: return [UTType(filenameExtension: "epub") ?? .data]
            }
        }()
        runSavePanel(
            suggestedFilename: suggested,
            allowedTypes: allowedTypes,
            tag: format.displayName,
            directory: resourceDirectory
        ) { url in
            // pandoc runs synchronously and can take a few seconds for
            // large docs / PDF — hop off main so the UI stays responsive,
            // then come back to surface success/errors.
            Task.detached(priority: .userInitiated) {
                do {
                    try PandocBridge.export(markdown: source, to: url, format: format,
                                            resourceDirectory: resourceDirectory)
                    await MainActor.run {
                        // Reveal in Finder so the user can verify the export.
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    await MainActor.run {
                        presentError(error,
                                      title: "\(format.displayName) export failed")
                    }
                }
            }
        }
    }

    // MARK: - Save panel

    private static func runSavePanel(suggestedFilename: String,
                                      allowedTypes: [UTType],
                                      tag: String,
                                      directory: URL? = nil,
                                      completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        // Next to the document by default, so relative image paths in an
        // exported HTML file still point at the document's assets.
        if let directory { panel.directoryURL = directory }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = allowedTypes
        panel.message = "Export as \(tag)"
        panel.title = "Export Document"
        panel.isExtensionHidden = false

        // Dispatch async so we don't block the menu-action chain;
        // panel runs modally on the active window.
        DispatchQueue.main.async {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    // MARK: - Error UI

    private static func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentPandocMissingAlert(format: PandocBridge.Format) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Pandoc is required for \(format.displayName) export"
        alert.informativeText = """
        PicaMD uses pandoc to render \(format.displayName). Install it via Homebrew:

            brew install pandoc

        For PDF in particular, pandoc also needs a LaTeX engine such as
        `basictex` or `mactex`. HTML export works without pandoc.
        """
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("brew install pandoc", forType: .string)
        }
    }
}
