import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown")
    }
}

struct MarkdownDocument: FileDocument {
    var text: String
    /// How the file was encoded on disk; a save writes it back the same
    /// way. A reference shared by SwiftUI's copies of this value — see
    /// `TextFileEncodingBox`.
    let encoding: TextFileEncodingBox

    init(text: String = "", encoding: TextFileEncoding = .utf8) {
        self.text = text
        self.encoding = TextFileEncodingBox(encoding)
    }

    static var readableContentTypes: [UTType] { [.markdown, .plainText] }
    static var writableContentTypes: [UTType] { [.markdown, .plainText] }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // UTF-8 with or without BOM, UTF-16 with BOM, and 8-bit text as
        // Windows 1252 or ISO Latin-1 open. Both 8-bit decodings map bytes
        // one to one, so an unedited save writes the same bytes back and
        // nothing is lost to a wrong guess. Damaged UTF-8 and a broken
        // byte order mark are refused with the standard "couldn't open"
        // alert (see `TextFileEncoding.decode`).
        guard let decoded = TextFileEncoding.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = decoded.text
        self.encoding = TextFileEncodingBox(decoded.encoding)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let (data, convertedFrom) = Self.encodedForSave(text, encoding: encoding)
        // Notify any open editor coordinator that we're about to write
        // to disk, so its FileWatcher can ignore the resulting
        // vnode-event. We include a per-write nonce so coordinators
        // watching DIFFERENT documents don't suppress their own
        // legitimate external-edit events when an unrelated window
        // happens to save.
        var info: [String: String] = [Self.willWriteNonceKey: UUID().uuidString,
                                      Self.willWriteTextKey: text]
        if let convertedFrom { info[Self.willWriteConvertedFromKey] = convertedFrom }
        NotificationCenter.default.post(name: .picaMDDocumentWillWrite, object: nil, userInfo: info)
        return FileWrapper(regularFileWithContents: data)
    }

    /// The bytes a save writes, in the document's encoding. Text that
    /// encoding can't hold is written as UTF-8, and the box switches to
    /// UTF-8 so later saves don't flip the file back; the name of the old
    /// encoding comes back so the editor can tell the user once.
    static func encodedForSave(_ text: String,
                               encoding box: TextFileEncodingBox) -> (data: Data, convertedFrom: String?) {
        let original = box.value
        let (data, written) = original.encode(text)
        guard written != original else { return (data, nil) }
        box.value = written
        return (data, original.displayName)
    }

    static let willWriteNonceKey = "PicaMDWillWriteNonce"
    static let willWriteTextKey = "PicaMDWillWriteText"
    /// Present when this save had to leave the file's encoding: the name
    /// of the encoding it was in (now UTF-8).
    static let willWriteConvertedFromKey = "PicaMDWillWriteConvertedFrom"
}

extension Notification.Name {
    static let picaMDDocumentWillWrite = Notification.Name("PicaMDDocumentWillWrite")
}
