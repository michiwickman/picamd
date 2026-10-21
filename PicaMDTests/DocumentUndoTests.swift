import XCTest
import AppKit
import ObjectiveC
@testable import PicaMD

/// Records every undo registration that actually lands (registration
/// enabled). Installed on a live document's undo manager by swapping the
/// instance's class, because SwiftUI keeps its own reference to the manager
/// the document was created with: assigning a fresh one would leave SwiftUI
/// registering on the old instance, out of sight.
final class RecordingUndoManager: UndoManager {
    nonisolated(unsafe) static var registrations: [String] = []
    /// Open a group when something registers outside one, the way AppKit's
    /// per-event grouping does in the app. The test host only opens that
    /// automatic group once; after a test closes it, the next registration
    /// would raise "must begin a group". Opening it by hand before each
    /// keystroke is no substitute: the text view never coalesces typing
    /// into an action from before a group that was already open.
    nonisolated(unsafe) static var opensGroupOnRegistration = false

    private func openGroupIfNeeded() {
        if Self.opensGroupOnRegistration, isUndoRegistrationEnabled, groupingLevel == 0 {
            beginUndoGrouping()
        }
    }

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        if isUndoRegistrationEnabled { Self.registrations.append("\(type(of: target)).\(selector)") }
        openGroupIfNeeded()
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
    }

    override func prepare(withInvocationTarget target: Any) -> Any {
        if isUndoRegistrationEnabled { Self.registrations.append("\(type(of: target)) invocation") }
        openGroupIfNeeded()
        return super.prepare(withInvocationTarget: target)
    }

    override func __registerUndoWithTarget(_ target: Any,
                                           handler undoHandler: @escaping @Sendable (Any) -> Void) {
        if isUndoRegistrationEnabled { Self.registrations.append("\(type(of: target)) handler") }
        openGroupIfNeeded()
        super.__registerUndoWithTarget(target, handler: undoHandler)
    }
}

/// The editor writes every change into the FileDocument
/// binding, and SwiftUI registers an undo action of its own for each such
/// write, on the same undo manager the NSTextView uses. Measured before the
/// fix, typing "word" left eight registrations: one SwiftUI action per
/// keystroke, and because each one landed on top of the text view's typing
/// action, the text view could not coalesce either and registered a new one
/// per character too. ⌘Z took back one character at a time and every step
/// held a copy of the document.
///
/// The undo stack must belong to the text view alone.
@MainActor
final class DocumentUndoTests: XCTestCase {

    private var hosted: HostedDocument?

    override func tearDown() async throws {
        if let hosted {
            object_setClass(hosted.undoManager, UndoManager.self)
            hosted.close()
        }
        hosted = nil
        RecordingUndoManager.registrations = []
        RecordingUndoManager.opensGroupOnRegistration = false
        try await super.tearDown()
    }

    private func recordedDocument() throws -> HostedDocument {
        let doc = try HostedDocument.untitled()
        hosted = doc
        object_setClass(doc.undoManager, RecordingUndoManager.self)
        RecordingUndoManager.registrations = []
        return doc
    }

    /// An edit the text view makes without registering undo (the way a
    /// reload replaces the buffer) must stay off the stack: the binding
    /// write that follows it may not register anything.
    func testBindingWriteRegistersNoUndoAction() throws {
        let doc = try recordedDocument()
        doc.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        doc.textView.didChangeText()
        HostedDocument.spin(0.1)

        XCTAssertEqual(doc.textView.string, "abc")
        XCTAssertEqual(RecordingUndoManager.registrations, [],
                       "the FileDocument binding write registered undo of its own")
    }

