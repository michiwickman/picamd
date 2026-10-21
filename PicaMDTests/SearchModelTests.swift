import XCTest
import AppKit
import SwiftUI
@testable import PicaMD

/// `SearchModel` against a recording driver: what reaches the editor,
/// option persistence and sharing, the find pasteboard, and the replace
/// rule. Every test gets its own defaults suite, notification centre and
/// find pasteboard, so nothing touches the user's real settings.
@MainActor
final class SearchModelTests: XCTestCase {

    @MainActor
    private final class RecordingDriver: SearchDriver {
        var parameterChanges = 0
        var actions: [SearchModel.Action] = []
        var closes = 0
        var selection: String?

        func searchParametersChanged() { parameterChanges += 1 }
        func performSearchAction(_ action: SearchModel.Action) { actions.append(action) }
        func searchDidClose() { closes += 1 }
        func selectedTextForFind() -> String? { selection }
    }

    private var defaults: UserDefaults!
    private var center: NotificationCenter!
    private var pasteboard: NSPasteboard!
    private var drivers: [RecordingDriver] = []

    override func setUp() async throws {
        defaults = makeTestDefaults("SearchModel")
        center = NotificationCenter()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        drivers = []
    }

    private func makeModel() -> (SearchModel, RecordingDriver) {
        let model = SearchModel(defaults: defaults, notificationCenter: center, findPasteboard: pasteboard)
        let driver = RecordingDriver()
        drivers.append(driver)   // `driver` is weak on the model
        model.driver = driver
        return (model, driver)
    }

    // MARK: - Reaching the editor (no polling)

    func testQueryChangeReachesTheDriverOnce() {
        let (model, driver) = makeModel()
        model.query = "tram"
        model.query = "tram"
        XCTAssertEqual(driver.parameterChanges, 1)
    }

    func testOpeningTwiceRefocusesWithoutASecondSearch() {
        let (model, driver) = makeModel()
        model.open(replace: false)
        let token = model.focusToken
        model.open(replace: true)
        XCTAssertEqual(driver.parameterChanges, 1)
        XCTAssertNotEqual(model.focusToken, token, "⌘F on an open bar re-focuses the field")
        XCTAssertTrue(model.showReplace)
    }

    func testCloseTellsTheDriver() {
        let (model, driver) = makeModel()
        model.open(replace: false)
        model.close()
        model.close()
        XCTAssertEqual(driver.closes, 1)
    }

    func testOptionChangeReachesTheDriver() {
        let (model, driver) = makeModel()
        model.options.wrapAround = false
        model.options.matchStyle = .startsWith
        model.options.matchStyle = .startsWith
        XCTAssertEqual(driver.parameterChanges, 2)
    }

    // MARK: - Find Next with the bar closed

    func testFindNextWithClosedBarSearchesTheLastQuery() {
        let (model, driver) = makeModel()
        model.query = "tram"
        model.next()
        model.previous()
        XCTAssertFalse(model.isOpen, "⌘G does not open the bar")
        XCTAssertEqual(driver.actions, [.next, .previous])
    }

    func testFindNextWithClosedBarAndNoQueryDoesNothing() {
        let (model, driver) = makeModel()
        model.next()
        XCTAssertTrue(driver.actions.isEmpty)
    }

    func testFindNextWithClosedBarFallsBackToTheFindPasteboard() {
        let (model, driver) = makeModel()
        pasteboard.clearContents()
        pasteboard.setString("Porto", forType: .string)
        model.next()
        XCTAssertEqual(model.query, "Porto")
        XCTAssertEqual(driver.actions, [.next])
    }

    func testOpeningAnEmptyBarAdoptsTheFindPasteboardButKeepsATypedQuery() {
        let (model, _) = makeModel()
        pasteboard.clearContents()
        pasteboard.setString("Porto", forType: .string)
        model.open(replace: false)
        XCTAssertEqual(model.query, "Porto")

        let (typed, _) = makeModel()
        typed.query = "tram"
        typed.open(replace: false)
        XCTAssertEqual(typed.query, "tram")
    }

