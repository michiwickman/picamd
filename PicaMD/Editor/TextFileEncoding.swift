import Foundation
import os

/// How a document's bytes are encoded on disk, so a save writes them back
/// the way they came.
///
/// Opening used to accept UTF-8 only: anything else was refused, and a
/// UTF-8 byte order mark was dropped on read and never written again, so
/// simply saving changed the file.
struct TextFileEncoding: Equatable, Sendable {
    enum Charset: Equatable, Sendable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        /// "Western (Windows 1252)", what legacy Windows tools call ANSI.
        case windowsCP1252
        /// ISO 8859-1, for 8-bit files Windows 1252 can't read.
        case isoLatin1

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            case .windowsCP1252: return .windowsCP1252
            case .isoLatin1: return .isoLatin1
            }
        }

        /// The name macOS uses for the encoding (TextEdit, the Finder).
        var displayName: String {
            String.localizedName(of: stringEncoding)
        }
    }

    var charset: Charset
    /// Whether the file starts with a byte order mark. Always true for
    /// UTF-16, which is only detected by its mark.
    var hasBOM: Bool

    static let utf8 = TextFileEncoding(charset: .utf8, hasBOM: false)

    var displayName: String {
        hasBOM && charset == .utf8 ? charset.displayName + " (BOM)" : charset.displayName
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    private var bom: [UInt8] {
        guard hasBOM else { return [] }
        switch charset {
        case .utf8: return Self.utf8BOM
        case .utf16LittleEndian: return Self.utf16LEBOM
        case .utf16BigEndian: return Self.utf16BEBOM
        case .windowsCP1252, .isoLatin1: return []
        }
    }

    // MARK: - Reading

    /// The text in `data` and how it was encoded, or nil for a file that
    /// must not be opened as text.
    ///
    /// In this order: a UTF-8 or UTF-16 byte order mark; valid UTF-8; then
    /// the 8-bit fallbacks. Windows 1252 is tried first, because it is what
    /// non-UTF-8 text files from Windows almost always are and it decodes
    /// typographic quotes and the euro sign that ISO Latin-1 has as control
    /// codes. A file with one of the five bytes Windows 1252 leaves
    /// undefined falls back to ISO Latin-1, which maps every byte, so every
    /// byte survives an unedited save.
    ///
    /// Refused, as every non-UTF-8 file was before: a file whose byte order
    /// mark promises an encoding its bytes then break, and UTF-8 with a few
    /// damaged bytes (a stray or truncated byte). Read as 8-bit text these
    /// show every umlaut as two wrong characters, and the first character
    /// Windows 1252 can't hold (an emoji, an arrow) makes the save switch
    /// to UTF-8 and writes that garbage into the file for good.
    static func decode(_ data: Data) -> (text: String, encoding: TextFileEncoding)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: utf8BOM) {
            // `String(validating:as:)`, not `String(bytes:encoding:)`: the
            // Foundation decoder drops a second byte order mark right behind
            // the first, and an unedited save then lost three bytes.
            guard let text = String(validating: data.dropFirst(3), as: UTF8.self) else { return nil }
            return (text, TextFileEncoding(charset: .utf8, hasBOM: true))
        }
        if bytes.starts(with: utf16LEBOM) {
            guard data.count % 2 == 0,
                  let text = String(bytes: data.dropFirst(2), encoding: .utf16LittleEndian) else { return nil }
            return (text, TextFileEncoding(charset: .utf16LittleEndian, hasBOM: true))
        }
        if bytes.starts(with: utf16BEBOM) {
            guard data.count % 2 == 0,
                  let text = String(bytes: data.dropFirst(2), encoding: .utf16BigEndian) else { return nil }
            return (text, TextFileEncoding(charset: .utf16BigEndian, hasBOM: true))
        }
        if let text = String(bytes: data, encoding: .utf8) {
            return (text, .utf8)
        }
        if looksLikeDamagedUTF8(data) { return nil }
        if !data.contains(where: { cp1252Undefined.contains($0) }),
           let text = String(bytes: data, encoding: .windowsCP1252) {
            return (text, TextFileEncoding(charset: .windowsCP1252, hasBOM: false))
        }
        // ISO Latin-1 maps all 256 byte values, so this cannot fail.
        let text = String(bytes: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        return (text, TextFileEncoding(charset: .isoLatin1, hasBOM: false))
    }

    /// Invalid UTF-8 that is still mostly UTF-8: at least as many
    /// well-formed multi-byte sequences as bytes that fit none. Real 8-bit
    /// text forms such a sequence only by chance (Windows 1252 "ß“" is the
    /// bytes DF 93), while most of its non-ASCII letters stand next to
    /// ASCII and are invalid UTF-8 on their own.
    static func looksLikeDamagedUTF8(_ data: Data) -> Bool {
        let b = [UInt8](data)
        var wellFormed = 0
        var invalid = 0
        var i = 0
        while i < b.count {
            let lead = b[i]
            if lead < 0x80 { i += 1; continue }
            // Lengths and second-byte ranges from RFC 3629, section 4.
            let length: Int
            var second: ClosedRange<UInt8> = 0x80...0xBF
            switch lead {
            case 0xC2...0xDF: length = 2
            case 0xE0: length = 3; second = 0xA0...0xBF
            case 0xED: length = 3; second = 0x80...0x9F
            case 0xE1...0xEF: length = 3
            case 0xF0: length = 4; second = 0x90...0xBF
            case 0xF4: length = 4; second = 0x80...0x8F
            case 0xF1...0xF3: length = 4
            default: length = 0
            }
            let complete = length > 0 && i + length <= b.count
                && second.contains(b[i + 1])
                && (2..<length).allSatisfy { (0x80...0xBF).contains(b[i + $0]) }
            if complete {
                wellFormed += 1
                i += length
            } else {
                invalid += 1
                i += 1
            }
        }
        return wellFormed > 0 && wellFormed >= invalid
    }

    /// Bytes Windows 1252 assigns no character to.
    private static let cp1252Undefined: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]

    // MARK: - Writing

    /// `text` as bytes in this encoding, BOM included. When the encoding
    /// can't hold every character (a Windows 1252 file that now contains
    /// an arrow or an emoji), the text is written as UTF-8 instead and the
    /// encoding that was actually used is returned with it, so the caller
    /// can tell the user and keep writing UTF-8 from then on.
    func encode(_ text: String) -> (data: Data, written: TextFileEncoding) {
        if let body = text.data(using: charset.stringEncoding, allowLossyConversion: false) {
            return (Data(bom) + body, self)
        }
        return (Data(text.utf8), .utf8)
    }
}

/// The encoding a document was read in, shared by every copy SwiftUI makes
/// of the `MarkdownDocument` value, so a save that had to fall back to
/// UTF-8 sticks for the saves after it instead of flipping the file back
/// and forth. Locked because `fileWrapper` runs on the save queue.
final class TextFileEncodingBox: Sendable {
    private let state: OSAllocatedUnfairLock<TextFileEncoding>

    init(_ encoding: TextFileEncoding) {
        state = OSAllocatedUnfairLock(initialState: encoding)
    }

    var value: TextFileEncoding {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
