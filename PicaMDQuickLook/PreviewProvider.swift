import Foundation
import QuickLookUI

/// Quick-Look preview extension for `.md` / `.markdown` files. Lets
/// Finder show a styled HTML preview of any Markdown file when the
/// user hits Space — no need to open PicaMD itself.
///
/// The provider is sandboxed and runs in its own process, so it can't
/// reach the user's chosen palette in `UserDefaults`. Instead it
/// renders with `MarkdownToHTML.render(_, palette: nil)` which falls
/// back to a `prefers-color-scheme`-driven CSS theme — light or dark
/// depending on the user's system setting.
/// Per Apple's `QLPreviewProvider.h` doc-comment:
///
/// > Data-based preview extensions should subclass QLPreviewProvider
/// > in their principal object. **The subclass should conform to
/// > QLPreviewingController.**
///
/// `QLPreviewingController` is a *protocol* (not a base class), so the
/// methods we implement here are protocol conformances, not overrides.
/// The protocol's three optional entry points are differently-shaped
/// callbacks for the same job; we implement the modern
/// `providePreview(for:completionHandler:)` form.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        do {
            // Decoded the way the app opens files: a Windows 1252 or UTF-16
            // file opened in PicaMD but showed no preview.
            let bytes = try Data(contentsOf: request.fileURL)
            guard let source = TextFileEncoding.decode(bytes)?.text else {
                throw NSError(domain: "PicaMD.QuickLook",
                              code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Not in a text encoding PicaMD opens"])
            }
            let title = request.fileURL.deletingPathExtension().lastPathComponent
            let html = MarkdownToHTML.render(source, title: title)
            guard let data = html.data(using: .utf8) else {
                throw NSError(domain: "PicaMD.QuickLook",
                              code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode HTML"])
            }
            let reply = QLPreviewReply(dataOfContentType: .html,
                                        contentSize: .zero) { _ in data }
            reply.stringEncoding = .utf8
            reply.title = title
            completionHandler(reply, nil)
        } catch {
            completionHandler(nil, error)
        }
    }
}
