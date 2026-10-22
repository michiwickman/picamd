import XCTest
@testable import PicaMD

/// Documents that are not UTF-8 were refused, and a UTF-8
/// byte order mark was dropped on read and never written back. Byte
/// fixtures for each encoding: it must open, and an unedited save must
/// write exactly the bytes that were read.
final class TextFileEncodingTests: XCTestCase {

    private func roundTrip(_ bytes: [UInt8], expectText text: String, encoding: TextFileEncoding,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let decoded = TextFileEncoding.decode(Data(bytes)) else {
            return XCTFail("refused", file: file, line: line)
        }
        XCTAssertEqual(decoded.text, text, file: file, line: line)
        XCTAssertEqual(decoded.encoding, encoding, file: file, line: line)
        let box = TextFileEncodingBox(decoded.encoding)
        let saved = MarkdownDocument.encodedForSave(decoded.text, encoding: box)
        XCTAssertEqual([UInt8](saved.data), bytes, "save changed the bytes", file: file, line: line)
        XCTAssertNil(saved.convertedFrom, file: file, line: line)
    }

    /// "# Grüße\r\n" in UTF-16 code units.
    private let sampleUnits: [UInt16] = Array("# Grüße\r\n".utf16)

    func testUTF8WithoutBOM() {
        roundTrip(Array("# Grüße\n".utf8), expectText: "# Grüße\n", encoding: .utf8)
    }

    func testUTF8KeepsItsBOM() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("# Grüße\n".utf8)
        roundTrip(bytes, expectText: "# Grüße\n",
                  encoding: TextFileEncoding(charset: .utf8, hasBOM: true))
        // The mark is not part of the text, so front matter at the top of a
        // BOM file is still found.
        XCTAssertFalse(TextFileEncoding.decode(Data(bytes))?.text.hasPrefix("\u{FEFF}") ?? true)
    }

    /// A tool that prepends a mark without checking leaves two. The second
    /// is text (U+FEFF); dropping it made an unedited save shorter.
    func testASecondUTF8ByteOrderMarkSurvives() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("A\n".utf8)
        roundTrip(bytes, expectText: "\u{FEFF}A\n",
                  encoding: TextFileEncoding(charset: .utf8, hasBOM: true))
    }

    func testUTF16LittleEndianWithBOM() {
        let bytes: [UInt8] = [0xFF, 0xFE] + sampleUnits.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        roundTrip(bytes, expectText: "# Grüße\r\n",
                  encoding: TextFileEncoding(charset: .utf16LittleEndian, hasBOM: true))
    }

    func testUTF16BigEndianWithBOM() {
        let bytes: [UInt8] = [0xFE, 0xFF] + sampleUnits.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        roundTrip(bytes, expectText: "# Grüße\r\n",
                  encoding: TextFileEncoding(charset: .utf16BigEndian, hasBOM: true))
    }

    /// Typical "ANSI" file from Windows: umlauts plus the euro sign and
    /// typographic quotes, which only Windows 1252 has (0x80, 0x93, 0x94).
    func testWindows1252() {
        let bytes: [UInt8] = Array("Gr".utf8) + [0xFC, 0xDF] + Array("e ".utf8)
            + [0x80, 0x20, 0x93] + Array("q".utf8) + [0x94, 0x0A]
        roundTrip(bytes, expectText: "Grüße € \u{201C}q\u{201D}\n",
                  encoding: TextFileEncoding(charset: .windowsCP1252, hasBOM: false))
    }

    /// 0x81 is undefined in Windows 1252; ISO Latin-1 maps every byte, so
    /// the file still opens and survives a save byte for byte.
    func testISOLatin1WhenWindows1252CannotReadIt() {
        let bytes: [UInt8] = Array("caf".utf8) + [0xE9, 0x81, 0x0A]
        roundTrip(bytes, expectText: "café\u{81}\n",
                  encoding: TextFileEncoding(charset: .isoLatin1, hasBOM: false))
    }

    func testEmptyFileIsUTF8() {
        roundTrip([], expectText: "", encoding: .utf8)
    }

    /// Every byte value opens and comes back unchanged: an unedited save
    /// damages no 8-bit file.
    func testArbitraryBytesSurviveAnUneditedSave() throws {
        let bytes = (0...255).map(UInt8.init)
        let decoded = try XCTUnwrap(TextFileEncoding.decode(Data(bytes)))
        let saved = MarkdownDocument.encodedForSave(decoded.text, encoding: TextFileEncodingBox(decoded.encoding))
        XCTAssertEqual([UInt8](saved.data), bytes)
    }

    // MARK: - Refused: opening would turn the text into garbage

    /// UTF-8 with one stray byte. Read as Windows 1252 it showed
    /// "GrÃ¼ÃŸeÿ", and typing an emoji made the save write that as UTF-8.
    func testDamagedUTF8IsRefused() {
        XCTAssertNil(TextFileEncoding.decode(Data(Array("# Grüße\n".utf8) + [0xFF])))
        // A file cut off in the middle of its last character.
        XCTAssertNil(TextFileEncoding.decode(Data(Array("Grüße und Füße ".utf8) + [0xC3])))
    }

    func testBrokenByteOrderMarkIsRefused() {
        // UTF-16 LE with a lone high surrogate (D800).
        XCTAssertNil(TextFileEncoding.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8, 0x42, 0x00])))
        // UTF-16 with an odd byte count.
        XCTAssertNil(TextFileEncoding.decode(Data([0xFE, 0xFF, 0x00, 0x41, 0x00])))
        // UTF-8 BOM, then a byte that is not UTF-8.
        XCTAssertNil(TextFileEncoding.decode(Data([0xEF, 0xBB, 0xBF] + Array("Gr".utf8) + [0xFC, 0x0A])))
    }

    /// Windows 1252 text may form a valid UTF-8 pair by chance ("ß“" is
    /// DF 93); the umlauts next to ASCII letters still mark it as 8-bit.
    func testWindows1252WithAnAccidentalUTF8PairStillOpens() {
        let bytes: [UInt8] = [0x84] + Array("Gru".utf8) + [0xDF, 0x93] + Array(" und Gr".utf8)
            + [0xFC, 0xDF] + Array("e\n".utf8)
        roundTrip(bytes, expectText: "\u{201E}Gruß\u{201C} und Grüße\n",
                  encoding: TextFileEncoding(charset: .windowsCP1252, hasBOM: false))
    }

    // MARK: - Characters the encoding can't hold

    func testUnrepresentableTextIsSavedAsUTF8OnceAndForAll() {
        let box = TextFileEncodingBox(TextFileEncoding(charset: .windowsCP1252, hasBOM: false))
        let first = MarkdownDocument.encodedForSave("Pfeil → hier", encoding: box)
        XCTAssertEqual(String(data: first.data, encoding: .utf8), "Pfeil → hier")
        XCTAssertNotNil(first.convertedFrom, "the user must be told about the conversion")
        XCTAssertEqual(box.value, .utf8)

        // Removing the arrow again does not flip the file back to 1252.
        let second = MarkdownDocument.encodedForSave("Grüße", encoding: box)
        XCTAssertEqual([UInt8](second.data), Array("Grüße".utf8))
        XCTAssertNil(second.convertedFrom, "the note is shown once")
    }

    func testRepresentableEditsStayInTheOriginalEncoding() {
        let box = TextFileEncodingBox(TextFileEncoding(charset: .windowsCP1252, hasBOM: false))
        let saved = MarkdownDocument.encodedForSave("Preis: 5 €", encoding: box)
        XCTAssertEqual([UInt8](saved.data), Array("Preis: 5 ".utf8) + [0x80])
        XCTAssertNil(saved.convertedFrom)
    }

    func testUTF16DocumentKeepsItsBOMOnEdit() {
        let box = TextFileEncodingBox(TextFileEncoding(charset: .utf16LittleEndian, hasBOM: true))
        let saved = MarkdownDocument.encodedForSave("a", encoding: box)
        XCTAssertEqual([UInt8](saved.data), [0xFF, 0xFE, 0x61, 0x00])
    }
}

