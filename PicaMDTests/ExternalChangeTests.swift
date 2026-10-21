import XCTest
import AppKit
@testable import PicaMD

/// Another program changes the file while it is open.
///
/// The editor's own reload bypassed NSDocument: it asked "Reload / Keep
/// mine" even when there was nothing to lose, read the file as UTF-8 only
/// (a Windows 1252 file silently did not reload), replaced the text behind
/// NSDocument's back — which left the document marked edited, its file
/// date stale and the text view's undo actions pointing into the old text.
///
/// Now: a document without unsaved changes reverts through NSDocument, the
/// way TextEdit does; one with unsaved changes asks, and only reverts when
/// the user says so.
@MainActor
final class ExternalChangeTests: XCTestCase {

    private var hosted: HostedDocument?
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let sheet = hosted?.textView.window?.attachedSheet {
            hosted?.textView.window?.endSheet(sheet)
        }
        hosted?.close()
        hosted = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func openFile(_ bytes: [UInt8]) throws -> (HostedDocument, URL) {
        let url = directory.appendingPathComponent("doc.md")
        try Data(bytes).write(to: url)
        let doc = try HostedDocument.open(url, in: self)
        hosted = doc
        // The watcher attaches on the first highlight pass after the window
        // has its URL.
        HostedDocument.spin(0.5)
        return (doc, url)
    }

    /// Type through the text view and close the undo group the way the end
    /// of the event would, so NSDocument counts the change.
    private func type(_ text: String, in doc: HostedDocument) {
        doc.textView.setSelectedRange(NSRange(location: (doc.textView.string as NSString).length, length: 0))
        doc.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        HostedDocument.spin(0.1)
        while doc.undoManager.groupingLevel > 0 { doc.undoManager.endUndoGrouping() }
        XCTAssertTrue(HostedDocument.spin(until: { doc.document.isDocumentEdited }))
    }

    private func sheetButton(_ title: String, in doc: HostedDocument) -> NSButton? {
        guard let content = doc.textView.window?.attachedSheet?.contentView else { return nil }
        func find(_ view: NSView) -> NSButton? {
            if let b = view as? NSButton, b.title == title { return b }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        return find(content)
    }

    private func diskDate(_ url: URL) throws -> Date? {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func testCleanDocumentRevertsSilentlyThroughNSDocument() throws {
        let (doc, url) = try openFile(Array("one\n".utf8))
        // Another program saves in Windows 1252 ("Grüße").
        try Data(Array("Gr".utf8) + [0xFC, 0xDF] + Array("e\n".utf8)).write(to: url, options: .atomic)

        XCTAssertTrue(HostedDocument.spin(until: { doc.textView.string == "Grüße\n" }),
                      "clean document did not reload: \(doc.textView.string.debugDescription)")
        XCTAssertNil(doc.textView.window?.attachedSheet, "nothing to lose, nothing to ask")
        XCTAssertFalse(doc.document.isDocumentEdited)
        XCTAssertEqual(doc.document.fileModificationDate, try diskDate(url))
        XCTAssertFalse(doc.undoManager.canUndo, "undo would replay edits into the replaced text")
    }

    func testEditedDocumentAsksAndKeepsTheEditsByDefault() throws {
        let (doc, url) = try openFile(Array("one\n".utf8))
        type("mine", in: doc)
        try Data("theirs\n".utf8).write(to: url, options: .atomic)

        XCTAssertTrue(HostedDocument.spin(until: { doc.textView.window?.attachedSheet != nil }),
                      "unsaved edits must not be replaced without asking")
        XCTAssertEqual(doc.textView.string, "one\nmine")
        let keep = try XCTUnwrap(sheetButton("Keep My Changes", in: doc))
        // Return must keep, not discard (the old prompt's default was Reload).
        XCTAssertEqual(doc.textView.window?.attachedSheet?.defaultButtonCell?.title, "Keep My Changes")
        keep.performClick(nil)
        HostedDocument.spin(0.2)

        XCTAssertEqual(doc.textView.string, "one\nmine")
        XCTAssertTrue(doc.document.isDocumentEdited)
        // The user decided; saving must not raise the conflict again.
        XCTAssertEqual(doc.document.fileModificationDate, try diskDate(url))
    }

    func testEditedDocumentRevertsWhenTheUserChoosesTheDiskVersion() throws {
        let (doc, url) = try openFile(Array("one\n".utf8))
        type("mine", in: doc)
        try Data("theirs\n".utf8).write(to: url, options: .atomic)

        XCTAssertTrue(HostedDocument.spin(until: { doc.textView.window?.attachedSheet != nil }))
        let revert = try XCTUnwrap(sheetButton("Revert", in: doc))
        revert.performClick(nil)

        XCTAssertTrue(HostedDocument.spin(until: { doc.textView.string == "theirs\n" }))
        XCTAssertFalse(doc.document.isDocumentEdited)
        XCTAssertEqual(doc.document.fileModificationDate, try diskDate(url))
        XCTAssertFalse(doc.undoManager.canUndo, "undo would replay edits into the replaced text")
    }

    /// A second write while the sheet is up was never shown to the user.
    /// Keeping the edits acknowledges only the version the sheet asked
    /// about, so saving still meets NSDocument's conflict check for the
    /// newer one.
    func testKeepingAcknowledgesOnlyTheVersionTheSheetAskedAbout() throws {
        let (doc, url) = try openFile(Array("one\n".utf8))
        type("mine", in: doc)
        try Data("theirs\n".utf8).write(to: url, options: .atomic)

        XCTAssertTrue(HostedDocument.spin(until: { doc.textView.window?.attachedSheet != nil }))
        let askedDate = try diskDate(url)
        // Another write while the user reads the sheet.
        try Data("theirs again\n".utf8).write(to: url, options: .atomic)
        // A distinct date even on a file system with coarse timestamps.
        let later = Date(timeIntervalSinceNow: 60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        HostedDocument.spin(0.2)

        try XCTUnwrap(sheetButton("Keep My Changes", in: doc)).performClick(nil)
        HostedDocument.spin(0.2)

        XCTAssertEqual(doc.textView.string, "one\nmine")
        XCTAssertEqual(doc.document.fileModificationDate, askedDate)
        XCTAssertNotEqual(doc.document.fileModificationDate, try diskDate(url),
                          "the unseen second write was acknowledged")
    }
}