    func testUseSelectionWritesTheFindPasteboard() {
        let (model, driver) = makeModel()
        driver.selection = "Foz"
        model.useSelection()
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.query, "Foz")
        XCTAssertEqual(pasteboard.string(forType: .string), "Foz")
        XCTAssertEqual(driver.actions, [.useSelection])
    }

    func testShiftReturnGoesBack() {
        let (model, driver) = makeModel()
        model.open(replace: false)
        model.query = "tram"
        model.submitQuery(shift: false)
        model.submitQuery(shift: true)
        XCTAssertEqual(driver.actions, [.next, .previous])
    }

    // MARK: - Replace while Ignore Markdown Formatting is on

    func testReplaceIsDisabledWithAReasonWhileIgnoringFormatting() {
        let (model, driver) = makeModel()
        model.open(replace: true)
        model.report(count: 2, index: 1, invalidRegex: false)
        XCTAssertTrue(model.canReplace)
        XCTAssertNil(model.replaceDisabledReason)

        model.options.ignoreFormatting = true
        XCTAssertFalse(model.canReplace)
        XCTAssertEqual(model.replaceDisabledReason, SearchModel.replaceUnavailableReason)
        model.replaceCurrent()
        model.replaceAll()
        XCTAssertTrue(driver.actions.isEmpty, "the menu path is blocked too, not only the buttons")
    }

    func testReplaceNeedsAMatch() {
        let (model, _) = makeModel()
        model.open(replace: true)
        model.report(count: 0, index: 0, invalidRegex: false)
        XCTAssertFalse(model.canReplace)
        XCTAssertFalse(model.canReplaceAll)
    }

    func testReplaceNeedsACurrentMatchButAllDoesNot() {
        // Wrap Around off, caret behind the last match: "3 matches" and
        // no current one. Replace has nothing to swap; All still works.
        let (model, _) = makeModel()
        model.open(replace: true)
        model.report(count: 3, index: 0, invalidRegex: false)
        XCTAssertFalse(model.canReplace)
        XCTAssertTrue(model.canReplaceAll)
        model.report(count: 3, index: 2, invalidRegex: false)
        XCTAssertTrue(model.canReplace)
    }

    // MARK: - Persistence and sharing

    func testDefaultsWithNothingStored() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.options.caseSensitive, "Ignore Case on")
        XCTAssertTrue(model.options.wrapAround)
        XCTAssertEqual(model.options.matchStyle, .contains)
        XCTAssertFalse(model.options.regex)
        XCTAssertFalse(model.options.ignoreFormatting)
    }

    /// The status beside the field is also the field's accessibility value
    /// and the VoiceOver announcement, so all three read the same.
    func testStatusTextFollowsTheReportedResults() {
        let (model, _) = makeModel()
        XCTAssertNil(model.statusText, "nothing to say for an empty query")
        model.query = "a"
        model.report(count: 0, index: 0, invalidRegex: false)
        XCTAssertEqual(model.statusText, "No matches")
        model.report(count: 1, index: 0, invalidRegex: false)
        XCTAssertEqual(model.statusText, "1 match")
        model.report(count: 12, index: 0, invalidRegex: false)
        XCTAssertEqual(model.statusText, "12 matches")
        model.report(count: 12, index: 3, invalidRegex: false)
        XCTAssertEqual(model.statusText, "3 of 12")
        model.report(count: 0, index: 0, invalidRegex: true)
        XCTAssertEqual(model.statusText, "Invalid")
    }

    func testOptionsPersistForTheNextWindow() {
        let (model, _) = makeModel()
        model.options.caseSensitive = true
        model.options.wrapAround = false
        model.options.matchStyle = .startsWith
        model.options.regex = true
        model.options.ignoreFormatting = true

        let (later, _) = makeModel()
        XCTAssertEqual(later.options, model.options)
        XCTAssertEqual(defaults.bool(forKey: SearchPreferences.ignoreCaseKey), false)
        XCTAssertEqual(defaults.string(forKey: SearchPreferences.matchStyleKey), "startsWith")
    }

    func testOptionChangeAppliesToOtherOpenWindows() {
        let (a, _) = makeModel()
        let (b, driverB) = makeModel()
        a.options.matchStyle = .wholeWord
        XCTAssertEqual(b.options.matchStyle, .wholeWord)
        XCTAssertEqual(driverB.parameterChanges, 1, "the other window re-runs its search")
    }

    func testAnUnknownStoredMatchStyleFallsBackToContains() {
        defaults.set("bogus", forKey: SearchPreferences.matchStyleKey)
        let (model, _) = makeModel()
        XCTAssertEqual(model.options.matchStyle, .contains)
    }
}