/// The same through a real document window: open a Windows 1252 file and a
/// UTF-8 file with BOM, save, and compare the bytes on disk.
@MainActor
final class DocumentEncodingTests: XCTestCase {

    private var hosted: HostedDocument?
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDEncoding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        hosted?.close()
        hosted = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func save(_ doc: HostedDocument) throws {
        let saved = expectation(description: "save")
        var failure: Error?
        doc.document.save(to: try XCTUnwrap(doc.document.fileURL),
                          ofType: try XCTUnwrap(doc.document.fileType),
                          for: .saveOperation) { error in
            failure = error
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        if let failure { throw failure }
    }

    func testWindows1252FileOpensAndSavesUnchanged() throws {
        let bytes: [UInt8] = Array("# Gr".utf8) + [0xFC, 0xDF] + Array("e\n".utf8)
        let url = directory.appendingPathComponent("latin.md")
        try Data(bytes).write(to: url)

        let doc = try HostedDocument.open(url, in: self)
        hosted = doc
        XCTAssertEqual(doc.textView.string, "# Grüße\n")

        try save(doc)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), bytes)
    }

    /// A refused file reports an error instead of opening as garbage.
    func testDamagedUTF8FileDoesNotOpen() throws {
        let url = directory.appendingPathComponent("damaged.md")
        try Data(Array("# Grüße\n".utf8) + [0xFF]).write(to: url)
        XCTAssertThrowsError(try HostedDocument.open(url, in: self))
    }

    func testUTF8BOMSurvivesAnEditAndSave() throws {
        let url = directory.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("Text\n".utf8)).write(to: url)

        let doc = try HostedDocument.open(url, in: self)
        hosted = doc
        XCTAssertEqual(doc.textView.string, "Text\n")
        doc.textView.setSelectedRange(NSRange(location: 4, length: 0))
        doc.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        HostedDocument.spin(0.1)

        try save(doc)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0xEF, 0xBB, 0xBF] + Array("Text!\n".utf8))
    }
}
