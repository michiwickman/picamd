import SwiftUI

/// File-menu entries for exporting the active document. HTML is
/// always available (in-process render); PDF / DOCX / EPUB go
/// through pandoc, and explain how to install it when it's missing.
struct ExportCommands: Commands {
    @FocusedValue(\.activeDocumentContext) private var doc: ActiveDocumentContext?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu("Export As") {
                Button("HTML…") {
                    if let d = doc {
                        ExportCoordinator.exportHTML(
                            source: d.source(),
                            documentURL: d.fileURL,
                            paletteForStyling: d.palette()
                        )
                    }
                }
                .disabled(doc == nil)

                Divider()

                Button("PDF…") { exportViaPandoc(.pdf) }
                    .disabled(doc == nil)
                Button("Word Document (.docx)…") { exportViaPandoc(.docx) }
                    .disabled(doc == nil)
                Button("EPUB…") { exportViaPandoc(.epub) }
                    .disabled(doc == nil)
            }
        }
    }

    @MainActor
    private func exportViaPandoc(_ format: PandocBridge.Format) {
        guard let d = doc else { return }
        ExportCoordinator.exportViaPandoc(source: d.source(), documentURL: d.fileURL, format: format)
    }
}
