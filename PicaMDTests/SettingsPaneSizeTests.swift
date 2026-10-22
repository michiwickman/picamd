import XCTest
import SwiftUI
import AppKit
@testable import PicaMD

/// The Settings panes have fixed heights (the window only resizes to a
/// pane with an explicit height). Each form must fit its height, or the
/// pane shows a scroll bar; only the AI pane, with its presets list, is
/// allowed to scroll.
@MainActor
final class SettingsPaneSizeTests: XCTestCase {

    /// The panes in the app's Settings window, as the app opens it.
    func testPanesFitTheSettingsWindow() throws {
        let defaults = UserDefaults.standard
        let storedPane = defaults.object(forKey: SettingsPane.storageKey)
        defer { defaults.set(storedPane, forKey: SettingsPane.storageKey) }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
        }
        SettingsOpener.open(.general)
        HostedDocument.spin(until: { settingsWindow() != nil })
        let window = try XCTUnwrap(settingsWindow(), "Settings window")
        defer { window.close() }

        for pane in [SettingsPane.general, .appearance, .editor] {
            defaults.set(pane.rawValue, forKey: SettingsPane.storageKey)
            HostedDocument.spin(0.6)
            let form = try XCTUnwrap(Self.formScrollView(in: window), "\(pane) form")
            Self.assertFits(form, "\(pane)")
        }
    }

    /// Appearance is the one pane whose height depends on a setting.
    func testAppearanceFitsWithAndWithoutCustomColours() throws {
        let defaults = makeTestDefaults("SettingsPaneSize")
        let store = ThemeStore(defaults: defaults)
        store.setPalette(.white)

        for custom in [false, true] {
            if custom { store.selectCustomColors() }
            XCTAssertEqual(store.theme.useCustomColors, custom)
            let host = NSHostingView(rootView: SettingsView.content(of: .appearance, customColors: custom)
                .environmentObject(store))
            let size = SettingsPane.appearance.contentSize(customColors: custom)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            HostedDocument.spin(0.6)
            let form = try XCTUnwrap(Self.formScrollView(in: window), "appearance form, custom \(custom)")
            Self.assertFits(form, "appearance, custom colours \(custom)")
        }
    }

    // MARK: - Helpers

    /// The grouped form's scroll view: the largest visible one.
    private static func formScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.max { $0.frame.height < $1.frame.height }
    }

    private static func assertFits(_ scroll: NSScrollView, _ name: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let content = scroll.documentView?.frame.height ?? 0
        let visible = scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        XCTAssertGreaterThan(content, 0, name, file: file, line: line)
        XCTAssertLessThanOrEqual(content, visible,
                                 "\(name) scrolls: content \(content) pt, visible \(visible) pt",
                                 file: file, line: line)
    }
}