/// The real coordinator behind the bar (pattern: `EditorBridgeTests`):
/// navigation with and without Wrap Around, ⌘G with the bar closed, and
/// Replace All as one undo step.
@MainActor
final class SearchCoordinatorTests: XCTestCase {

    @MainActor
    private final class UndoProvider: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private var undoProvider: UndoProvider?
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    /// Kept alive: the model's driver reference is weak.
    private var coordinator: MarkdownTextView.Coordinator?

    override func setUp() async throws {
        defaults = makeTestDefaults("FindCoordinator")
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        coordinator = nil
    }

    private func makeEditor(_ text: String) -> (SearchModel, PicaMDTextView) {
        var binding = text
        let view = MarkdownTextView(text: Binding(get: { binding }, set: { binding = $0 }),
                                    jumpToken: .constant(nil))
        let coord = view.makeCoordinator()
        let textView = PicaMDTextView()
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let provider = UndoProvider()
        undoProvider = provider
        textView.delegate = provider
        coord.textView = textView
        coordinator = coord
        let model = SearchModel(defaults: defaults, notificationCenter: NotificationCenter(),
                                findPasteboard: pasteboard)
        coord.attachSearch(model)
        return (model, textView)
    }

    private func selected(_ tv: NSTextView) -> String {
        (tv.string as NSString).substring(with: tv.selectedRange())
    }

    private let doc = "tram one\ntram two\ntram three"

    func testNavigationWrapsAtBothEndsWhenWrapAroundIsOn() {
        let (model, tv) = makeEditor(doc)
        model.open(replace: false)
        model.query = "tram"
        model.next()            // flush lands on 1, the step on 2
        XCTAssertEqual(model.currentIndex, 2)
        model.next()
        model.next()
        XCTAssertEqual(model.currentIndex, 1, "past the last match wraps to the first")
        XCTAssertEqual(tv.selectedRange().location, 0)
        model.previous()
        XCTAssertEqual(model.currentIndex, 3, "before the first wraps to the last")
    }

