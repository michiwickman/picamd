import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes documents the user opens in PicaMD into Spotlight via
/// `CoreSpotlight`. macOS already indexes Markdown content as plain
/// text via the built-in importer; this layer adds the editor-aware
/// metadata (frontmatter title, tags) so Spotlight returns smarter
/// results for PicaMD-known files: a search for a tag, for example,
/// hits notes that explicitly tag themselves rather than guessing.
///
/// Why CoreSpotlight from the main app instead of a `mdimporter`
/// bundle? Apple deprecated `mdimporter` for new code in macOS 11,
/// and a separate bundle would need its own Developer ID signing
/// (same Quick-Look-style Phase-9 blocker). CoreSpotlight from the
/// main app:
/// 1. ships with the regular app code-signing,
/// 2. only indexes files the user actually opens (sandboxes nicely),
/// 3. naturally covers the "PicaMD smart-index" use-case without
///    trying to replace the system's general Markdown indexer.
@MainActor
enum SpotlightIndexer {

    /// Domain identifier used for every PicaMD-indexed item. Lets
    /// `deleteSearchableItems(withDomainIdentifiers:)` clear them all
    /// at once if the user wants to wipe PicaMD's metadata.
    static let domain = "de.michaelwittmann.PicaMD.documents"

    /// Index a freshly-opened or saved document.
    ///
    /// - Parameters:
    ///   - url: The document's on-disk URL. Used both as the unique
    ///     identifier and as a deep-link target Spotlight passes back
    ///     when the user picks the result (handled by `MarkdownDocument`'s
    ///     `init(configuration:)` re-opening the URL).
    ///   - source: The full Markdown source. Front-matter is parsed
    ///     for `title:` and `tags:`; the body's first ~240 characters
    ///     become the `contentDescription` shown in Spotlight's
    ///     preview row.
    static func index(url: URL, source: String) {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)

        // Title — frontmatter wins, fall back to filename without ext.
        let frontmatter = Frontmatter.build(from: source)
        attrs.title = frontmatter.title
            ?? url.deletingPathExtension().lastPathComponent

        // Tags → keywords. CoreSpotlight folds keywords into the
        // search-term match, so a doc tagged `swift` shows up for
        // queries containing "swift" even when the body doesn't.
        if !frontmatter.tags.isEmpty {
            attrs.keywords = frontmatter.tags
        }

        // Description — the first 240 chars of body, frontmatter stripped.
        // Newlines collapsed to spaces so Spotlight's one-line preview
        // doesn't show ragged whitespace.
        attrs.contentDescription = previewText(from: source,
                                                strippingFrontmatter: frontmatter)

        attrs.kind = "Markdown Document"
        attrs.contentURL = url
        attrs.contentModificationDate = Date()

        let item = CSSearchableItem(uniqueIdentifier: url.absoluteString,
                                     domainIdentifier: domain,
                                     attributeSet: attrs)

        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                NSLog("PicaMD: spotlight index failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Remove the index entry for a document the user moved to trash
    /// or whose URL no longer matters. Currently unused — orphan
    /// entries are harmless because Spotlight won't return results
    /// for a file the system has already noticed is gone — but kept
    /// for future cleanup hooks.
    static func remove(url: URL) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [url.absoluteString]
        ) { error in
            if let error = error {
                NSLog("PicaMD: spotlight remove failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private static func previewText(from source: String,
                                     strippingFrontmatter fm: Frontmatter) -> String {
        let nsSource = source as NSString
        let body: String
        if let fmRange = fm.range, NSMaxRange(fmRange) <= nsSource.length {
            body = nsSource.substring(from: NSMaxRange(fmRange))
        } else {
            body = source
        }
        // Collapse whitespace runs into single spaces — over just enough
        // of the body for 240 characters, not the whole document (this
        // runs on every save and autosave).
        var collapsed = ""
        var pendingSpace = false
        var count = 0
        for ch in body {
            if ch.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if count >= 240 { return collapsed + "…" }
            if pendingSpace {
                collapsed.append(" ")
                count += 1
                pendingSpace = false
            }
            collapsed.append(ch)
            count += 1
        }
        return collapsed
    }
}
