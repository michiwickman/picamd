import XCTest
import AppKit
@testable import PicaMD

/// The document window's three columns in a real `DocumentGroup` window:
/// with the outline and the inspector both open, every column has to fit
/// inside the window at the default and at the minimum width.
@MainActor
final class WindowColumnsTests: XCTestCase {

    private var hosted: HostedDocument?

    func testOutlineEditorAndInspectorFitTheDefaultWindow() throws {
        let window = try openWindow(width: 1100)
        defer { hosted?.close() }
        try openInspector(in: window)
        try assertColumnsFit(in: window, editorAtLeast: 500)
    }

    func testOutlineEditorAndInspectorFitTheMinimumWindow() throws {
        let window = try openWindow(width: ContentView.minimumWindowWidth)
        defer { hosted?.close() }
        try openInspector(in: window)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)

        // Narrowing an open window further stops at the minimum.
        window.setFrame(NSRect(origin: window.frame.origin,
                               size: NSSize(width: 700, height: 750)), display: true)
        HostedDocument.spin(0.5)
        XCTAssertEqual(window.frame.width, ContentView.minimumWindowWidth)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    /// Dragging both dividers outward as far as they go stops where the
    /// editor keeps its floor. At the static maxima an outline dragged
    /// to 300 pt left the editor 220 pt, and the constraint passes never
    /// settled.
    func testDraggedColumnsLeaveTheEditorItsFloor() throws {
        let window = try openWindow(width: ContentView.minimumWindowWidth)
        defer { hosted?.close() }
        try openInspector(in: window)
        try widenColumns(in: window)
    }

