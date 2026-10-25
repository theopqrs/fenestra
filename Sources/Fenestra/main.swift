import AppKit
import ScreenCaptureKit

if let flag = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.indices.contains(flag + 1) {
    // Debug: open the switcher on the current windows, save what the screen shows and exit.
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Settings.registerDefaults()
    NSApplication.shared.setActivationPolicy(.accessory)
    var items = WindowManager().collectItems(appOrder: [], frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                             includeWindowlessApps: Settings.showWindowlessApps)
    var selection = min(1, items.count - 1)
    // --query <texte>: show the search results for that text, Chrome tabs included.
    let query = CommandLine.arguments.firstIndex(of: "--query").flatMap {
        CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
    } ?? ""
    if !query.isEmpty {
        let tabs = BrowserTabs.runningBrowsers().filter { BrowserTabs.permission(for: $0) == .granted }.flatMap(BrowserTabs.tabs(of:))
        (items, selection) = Search.results(for: query, in: items + tabs)
    }
    let thumbnails = ThumbnailProvider()
    let panel = SwitcherPanel()
    panel.present(items, selection: selection, thumbnails: [:], query: query)
    thumbnails.refresh(items.filter(\.isWindow)) { id, image in panel.setThumbnail(image, for: id) }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.5))
        if #available(macOS 15.2, *) {
            let frame = panel.frame.insetBy(dx: -30, dy: -30)
            let rect = CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            if let image = try? await SCScreenshotManager.captureImage(in: rect),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: output)
            }
        }
        exit(0)
    }
    NSApplication.shared.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--demo-screenshot"), CommandLine.arguments.indices.contains(flag + 1) {
    // Debug: the README screenshots — made-up windows on a gradient backdrop, nothing real on screen.
    // --query <texte> shows the search instead.
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let query = CommandLine.arguments.firstIndex(of: "--query").flatMap {
        CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
    } ?? ""
    NSApplication.shared.setActivationPolicy(.accessory)
    let demo = DemoContent.make(query: query)
    let panel = SwitcherPanel()
    panel.present(demo.items, selection: demo.selection, thumbnails: demo.thumbnails, query: query)
    let backdrop = NSWindow(contentRect: panel.frame.insetBy(dx: -70, dy: -56), styleMask: .borderless, backing: .buffered, defer: false)
    backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    backdrop.contentView = DemoContent.Backdrop()
    backdrop.orderFrontRegardless()
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        if #available(macOS 15.2, *) {
            let frame = backdrop.frame
            let rect = CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            if let image = try? await SCScreenshotManager.captureImage(in: rect),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: output)
            }
        }
        exit(0)
    }
    NSApplication.shared.run()
}

if CommandLine.arguments.contains("--tiling-test") {
    // Debug: arranges a test window of our own with every action and prints the frames obtained.
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 360),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.title = "Fenestra — test de rangement"
    window.orderFrontRegardless()
    let screens = WindowTiling.screenAreas()
    // AX requests to our own app are answered by its main thread: send them from another one.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
        guard let testWindow = (value as? [AXUIElement])?.first else {
            print("Fenêtre de test introuvable (autorisation Accessibilité ?)")
            exit(1)
        }
        print("Zone utile de l'écran :", screens.map { "\(Int($0.visible.minX)),\(Int($0.visible.minY)) \(Int($0.visible.width))×\(Int($0.visible.height))" })
        let tiling = WindowTiling()
        let actions: [TilingAction] = [.left, .left, .left, .right, .top, .bottom, .maximize, .maximize,
                                       .center, .firstThird, .centerThird, .lastThird, .restore]
        for action in actions {
            let frame = tiling.apply(action, to: testWindow, screens: screens)
            print(String(describing: action).padding(toLength: 12, withPad: " ", startingAt: 0), "→",
                  frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "échec")
            Thread.sleep(forTimeInterval: 0.15)
        }
        exit(0)
    }
    NSApplication.shared.run()
}

