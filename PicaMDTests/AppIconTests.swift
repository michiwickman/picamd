import AppKit
import XCTest

/// Guards the shipped app icon (PicaMD/AppIcon.icon, "Caret line").
///
/// The tests run inside the host app, so `NSImage(named: "AppIcon")`
/// resolves against the app's compiled Assets.car, and
/// `NSApp.applicationIconImage` is the image the welcome window shows.
/// They check that the Icon Composer icon still yields a named image
/// after the old `AppIcon.appiconset` was removed, and that it is the
/// Caret line icon (near-black ground, blue "#" and caret) rather than
/// the old navy "M↓" icon.
@MainActor
final class AppIconTests: XCTestCase {

    func testAppIconResolvesForWelcomeLogo() {
        XCTAssertNotNil(NSImage(named: "AppIcon"),
                        "the compiled asset catalog has no AppIcon")
    }

    func testInfoPlistNamesTheIcon() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(info?["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(info?["CFBundleIconFile"] as? String, "AppIcon")
    }

    func testIconIsTheCaretLineDesign() throws {
        try assertCaretLine(XCTUnwrap(NSImage(named: "AppIcon")))
    }

    /// The welcome window draws `NSApp.applicationIconImage`.
    func testApplicationIconImageIsTheCaretLineDesign() {
        assertCaretLine(NSApp.applicationIconImage)
    }

    private func assertCaretLine(_ icon: NSImage) {
        let rep = render(icon, side: 256)

        // Ground above the first and below the last paper line. The old
        // icon is navy there (#2B5485 / #1C3A62), the new one a neutral
        // near-black gradient (#232321 / #0D0D0B in the system render).
        for (x, y) in [(0.5, 0.20), (0.5, 0.80)] {
            let c = color(rep, x, y)
            XCTAssertLessThan(max(c.r, c.g, c.b), 0.25, "ground at \(x),\(y) not dark: \(c)")
            XCTAssertLessThan(abs(c.b - c.r), 0.06, "ground at \(x),\(y) not neutral: \(c)")
        }
        // Left bar of the "#" and the caret are blue. In the old icon
        // these points are the white M stroke and navy ground.
        for (x, y) in [(0.25, 0.45), (0.70, 0.50)] {
            let c = color(rep, x, y)
            XCTAssertGreaterThan(c.b - c.r, 0.15, "markup at \(x),\(y) not blue: \(c)")
        }
    }

    // MARK: - Helpers

    private func render(_ image: NSImage, side: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Light appearance so the result does not depend on the test
        // machine's system appearance.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }

    /// Colour at fractional position, y measured from the top.
    private func color(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double)
        -> (r: Double, g: Double, b: Double) {
        let side = Double(rep.pixelsWide)
        let c = rep.colorAt(x: Int(x * side), y: Int(y * side))!.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}