    func testNavigationStopsAtBothEndsWhenWrapAroundIsOff() {
        let (model, tv) = makeEditor(doc)
        model.options.wrapAround = false
        model.open(replace: false)
        model.query = "tram"
        model.next()
        model.next()
        XCTAssertEqual(model.currentIndex, 3)
        model.next()
        XCTAssertEqual(model.currentIndex, 3, "stays on the last match")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 4))
        model.previous(); model.previous()
        XCTAssertEqual(model.currentIndex, 1)
        model.previous()
        XCTAssertEqual(model.currentIndex, 1, "stays on the first match")
    }

    func testWrapAroundOffDoesNotJumpBackFromBehindTheLastMatch() {
        // The caret sits after every match: with Wrap Around off there is
        // no current match, and ⌘G must not wrap to the first one.
        let (model, tv) = makeEditor(doc)
        model.options.wrapAround = false
        tv.setSelectedRange(NSRange(location: (doc as NSString).length, length: 0))
        model.open(replace: false)
        model.query = "tram"
        model.next()
        XCTAssertEqual(model.resultCount, 3)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(tv.selectedRange().location, (doc as NSString).length)
        model.previous()
        XCTAssertEqual(model.currentIndex, 3, "⇧⌘G takes the last match before the caret")
    }

    func testFindNextWithTheBarClosedSelectsTheNextMatch() {
        let (model, tv) = makeEditor(doc)
        model.query = "tram"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        model.next()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 9, length: 4))
        model.next()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 4))
        model.next()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 4), "wraps")
        model.previous()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 4))
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(tv.searchHighlightState.matches.isEmpty, "no highlights while the bar is closed")
    }

    func testFindNextWithTheBarClosedStopsWithoutWrapAround() {
        let (model, tv) = makeEditor(doc)
        model.options.wrapAround = false
        model.query = "tram"
        tv.setSelectedRange(NSRange(location: 18, length: 4))
        model.next()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 4))
    }

    func testFindNextWithTheBarClosedOpensFoldedFrontMatter() {
        let src = "---\ntitle: Needle\n---\nBody needle"
        let (model, tv) = makeEditor(src)
        model.options.caseSensitive = true
        model.query = "Needle"
        tv.setSelectedRange(NSRange(location: 22, length: 0))
        model.previous()
        let selection = tv.selectedRange()
        XCTAssertEqual(selection, NSRange(location: 11, length: 6))
        XCTAssertFalse(FrontmatterFold.isFolded(selection: selection, block: NSRange(location: 0, length: 22),
                                                in: src as NSString),
                       "a selection inside the block unfolds it")
    }

    func testCurrentMatchInsideFrontMatterIsRevealed() {
        let src = "---\ntitle: Needle\n---\nBody"
        let (model, tv) = makeEditor(src)
        tv.setSelectedRange(NSRange(location: 22, length: 0))
        model.open(replace: false)
        model.query = "needle"
        model.next()
        XCTAssertEqual(tv.searchHighlightState.current, NSRange(location: 11, length: 6))
        XCTAssertEqual(coordinator?.highlighter.searchMatchToReveal, NSRange(location: 11, length: 6),
                       "the highlighter keeps the block open for it")
    }

    func testMatchesInsideFoldedFrontMatterAreNotPainted() {
        // The folded block's glyphs are 0.01 pt and clear: a highlight
        // there would be a yellow sliver over the meta line. The match
        // still counts, and becoming current opens the block.
        let src = "---\ntitle: Needle\n---\nBody needle"
        var binding = src
        let view = MarkdownTextView(text: Binding(get: { binding }, set: { binding = $0 }),
                                    jumpToken: .constant(nil))
        let coord = view.makeCoordinator()
        let (scrollView, tv) = PicaMDTextView.makeScrollable()
        tv.string = src
        tv.setSelectedRange(NSRange(location: 26, length: 0))
        coord.textView = tv
        coord.scrollView = scrollView
        coordinator = coord
        let model = SearchModel(defaults: defaults, notificationCenter: NotificationCenter(),
                                findPasteboard: pasteboard)
        coord.attachSearch(model)
        coord.applyHighlightingNow()
        XCTAssertEqual(tv.frontmatterMetaLine?.block, NSRange(location: 0, length: 22))

        model.options.wrapAround = false
        model.open(replace: false)
        model.query = "needle"
        model.next()        // flush lands on the body match; no wrap, so it stays
        XCTAssertEqual(model.resultCount, 2)
        XCTAssertEqual(tv.searchHighlightState.current, NSRange(location: 27, length: 6))
        coord.applyHighlightingNow()
        XCTAssertEqual(tv.drawnSearchMatches, [NSRange(location: 27, length: 6)])

        model.previous()    // onto the YAML match: the block opens
        coord.applyHighlightingNow()
        XCTAssertNil(tv.frontmatterMetaLine)
        XCTAssertEqual(tv.drawnSearchMatches.count, 2)
    }

    func testHighlightsAreSystemYellowNotTheAccent() {
        let (model, tv) = makeEditor(doc)
        model.open(replace: false)
        model.query = "tram"
        model.next()
        XCTAssertEqual(tv.searchHighlightState.matches.count, 3)
        XCTAssertEqual(tv.currentSearchHighlightColor, NSColor.systemYellow)
        XCTAssertEqual(tv.searchHighlightColor, NSColor.systemYellow.withAlphaComponent(0.42))
    }

    func testReplaceAllIsOneUndoStep() throws {
        let (model, tv) = makeEditor(doc)
        model.open(replace: true)
        model.query = "tram"
        model.replaceText = "bus"
        model.replaceAll()
        XCTAssertEqual(tv.string, "bus one\nbus two\nbus three")
        let undo = try XCTUnwrap(undoProvider?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Replace All")
        undo.undo()
        XCTAssertEqual(tv.string, doc)
    }

    func testUseSelectionSearchesTheSelection() {
        let (model, tv) = makeEditor(doc)
        tv.setSelectedRange(NSRange(location: 9, length: 4))
        model.useSelection()
        XCTAssertEqual(model.query, "tram")
        XCTAssertEqual(model.currentIndex, 2, "lands on the selected occurrence")
        XCTAssertEqual(pasteboard.string(forType: .string), "tram")
    }

    func testSpaceInTheQueryMatchesAcrossASoftLineBreak() {
        let (model, tv) = makeEditor("Take the tram\nout to Foz.\n\nThe tram\n\nout")
        model.open(replace: false)
        model.query = "tram out"
        model.next()
        XCTAssertEqual(model.resultCount, 1, "a blank line is a paragraph break, not a space")
        XCTAssertEqual(selected(tv), "tram\nout")
    }
}