    /// Columns widened in a large window give way when the window is
    /// narrowed to its minimum, the inspector first, instead of
    /// squeezing the editor. At the static maxima the content stopped
    /// shrinking at 1060 pt and overflowed the narrower window.
    func testNarrowingTheWindowShrinksWideColumns() throws {
        let window = try openWindow(width: 1100)
        defer { hosted?.close() }
        try openInspector(in: window)
        try widenColumns(in: window)
        try narrowStepwise(window)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    /// The same in one jump (a window tiled to half a screen).
    func testJumpingToTheMinimumWidthShrinksWideColumns() throws {
        let window = try openWindow(width: 1100)
        defer { hosted?.close() }
        try openInspector(in: window)
        try widenColumns(in: window)
        window.setFrame(NSRect(origin: window.frame.origin,
                               size: NSSize(width: ContentView.minimumWindowWidth, height: 750)), display: true)
        HostedDocument.spin(1.0)
        XCTAssertEqual(window.frame.width, ContentView.minimumWindowWidth)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    func testNarrowingTheWindowWithDefaultColumns() throws {
        let window = try openWindow(width: 1100)
        defer { hosted?.close() }
        try openInspector(in: window)
        try narrowStepwise(window)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    /// The outline widened while the inspector is closed gives way when
    /// the inspector opens in the minimum window.
    func testInspectorOpeningNextToAWideOutline() throws {
        let window = try openWindow(width: ContentView.minimumWindowWidth)
        defer { hosted?.close() }
        let (outline, _) = try splitViews(in: window)
        outline.setPosition(WindowColumnLimits.outline.upperBound, ofDividerAt: 0)
        HostedDocument.spin(0.5)
        try openInspector(in: window)
        HostedDocument.spin(0.5)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    func testColumnMaximaLeaveTheEditorItsFloor() {
        func limits(_ width: CGFloat, outline: CGFloat, inspector: Bool = true) -> WindowColumnLimits {
            WindowColumnLimits(windowWidth: width, editorFrame: CGRect(x: outline, y: 0, width: 300, height: 700),
                               inspectorShown: inspector)
        }
        let unmeasured = WindowColumnLimits(windowWidth: nil, editorFrame: .zero, inspectorShown: true)
        XCTAssertEqual([unmeasured.outlineMax, unmeasured.inspectorMax], [320, 360])
        // The default window: both columns may grow fully.
        XCTAssertEqual([limits(1100, outline: 248).outlineMax, limits(1100, outline: 248).inspectorMax], [320, 360])
        // 1000 pt with the outline at 320: the inspector stops at 320.
        XCTAssertEqual([limits(1000, outline: 320).outlineMax, limits(1000, outline: 320).inspectorMax], [320, 320])
        // 900 pt: the outline only keeps room for an inspector at 260.
        XCTAssertEqual([limits(900, outline: 300).outlineMax, limits(900, outline: 300).inspectorMax], [280, 260])
        // The minimum window: both columns at their minimum.
        XCTAssertEqual([limits(820, outline: 200).outlineMax, limits(820, outline: 200).inspectorMax], [200, 260])
        // Inspector closed: the outline may use the room it would take.
        XCTAssertEqual(limits(820, outline: 320, inspector: false).outlineMax, 320)
        // Outline hidden: the editor starts at the window's edge.
        XCTAssertEqual(limits(820, outline: 0).inspectorMax, 360)
    }

    // MARK: - Helpers

    /// Both dividers dragged outward as far as they go.
    private func widenColumns(in window: NSWindow) throws {
        let (outline, inspector) = try splitViews(in: window)
        outline.setPosition(WindowColumnLimits.outline.upperBound, ofDividerAt: 0)
        HostedDocument.spin(0.5)
        inspector.setPosition(window.frame.width - WindowColumnLimits.inspector.upperBound, ofDividerAt: 0)
        HostedDocument.spin(0.5)
        try assertColumnsFit(in: window, editorAtLeast: WindowColumnLimits.editorFloor)
    }

    /// Down to the minimum width in 10 pt steps, as a live resize does.
    private func narrowStepwise(_ window: NSWindow) throws {
        var width = window.frame.width
        while width > ContentView.minimumWindowWidth {
            width = max(width - 10, ContentView.minimumWindowWidth)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 750)),
                            display: true)
            HostedDocument.spin(0.03)
        }
        HostedDocument.spin(1.0)
        XCTAssertEqual(window.frame.width, ContentView.minimumWindowWidth)
    }

    /// The outline's split view (NavigationSplitView) and the one the
    /// inspector splits the detail column with.
    private func splitViews(in window: NSWindow) throws -> (outline: NSSplitView, inspector: NSSplitView) {
        let frame = try XCTUnwrap(window.contentView?.superview)
        let splits = Self.views(in: frame) { $0 is NSSplitView }.compactMap { $0 as? NSSplitView }
        let outline = try XCTUnwrap(splits.first {
            ($0.delegate as? NSSplitViewController)?.splitViewItems.first?.behavior == .sidebar
        }, "outline split view")
        let inspector = try XCTUnwrap(splits.first {
            ($0.delegate as? NSSplitViewController)?.splitViewItems.last?.behavior == .inspector
        }, "inspector split view")
        return (outline, inspector)
    }

    private func openWindow(width: CGFloat) throws -> NSWindow {
        let doc = try HostedDocument.untitled()
        hosted = doc
        let window = try XCTUnwrap(doc.textView.window)
        window.setFrame(NSRect(x: 80, y: 80, width: width, height: 750), display: true)
        HostedDocument.spin(0.4)
        XCTAssertEqual(window.frame.width, width)
        return window
    }

    /// Clicks the toolbar's Inspector button, the right-most toolbar item.
    /// The View menu item can't be used: its focused-scene binding only
    /// exists while the window is key, and the test host is not active.
    private func openInspector(in window: NSWindow) throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        let items = Self.views(in: frame) { "\(type(of: $0))".contains("ToolbarItemHostingView") }
        let button = try XCTUnwrap(items.max { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX })
        let rect = button.convert(button.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        HostedDocument.spin(1.0)
    }

    /// The outline, the editor and the inspector all lie inside the
    /// window, side by side, and the editor keeps `editorAtLeast` points.
    private func assertColumnsFit(in window: NSWindow, editorAtLeast minimum: CGFloat,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        let width = window.frame.width
        let columns = Self.views(in: frame) { "\(type(of: $0))" == "_NSSplitViewItemViewWrapper" }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { $0.convert($0.bounds, to: nil) }
        for column in columns {
            XCTAssertGreaterThanOrEqual(column.minX, 0, "column \(column) starts left of the window",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(column.maxX, width, "column \(column) ends right of the window",
                                     file: file, line: line)
        }
        // Sidebar at the left edge, inspector at the right edge.
        let sidebar = try XCTUnwrap(columns.first { $0.minX == 0 && $0.width < width / 2 },
                                    "outline column", file: file, line: line)
        let inspector = try XCTUnwrap(columns.first { $0.minX > 0 && $0.maxX == width },
                                      "inspector column is open", file: file, line: line)
        let editor = try XCTUnwrap(hosted?.textView.enclosingScrollView).convert(
            try XCTUnwrap(hosted?.textView.enclosingScrollView).bounds, to: nil)
        XCTAssertGreaterThanOrEqual(editor.minX, sidebar.maxX, "editor under the outline", file: file, line: line)
        XCTAssertLessThanOrEqual(editor.maxX, inspector.minX, "editor under the inspector", file: file, line: line)
        XCTAssertGreaterThanOrEqual(editor.width, minimum, file: file, line: line)
    }

    private static func views(in root: NSView, where match: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if match(view) { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}
