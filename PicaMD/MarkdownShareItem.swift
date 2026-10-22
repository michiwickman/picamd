import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the toolbar's Share button hands to the system share sheet: the
/// document as a Markdown file.
///
/// A saved document shares its file on disk while that file holds what
/// the editor shows. With unsaved edits, or for an untitled document,
/// the text is written to a fresh temporary `.md` instead (under the
/// file's own name when there is one). That happens only when a share
/// target asks for the file, not each time the toolbar is drawn.
struct MarkdownShareItem: Transferable, Sendable {
    /// The document's file, nil while untitled.
    let savedURL: URL?
    /// The document's text as the editor shows it.
    let text: String
    /// File name without extension for an untitled document.
    let untitledName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdown) { item in
            SentTransferredFile(try item.fileURL())
        }
    }

    /// Name shown in the share sheet's preview.
    var displayName: String {
        savedURL?.lastPathComponent ?? "\(Self.sanitized(untitledName)).md"
    }

    /// Temporary copies older than this are removed on the next share.
    /// A share target may still be reading a recent one.
    static let staleCopyAge: TimeInterval = 60 * 60

    /// The file to share: the saved file if it holds `text`, otherwise a
    /// temporary copy of `text` under `directory` (one fresh subfolder per
    /// share, so two documents never overwrite each other's file).
    func fileURL(temporaryDirectory directory: URL = FileManager.default.temporaryDirectory,
                 now: Date = Date()) throws -> URL {
        let data = Data(text.utf8)
        // Comparing the file's content, not the window's "Edited" flag: the
        // file can also lag behind until autosave has written it. Decoded
        // the way the document was opened, not as UTF-8 bytes: a file in
        // UTF-16, Windows 1252 or with a byte order mark never matched, and
        // an unedited file was shared as a re-encoded copy without its
        // tags and other metadata.
        if let savedURL, let onDisk = try? Data(contentsOf: savedURL),
           let decoded = TextFileEncoding.decode(onDisk),
           decoded.text.unicodeScalars.elementsEqual(text.unicodeScalars) {
            return savedURL
        }
        let root = directory.appendingPathComponent("PicaMD Share", isDirectory: true)
        Self.removeCopies(in: root, olderThan: now.addingTimeInterval(-Self.staleCopyAge))
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(displayName, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Earlier share copies hold document text in the temporary folder;
    /// nothing else removes them before the system's own purge.
    private static func removeCopies(in root: URL, olderThan cutoff: Date) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    /// Longest file name `sanitized` returns, in UTF-8 bytes: file
    /// systems allow 255, and ".md" plus some margin must still fit.
    static let maxNameBytes = 200

    /// A file name the file system accepts: no path separators, no
    /// leading dot, not empty, not too long (a long first heading would
    /// otherwise make the write fail).
    static func sanitized(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        var limited = ""
        var bytes = 0
        for character in cleaned {
            bytes += character.utf8.count
            if bytes > maxNameBytes { break }
            limited.append(character)
        }
        limited = limited.trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "Untitled" : limited
    }
}
