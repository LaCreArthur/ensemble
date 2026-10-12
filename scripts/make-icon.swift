// Draws Resources/AppIcon.icns: the menu bar symbol, white, on a blue squircle (macOS icon grid).
// Usage: swift scripts/make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(starting: NSColor(red: 0.30, green: 0.56, blue: 1.0, alpha: 1), ending: NSColor(red: 0.20, green: 0.27, blue: 0.85, alpha: 1))!
        .draw(in: shape, angle: -90)
    // Monochrome, painted white over its own shape, so the speaker cones stay cut out.
    let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .medium)
    let symbol = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let white = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let size = symbol.size
    white.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try draw(points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try draw(1024).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon-1024.png"))
print("Wrote Resources/AppIcon.icns")
