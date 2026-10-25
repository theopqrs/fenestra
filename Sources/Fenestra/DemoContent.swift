import AppKit

/// Made-up windows and tabs for the README screenshots (`--demo-screenshot`), so that no real window
/// title or content ends up in them. Uses the icons of apps that are running.
enum DemoContent {
    private struct DemoWindow {
        let bundleID: String
        let title: String
        let size: CGSize
        let dark: Bool
        let accent: NSColor
        var spaceLabel: String? = nil
        var isMinimized = false
    }

    private static let windows = [
        DemoWindow(bundleID: "com.google.Chrome", title: "Fenestra — a real window switcher for macOS", size: CGSize(width: 1440, height: 900),
                   dark: false, accent: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1)),
        DemoWindow(bundleID: "com.apple.Terminal", title: "fenestra — zsh — 120×32", size: CGSize(width: 860, height: 540),
                   dark: true, accent: NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)),
        DemoWindow(bundleID: "com.tinyspeck.slackmacgap", title: "# design", size: CGSize(width: 1280, height: 800),
                   dark: false, accent: NSColor(srgbRed: 0.45, green: 0.22, blue: 0.55, alpha: 1), spaceLabel: "Bureau 2"),
        DemoWindow(bundleID: "com.apple.finder", title: "Projets", size: CGSize(width: 900, height: 560),
                   dark: false, accent: NSColor(srgbRed: 0.2, green: 0.55, blue: 0.95, alpha: 1)),
        DemoWindow(bundleID: "com.google.Chrome", title: "Rectangle — Move and resize windows", size: CGSize(width: 1440, height: 900),
                   dark: false, accent: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.2, alpha: 1)),
        DemoWindow(bundleID: "com.apple.Safari", title: "Apple Developer", size: CGSize(width: 1440, height: 900),
                   dark: true, accent: NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1), spaceLabel: "Plein écran"),
        DemoWindow(bundleID: "com.apple.Music", title: "Musique", size: CGSize(width: 1100, height: 700),
                   dark: true, accent: NSColor(srgbRed: 0.98, green: 0.24, blue: 0.33, alpha: 1), isMinimized: true),
    ]

    private static let windowlessApps = [
        "com.apple.mail", "com.apple.iCal", "com.apple.Numbers", "com.apple.iWork.Numbers", "com.apple.QuickTimePlayerX",
        "com.apple.Preview", "com.apple.Notes", "com.apple.Photos", "com.apple.systempreferences",
    ]

    private static let tabs: [(title: String, url: String)] = [
        ("Fenestra · GitHub", "https://github.com/fenestra/fenestra"),
        ("Releases · fenestra/fenestra", "https://github.com/fenestra/fenestra/releases"),
        ("AltTab — Windows alt-tab on macOS", "https://alt-tab-macos.netlify.app"),
        ("Rectangle", "https://rectangleapp.com"),
    ]

    static func make(query: String) -> (items: [SwitcherItem], selection: Int, thumbnails: [CGWindowID: CGImage]) {
        func running(_ bundleID: String) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        var items: [SwitcherItem] = []
        var thumbnails: [CGWindowID: CGImage] = [:]
        for (offset, window) in windows.enumerated() {
            guard let app = running(window.bundleID) else { continue }
            let id = CGWindowID(900_001 + offset)
            items.append(SwitcherItem(app: app, window: nil, windowID: id, title: window.title, size: window.size,
                                      isMinimized: window.isMinimized, isHidden: false, spaceLabel: window.spaceLabel))
            thumbnails[id] = preview(size: window.size, dark: window.dark, accent: window.accent)
        }
        items += windowlessApps.compactMap(running).map {
            SwitcherItem(app: $0, window: nil, windowID: 0, title: "", size: .zero, isMinimized: false, isHidden: false)
        }
        guard !query.isEmpty, let chrome = running("com.google.Chrome") else { return (items, min(1, items.count - 1), thumbnails) }

        let tabItems = tabs.enumerated().map { offset, tab in
            SwitcherItem(app: chrome, window: nil, windowID: 0, title: tab.title, size: .zero, isMinimized: false, isHidden: false,
                         tab: BrowserTab(windowID: 1, index: offset + 2, isActive: false, url: tab.url))
        }
        let results = Search.results(for: query, in: items + tabItems)
        return (results.items, results.selection, thumbnails)
    }

    /// A generic app window: title bar, sidebar, a header and lines of "content".
    private static func preview(size: CGSize, dark: Bool, accent: NSColor) -> CGImage? {
        let width = 720, height = Int(720 * size.height / size.width)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let ink = dark ? NSColor.white : NSColor.black
        func fill(_ color: NSColor, _ rect: CGRect, radius: CGFloat = 0) {
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        fill(dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.98, alpha: 1), CGRect(x: 0, y: 0, width: w, height: h))
        fill(dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1), CGRect(x: 0, y: h - 34, width: w, height: 34))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(color, CGRect(x: 16 + CGFloat(index) * 20, y: h - 23, width: 12, height: 12), radius: 6)
        }

        let sidebar = w * 0.24
        fill(accent.withAlphaComponent(dark ? 0.16 : 0.08), CGRect(x: 0, y: 0, width: sidebar, height: h - 34))
        for row in 0..<7 {
            let y = h - 70 - CGFloat(row) * 30
            guard y > 20 else { break }
            fill(row == 1 ? accent.withAlphaComponent(0.55) : ink.withAlphaComponent(0.14),
                 CGRect(x: 18, y: y, width: sidebar - 36 - CGFloat(row % 3) * 14, height: 12), radius: 6)
        }

        let left = sidebar + 32
        fill(accent.withAlphaComponent(0.9), CGRect(x: left, y: h - 84, width: w * 0.3, height: 20), radius: 6)
        fill(accent.withAlphaComponent(0.14), CGRect(x: left, y: h - 190, width: (w - left - 32) / 2 - 8, height: 84), radius: 12)
        fill(ink.withAlphaComponent(0.06), CGRect(x: left + (w - left - 32) / 2 + 8, y: h - 190, width: (w - left - 32) / 2 - 8, height: 84), radius: 12)
        let widths: [CGFloat] = [0.9, 0.75, 0.82, 0.6, 0.88, 0.7, 0.8, 0.5]
        for (row, fraction) in widths.enumerated() {
            let y = h - 222 - CGFloat(row) * 24
            guard y > 20 else { break }
            fill(ink.withAlphaComponent(0.12), CGRect(x: left, y: y, width: (w - left - 32) * fraction, height: 10), radius: 5)
        }
        return context.makeImage()
    }

    /// A wallpaper-like gradient placed behind the panel for the screenshot.
    final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [
                NSColor(srgbRed: 0.08, green: 0.16, blue: 0.42, alpha: 1),
                NSColor(srgbRed: 0.38, green: 0.2, blue: 0.6, alpha: 1),
                NSColor(srgbRed: 0.86, green: 0.42, blue: 0.5, alpha: 1),
            ])!.draw(in: bounds, angle: -30)
            NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: .clear)!
                .draw(fromCenter: NSPoint(x: bounds.width * 0.25, y: bounds.height * 0.8), radius: 0,
                      toCenter: NSPoint(x: bounds.width * 0.25, y: bounds.height * 0.8), radius: bounds.width * 0.45, options: [])
        }
    }
}