    /// One typed word, one undo registration: the text view's coalesced
    /// typing action.
    func testTypingAWordRegistersOneUndoAction() throws {
        let doc = try recordedDocument()
        for ch in "word" {
            doc.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        HostedDocument.spin(0.1)

        XCTAssertEqual(doc.textView.string, "word")
        XCTAssertEqual(RecordingUndoManager.registrations.count, 1,
                       "registrations: \(RecordingUndoManager.registrations)")
        XCTAssertEqual(doc.undoManager.undoActionName, "Typing")
    }

    /// Undoing and redoing writes the binding too; that may not leave
    /// SwiftUI actions on the redo or undo stack either.
    func testUndoAndRedoRegisterOnlyTheTextViewsInverse() throws {
        let doc = try recordedDocument()
        let um = doc.undoManager
        doc.textView.insertText("word", replacementRange: NSRange(location: NSNotFound, length: 0))
        HostedDocument.spin(0.1)
        // Close the event's group the way the end of a run loop pass would.
        while um.groupingLevel > 0 { um.endUndoGrouping() }
        RecordingUndoManager.registrations = []

        um.undo()
        HostedDocument.spin(0.1)
        XCTAssertEqual(doc.textView.string, "")
        XCTAssertEqual(RecordingUndoManager.registrations.count, 1,
                       "undo registered: \(RecordingUndoManager.registrations)")

        RecordingUndoManager.registrations = []
        um.redo()
        HostedDocument.spin(0.1)
        XCTAssertEqual(doc.textView.string, "word")
        XCTAssertEqual(RecordingUndoManager.registrations.count, 1,
                       "redo registered: \(RecordingUndoManager.registrations)")
    }

    /// Without SwiftUI's registration the text view's own undo actions
    /// are what mark the document edited, and undoing them marks it clean.
    func testTypingStillMarksTheDocumentEditedAndUndoCleansIt() throws {
        let doc = try HostedDocument.untitled()
        hosted = doc
        let um = doc.undoManager
        doc.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        HostedDocument.spin(0.1)
        while um.groupingLevel > 0 { um.endUndoGrouping() }
        XCTAssertTrue(HostedDocument.spin(until: { doc.document.isDocumentEdited }))

        um.undo()
        XCTAssertTrue(HostedDocument.spin(until: { !doc.document.isDocumentEdited }))
        XCTAssertEqual(doc.textView.string, "")
    }

    /// Type one character per event without moving the caret: each
    /// keystroke's group opens when the text view registers (and not at
    /// all when it coalesces), and closes before the next keystroke, with
    /// a run loop turn in between as in the app, where NSDocument updates
    /// its change count on a later pass.
    private func typeCoalesced(_ text: String, in doc: HostedDocument) {
        let um = doc.undoManager
        for ch in text {
            XCTAssertEqual(um.groupingLevel, 0)
            doc.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            while um.groupingLevel > 0 { um.endUndoGrouping() }
            HostedDocument.spin(0.05)
        }
        HostedDocument.spin(0.1)
    }

    private func coalescingDocument() throws -> HostedDocument {
        let doc = try recordedDocument()
        RecordingUndoManager.opensGroupOnRegistration = true
        // Close the host's own automatic group if it is open.
        while doc.undoManager.groupingLevel > 0 { doc.undoManager.endUndoGrouping() }
        return doc
    }

    /// Typing that continues after a save, without a caret move, must mark
    /// the document edited again. The text view folds it into the typing
    /// action from before the save and registers nothing new, and nothing
    /// else counts the change since SwiftUI's registration is gone: the
    /// window stayed clean, closing it asked nothing, and a clean document
    /// is reverted silently when the file changes on disk.
    func testTypingAfterASaveMarksTheDocumentEditedAgain() throws {
        let doc = try coalescingDocument()
        typeCoalesced("ab", in: doc)
        XCTAssertTrue(HostedDocument.spin(until: { doc.document.isDocumentEdited }))
        XCTAssertEqual(RecordingUndoManager.registrations.count, 1, "the typing before the save coalesces")

        doc.document.updateChangeCount(.changeCleared)
        XCTAssertFalse(doc.document.isDocumentEdited)
        typeCoalesced("cd", in: doc)

        XCTAssertEqual(doc.textView.string, "abcd")
        XCTAssertTrue(HostedDocument.spin(until: { doc.document.isDocumentEdited }),
                      "typing after a save left the document clean")
        XCTAssertEqual(RecordingUndoManager.registrations.count, 2,
                       "one new typing action after the save, coalesced again")

        // Undo takes back exactly what came after the save, which is the
        // saved state again.
        doc.undoManager.undo()
        XCTAssertEqual(doc.textView.string, "ab")
        XCTAssertTrue(HostedDocument.spin(until: { !doc.document.isDocumentEdited }))
    }

    /// Same after an autosave in place: the next autosave, and the one at
    /// quit, only write when the document has unautosaved changes.
    func testTypingAfterAnAutosaveCountsAsUnautosaved() throws {
        let doc = try coalescingDocument()
        typeCoalesced("ab", in: doc)
        XCTAssertTrue(HostedDocument.spin(until: { doc.document.hasUnautosavedChanges }))

        doc.document.updateChangeCount(.changeAutosaved)
        XCTAssertFalse(doc.document.hasUnautosavedChanges)
        typeCoalesced("cd", in: doc)

        XCTAssertTrue(HostedDocument.spin(until: { doc.document.hasUnautosavedChanges }),
                      "typing after an autosave would not be autosaved")
    }
}
