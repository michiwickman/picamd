import XCTest
import SwiftUI
import AppKit
@testable import PicaMD

/// The macOS 27 editor window: word count, inspector strings, outline
/// rows, Share, scroll positions under the toolbar, window size.
@MainActor
final class WindowLayoutTests: XCTestCase {

    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    // MARK: - Word count of the visible text

    func testWordCountIgnoresMarkdownMarkers() {
        XCTAssertEqual(TextStats("# Trip to **Porto**\n").words, 3)
        XCTAssertEqual(TextStats("> A *quoted* `line`\n").words, 3)
        XCTAssertEqual(TextStats("[São Bento](https://example.com/sao-bento) is near\n").words, 4)
    }

    func testWordCountSkipsFrontMatterCodeAndMath() {
        XCTAssertEqual(TextStats("---\ntitle: Trip\ntags: [travel, portugal]\n---\nHello world\n").words, 2)
        XCTAssertEqual(TextStats("Before\n```swift\nlet x = compute(1, 2)\n```\nAfter\n").words, 2)
        XCTAssertEqual(TextStats("$$\nx^2 + y^2\n$$\nText\n").words, 1)
    }

    func testWordCountSkipsListMarkersTablePipesAndRules() {
        XCTAssertEqual(TextStats("- [x] Passport\n- [ ] Rain jacket\n1. [ ] Shoes\n").words, 4)
        XCTAssertEqual(TextStats("| Day | Where |\n|---|---|\n| Thu | Ribeira |\n").words, 4)
        XCTAssertEqual(TextStats("One\n\n---\n\n* two — three\n").words, 3)
        XCTAssertEqual(TextStats("1. Buy milk\n2) Eat\n10. Sleep\n").words, 4, "list numbers are not words")
        XCTAssertEqual(TextStats("> 1. Quoted item\n").words, 2)
        XCTAssertEqual(TextStats("Porto[^1] is old.\n\n[^1]: Founded early.\n").words, 5,
                       "footnote labels are not words")
        XCTAssertEqual(TextStats("In 1999 we had 2 cats.\n").words, 6, "numbers inside a line still count")
    }

    func testCharactersAndLinesDescribeTheFile() {
        let stats = TextStats("# Hi\n\nTwo words\n")
        XCTAssertEqual(stats.characters, 16)
        XCTAssertEqual(stats.lines, 4)
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(TextStats(""), TextStats())
    }

    func testStatsPassStopsWhenCancelled() {
        XCTAssertNil(TextStats.compute("Some words here\n", isCancelled: { true }))
        var checks = 0
        XCTAssertNil(TextStats.compute("Some words here\n", isCancelled: { checks += 1; return checks > 3 }),
                     "checked again between the passes, not only at the start")
        XCTAssertEqual(TextStats.compute("Some words here\n", isCancelled: { false }), TextStats("Some words here\n"))
    }

    // MARK: - Inspector and word count strings

    func testNumbersUseThousandsSeparators() {
        XCTAssertEqual(InspectorFormat.number(2318, locale: us), "2,318")
        XCTAssertEqual(InspectorFormat.number(2318, locale: de), "2.318")
        XCTAssertEqual(InspectorFormat.number(7, locale: us), "7")
    }

    func testWordCountLabel() {
        XCTAssertEqual(InspectorFormat.wordCount(412, locale: us), "412 words")
        XCTAssertEqual(InspectorFormat.wordCount(1, locale: us), "1 word")
        XCTAssertEqual(InspectorFormat.wordCount(0, locale: us), "0 words")
        XCTAssertEqual(InspectorFormat.wordCount(12_045, locale: us), "12,045 words")
    }

    func testReadingTimeRoundsAt200WordsPerMinute() {
        XCTAssertEqual(InspectorFormat.readingTime(words: 412, locale: us), "2 min")
        XCTAssertEqual(InspectorFormat.readingTime(words: 1, locale: us), "1 min")
        XCTAssertEqual(InspectorFormat.readingTime(words: 499, locale: us), "2 min")
        XCTAssertEqual(InspectorFormat.readingTime(words: 500, locale: us), "3 min")
        XCTAssertEqual(InspectorFormat.readingTime(words: 240_000, locale: us), "1,200 min")
        XCTAssertEqual(InspectorFormat.readingTime(words: 0, locale: us), "—")
    }

    func testWhereShowsTheLastTwoFolders() {
        let url = URL(fileURLWithPath: "/Users/m/Documents/Travel/Trip to Porto.md")
        XCTAssertEqual(InspectorFormat.location(of: url), "Documents ▸ Travel")
        XCTAssertEqual(InspectorFormat.location(of: URL(fileURLWithPath: "/Volumes/Notes.md")), "Volumes")
        XCTAssertEqual(InspectorFormat.location(of: URL(fileURLWithPath: "/Notes.md")), "/")
        XCTAssertEqual(InspectorFormat.location(of: nil), "—")
    }

    func testModifiedIsRelativeToToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let gb = Locale(identifier: "en_GB")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 20)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 5)))
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 20)))

        XCTAssertEqual(InspectorFormat.modified(today, now: now, calendar: calendar, locale: gb), "Today, 14:20")
        let yesterdayText = InspectorFormat.modified(yesterday, now: now, calendar: calendar, locale: gb)
        XCTAssertTrue(yesterdayText.hasPrefix("Yesterday, ") && yesterdayText.hasSuffix("9:05"), yesterdayText)
        let olderText = InspectorFormat.modified(older, now: now, calendar: calendar, locale: gb)
        XCTAssertTrue(olderText.contains("3") && olderText.contains("2026"), olderText)
        XCTAssertTrue(olderText.hasSuffix(", 14:20"), olderText)
        XCTAssertEqual(InspectorFormat.modified(nil), "—")
    }

    func testFormatFromExtension() {
        XCTAssertEqual(InspectorFormat.format(of: URL(fileURLWithPath: "/a/b.md")), "Markdown")
        XCTAssertEqual(InspectorFormat.format(of: URL(fileURLWithPath: "/a/b.MARKDOWN")), "Markdown")
        XCTAssertEqual(InspectorFormat.format(of: URL(fileURLWithPath: "/a/b.txt")), "Plain Text")
        XCTAssertEqual(InspectorFormat.format(of: nil), "—")
    }

    // MARK: - Outline rows

    func testOutlineIndentGrowsBy14PerLevel() {
        XCTAssertEqual(OutlineSidebar.indent(forLevel: 1), 10)
        XCTAssertEqual(OutlineSidebar.indent(forLevel: 2), 24)
        XCTAssertEqual(OutlineSidebar.indent(forLevel: 3), 38)
        XCTAssertEqual(OutlineSidebar.indent(forLevel: 6), 80)
        XCTAssertEqual(OutlineSidebar.indent(forLevel: 0), 10, "malformed level clamps to H1")
    }

    // MARK: - Reduce Motion

    func testColumnsDoNotSlideWithReduceMotion() {
        XCTAssertNil(PanelMotion.toggle(.easeInOut(duration: 0.2), reduceMotion: true))
        XCTAssertEqual(PanelMotion.toggle(.easeInOut(duration: 0.2), reduceMotion: false),
                       .easeInOut(duration: 0.2))
    }

    // MARK: - Share

    func testSharingASavedDocumentSharesItsFile() throws {
        let dir = try makeShareTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = dir.appendingPathComponent("Trip.md")
        try Data("# Trip\n".utf8).write(to: saved)
        let item = MarkdownShareItem(savedURL: saved, text: "# Trip\n", untitledName: "x")
        XCTAssertEqual(try item.fileURL(temporaryDirectory: dir), saved)
        XCTAssertEqual(item.displayName, "Trip.md")
    }

    /// A file PicaMD keeps in its own encoding holds what the editor shows
    /// although its bytes are not the UTF-8 of the text.
    func testSharingAnUneditedNonUTF8DocumentSharesItsFile() throws {
        let dir = try makeShareTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp1252 = dir.appendingPathComponent("Gruss.md")
        try Data(Array("Gr".utf8) + [0xFC, 0xDF] + Array("e\n".utf8)).write(to: cp1252)
        XCTAssertEqual(try MarkdownShareItem(savedURL: cp1252, text: "Grüße\n", untitledName: "x")
            .fileURL(temporaryDirectory: dir), cp1252)

        let bom = dir.appendingPathComponent("Bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("# Trip\n".utf8)).write(to: bom)
        XCTAssertEqual(try MarkdownShareItem(savedURL: bom, text: "# Trip\n", untitledName: "x")
            .fileURL(temporaryDirectory: dir), bom)
    }

    func testSharingAnEditedDocumentSharesTheEditorText() throws {
        let dir = try makeShareTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = dir.appendingPathComponent("Trip.md")
        try Data("# Trip\n".utf8).write(to: saved)
        let item = MarkdownShareItem(savedURL: saved, text: "# Trip\n\nNot saved yet\n", untitledName: "x")

        let shared = try item.fileURL(temporaryDirectory: dir)
        XCTAssertNotEqual(shared, saved, "the file on disk is behind the editor")
        XCTAssertEqual(shared.lastPathComponent, "Trip.md")
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "# Trip\n\nNot saved yet\n")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "# Trip\n", "the saved file is untouched")
    }

    func testShareRemovesCopiesOlderThanAnHour() throws {
        let dir = try makeShareTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = MarkdownShareItem(savedURL: nil, text: "Text\n", untitledName: "Note")
        let now = Date()
        let old = try item.fileURL(temporaryDirectory: dir, now: now).deletingLastPathComponent()
        let recent = try item.fileURL(temporaryDirectory: dir, now: now).deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 60 * 60)],
                                              ofItemAtPath: old.path)

        let newest = try item.fileURL(temporaryDirectory: dir, now: now).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    private func makeShareTestDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDShareTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSharingAnUntitledDocumentWritesATemporaryMarkdownFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDShareTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = MarkdownShareItem(savedURL: nil, text: "# Trip\n\nÜber Porto\n", untitledName: "Trip/Porto: 2026")

        let first = try item.fileURL(temporaryDirectory: dir)
        XCTAssertEqual(first.lastPathComponent, "Trip-Porto- 2026.md")
        XCTAssertEqual(first.pathExtension, "md")
        XCTAssertTrue(first.path.hasPrefix(dir.path))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Trip\n\nÜber Porto\n")

        let second = try item.fileURL(temporaryDirectory: dir)
        XCTAssertNotEqual(first, second, "each share gets its own folder")
    }

    func testUntitledShareNameIsSanitised() {
        XCTAssertEqual(MarkdownShareItem.sanitized("  "), "Untitled")
        XCTAssertEqual(MarkdownShareItem.sanitized("..hidden"), "hidden")
        XCTAssertEqual(MarkdownShareItem.sanitized("a/b:c"), "a-b-c")
    }

    func testUntitledShareNameFitsTheFileSystem() throws {
        let long = String(repeating: "Überlange Überschrift 🧭 ", count: 30)
        let name = MarkdownShareItem.sanitized(long)
        XCTAssertLessThanOrEqual(name.utf8.count, MarkdownShareItem.maxNameBytes)
        XCTAssertTrue(long.hasPrefix(name), "cut at a character boundary")

        let dir = try makeShareTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MarkdownShareItem(savedURL: nil, text: "x", untitledName: long).fileURL(temporaryDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Scroll positions under the toolbar

    func testJumpWithoutInsetsMatchesTheOldFormula() {
        // y = min(maxY, max(0, lineTop − 24)), maxY = docHeight − viewport
        XCTAssertEqual(EditorScrollMath.jumpOrigin(lineTop: 500, documentHeight: 2000, viewportHeight: 600), 476)
        XCTAssertEqual(EditorScrollMath.jumpOrigin(lineTop: 10, documentHeight: 2000, viewportHeight: 600), 0)
        XCTAssertEqual(EditorScrollMath.jumpOrigin(lineTop: 1990, documentHeight: 2000, viewportHeight: 600), 1400)
        XCTAssertEqual(EditorScrollMath.jumpOrigin(lineTop: 300, documentHeight: 400, viewportHeight: 600), 0,
                       "short document never scrolls")
    }

    func testJumpLandsBelowAnOverlappingToolbar() {
        // 52 pt toolbar over the scroll view: the visible area starts at
        // origin + 52, the heading must sit 24 pt below that.
        let origin = EditorScrollMath.jumpOrigin(lineTop: 500, documentHeight: 2000, viewportHeight: 600,
                                                 insetTop: 52)
        XCTAssertEqual(origin + 52 + EditorScrollMath.jumpTopMargin, 500)
        XCTAssertEqual(EditorScrollMath.jumpOrigin(lineTop: 0, documentHeight: 2000, viewportHeight: 600,
                                                   insetTop: 52), -52, "first line stays below the toolbar")
    }

    func testTypewriterCentresInTheUnobscuredViewport() {
        XCTAssertEqual(EditorScrollMath.centeredOrigin(lineMidY: 1000, documentHeight: 3000, viewportHeight: 600), 700)
        XCTAssertEqual(EditorScrollMath.centeredOrigin(lineMidY: 100, documentHeight: 3000, viewportHeight: 600), 0)

        let origin = EditorScrollMath.centeredOrigin(lineMidY: 1000, documentHeight: 3000, viewportHeight: 600,
                                                     insetTop: 52, insetBottom: 0)
        let visibleMid = origin + 52 + (600 - 52) / 2
        XCTAssertEqual(visibleMid, 1000)
        XCTAssertEqual(EditorScrollMath.centeredOrigin(lineMidY: 10, documentHeight: 3000, viewportHeight: 600,
                                                       insetTop: 52), -52)
    }

    // MARK: - Columns and window

    func testOutlineFlagMapsToColumnVisibility() {
        XCTAssertEqual(ContentView.columnVisibility(showOutline: true), .all)
        XCTAssertEqual(ContentView.columnVisibility(showOutline: false), .detailOnly)
        XCTAssertFalse(ContentView.showsOutline(.detailOnly))
        XCTAssertTrue(ContentView.showsOutline(.all))
        XCTAssertTrue(ContentView.showsOutline(.doubleColumn))
        XCTAssertTrue(ContentView.showsOutline(.automatic))
    }

    func testMinimumWidthFitsOutlineEditorAndInspector() {
        XCTAssertGreaterThanOrEqual(ContentView.minimumWindowWidth, 200 + 360 + 260)
    }
}
