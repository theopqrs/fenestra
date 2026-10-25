// Generates the AppIcon.iconset used by build.sh: a gradient squircle with three stacked windows.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func drawIcon(size s: CGFloat) {
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let squircle = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.47, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.62, green: 0.30, blue: 0.95, alpha: 1))!.draw(in: squircle, angle: -70)

    let windows: [(x: CGFloat, y: CGFloat, alpha: CGFloat)] = [(0.38, 0.47, 0.35), (0.30, 0.38, 0.6), (0.22, 0.29, 1)]
    let windowSize = NSSize(width: s * 0.45, height: s * 0.31)
    for window in windows {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        shadow.set()
        NSColor.white.withAlphaComponent(window.alpha).setFill()
        NSBezierPath(roundedRect: NSRect(origin: NSPoint(x: s * window.x, y: s * window.y), size: windowSize),
                     xRadius: s * 0.035, yRadius: s * 0.035).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Traffic lights on the front window.
    let front = windows[2]
    let dot = s * 0.03
    let dotY = s * front.y + windowSize.height - s * 0.05
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        let x = s * (front.x + 0.035) + CGFloat(index) * dot * 1.6
        NSBezierPath(ovalIn: NSRect(x: x, y: dotY - dot / 2, width: dot, height: dot)).fill()
    }
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for variant in variants {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: variant.pixels, pixelsHigh: variant.pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(variant.pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(variant.name).png"))
}
