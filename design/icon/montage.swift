import AppKit

// Lays PNGs side by side on a solid background, for the preview image.
// Usage: swift montage.swift out.png bgHex gap size in1.png [in2.png ...]
let a = CommandLine.arguments
guard a.count >= 6, let gap = Double(a[3]), let side = Double(a[4]) else {
    FileHandle.standardError.write(Data("usage: montage out.png bgHex gap size in.png...\n".utf8))
    exit(2)
}
let images = a.dropFirst(5).map { path -> NSImage in
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: path)) else { fatalError("cannot read \(path)") }
    return img
}
let s = CGFloat(side), g = CGFloat(gap)
let width = g + CGFloat(images.count) * (s + g), height = s + 2 * g
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
ctx.imageInterpolation = .high
NSGraphicsContext.current = ctx
var v: UInt64 = 0
Scanner(string: a[2]).scanHexInt64(&v)
NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
        blue: CGFloat(v & 255) / 255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
for (i, img) in images.enumerated() {
    img.draw(in: NSRect(x: g + CGFloat(i) * (s + g), y: g, width: s, height: s),
             from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
