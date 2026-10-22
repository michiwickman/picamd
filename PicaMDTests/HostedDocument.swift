import XCTest
import AppKit
@testable import PicaMD

/// A real document window from the test host's `DocumentGroup`: SwiftUI's
/// own NSDocument subclass, `ContentView`, and the `PicaMDTextView` inside
/// it. For behaviour that only exists in that assembly — SwiftUI's undo
/// registration on the document binding, NSDocument's revert and change
/// count — which a bare NSTextView cannot show.
@MainActor
struct HostedDocument {
    let document: NSDocument
    let textView: PicaMDTextView

    var undoManager: UndoManager { textView.undoManager! }

    /// A new untitled document.
    static func untitled(file: StaticString = #filePath, line: UInt = #line) throws -> HostedDocument {
        let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        return try attach(to: document, file: file, line: line)
    }

    /// The document at `url`, opened the way Finder or File ▸ Open would.
    static func open(_ url: URL, in testCase: XCTestCase,
                     file: StaticString = #filePath, line: UInt = #line) throws -> HostedDocument {
        let opened = testCase.expectation(description: "open \(url.lastPathComponent)")
        var result: NSDocument?
        var failure: Error?
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            result = doc
            failure = error
            opened.fulfill()
        }
        testCase.wait(for: [opened], timeout: 10)
        if let failure { throw failure }
        let document = try XCTUnwrap(result, file: file, line: line)
        return try attach(to: document, file: file, line: line)
    }

    private static func attach(to document: NSDocument,
                               file: StaticString, line: UInt) throws -> HostedDocument {
        var found: PicaMDTextView?
        for _ in 0..<100 {
            spin(0.05)
            if let content = document.windowControllers.first?.window?.contentView,
               let tv = firstTextView(in: content) {
                found = tv
                break
            }
        }
        let textView = try XCTUnwrap(found, "no editor in the document window", file: file, line: line)
        // Let the first highlight and binding round trip settle.
        spin(0.2)
        textView.window?.makeFirstResponder(textView)
        return HostedDocument(document: document, textView: textView)
    }

    /// Close without the save prompt; the documents are throwaway. Takes
    /// the file off the recents list too: opening it put it there, and a
    /// temporary file left in the list is a dead entry.
    func close() {
        let url = document.fileURL
        document.updateChangeCount(.changeCleared)
        document.close()
        HostedDocument.spin(0.1)
        if let url { RecentDocumentsStore.remove(url) }
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spin until `condition` holds or `timeout` passes; returns the result.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
        return condition()
    }

    private static func firstTextView(in view: NSView) -> PicaMDTextView? {
        if let tv = view as? PicaMDTextView { return tv }
        for sub in view.subviews {
            if let tv = firstTextView(in: sub) { return tv }
        }
        return nil
    }
}