if CommandLine.arguments.contains("--tabs") {
    // Debug: asks for the permission to control the browsers if needed, then reads their tabs.
    for browser in BrowserTabs.runningBrowsers() {
        print(browser.localizedName ?? "?", "→ autorisation :", BrowserTabs.permission(for: browser, ask: true))
        let start = Date()
        let tabs = BrowserTabs.tabs(of: browser)
        let windows = Set(tabs.compactMap { $0.tab?.windowID }).count
        print("\(tabs.count) onglets dans \(windows) fenêtre(s), lus en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        print("Sites :", Array(Set(tabs.compactMap { $0.tab?.host })).sorted().prefix(12).joined(separator: ", "))
        let query = CommandLine.arguments.last ?? ""
        if query != "--tabs" {
            let found = Search.results(for: query, in: tabs).items
            print("Recherche « \(query) » :", found.prefix(5).map { "\($0.tab!.host) (fenêtre \($0.tab!.windowID), onglet \($0.tab!.index))" })
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--list") {
    // Debug: print the switcher's window list once and exit.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    print("Accessibilité :", AXIsProcessTrusted() ? "autorisée" : "NON autorisée",
          "· Enregistrement de l'écran :", CGPreflightScreenCaptureAccess() ? "autorisé" : "non autorisé")
    let manager = WindowManager()
    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    _ = manager.collectItems(appOrder: [], frontPID: frontPID, includeWindowlessApps: true) // warm-up, like the running app
    let start = Date()
    let items = manager.collectItems(appOrder: [], frontPID: frontPID, includeWindowlessApps: true)
    for item in items {
        let flags = (item.isMinimized ? " [réduite]" : "") + (item.isHidden ? " [masquée]" : "")
            + (item.spaceLabel.map { " [\($0)]" } ?? "") + (item.isWindow && item.window == nil ? " [sans AX]" : "")
        print("\(item.windowID)\t\(item.appName)\t\(item.isWindow ? item.displayTitle : "(aucune fenêtre)")\(flags)")
    }
    print("\(items.count) éléments en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    print("Spaces cachés :", PrivateAPI.hiddenSpaces().map(\.label))
    let cycleKeyCode = PrivateAPI.nextWindowShortcut.keyCode
    print("Fenêtres de l'app active : ⌘\(KeyboardInterceptor.displayName(ofKeyCode: cycleKeyCode)) (keyCode \(cycleKeyCode))")
    print("Tout masquer : ⌥⌘M (keyCode \(KeyboardInterceptor.keyCode(typing: "m").map(String.init) ?? "introuvable"))")
    // Windows reachable on every Space, used to resolve windows of the other desktops.
    for app in Set(items.map(\.app)) {
        let discoveryStart = Date()
        let found = PrivateAPI.windowElementsByBruteForce(pid: app.processIdentifier, budget: 0.4)
        print("Découverte \(app.localizedName ?? "?") : \(found.count) fenêtre(s) en \(Int(Date().timeIntervalSince(discoveryStart) * 1000)) ms")
    }
    // Previews the window server can give right now ("VIDE": window not drawn, e.g. in the Stage Manager strip).
    // Saved as PNG with --thumbnails <dossier>.
    let thumbnailFolder = CommandLine.arguments.firstIndex(of: "--thumbnails").flatMap {
        CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil
    }
    if let thumbnailFolder { try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true) }
    for item in items where item.isWindow {
        let captureStart = Date()
        let image = PrivateAPI.captureWindow(item.windowID)
        let result = image.map { "\($0.width)×\($0.height)" + (ThumbnailProvider.isBlank($0) ? " VIDE" : "") } ?? "échec"
        print("Aperçu \(item.windowID) \(item.appName) : \(result) en \(Int(Date().timeIntervalSince(captureStart) * 1000)) ms")
        if let thumbnailFolder, let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: thumbnailFolder.appendingPathComponent("\(item.windowID).png"))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
