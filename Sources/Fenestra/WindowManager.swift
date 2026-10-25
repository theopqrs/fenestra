import AppKit
import ApplicationServices

struct SwitcherItem {
    let app: NSRunningApplication
    /// The window's Accessibility element. nil for an app without windows, or for a window on another
    /// Space that Fenestra has not been able to resolve yet.
    let window: AXUIElement?
    /// 0 for an app without windows.
    let windowID: CGWindowID
    let title: String
    let size: CGSize
    var isMinimized: Bool
    var isHidden: Bool
    /// "Bureau 2", "Plein écran"… for a window that is not on a visible Space.
    var spaceLabel: String? = nil
    /// Set for a browser tab found by the search (`title` is then the tab's title).
    var tab: BrowserTab? = nil

    var pid: pid_t { app.processIdentifier }
    var isWindow: Bool { windowID != 0 }
    var isTab: Bool { tab != nil }
    /// An app shown without any window (it has none open).
    var isApp: Bool { !isWindow && !isTab }
    var appName: String { app.localizedName ?? "Application" }

    /// The title without the " - Google Chrome – Profil" style suffix many apps append.
    var displayTitle: String {
        guard !title.isEmpty else { return appName }
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator + appName), range.lowerBound > title.startIndex {
                return String(title[..<range.lowerBound])
            }
        }
        return title
    }
}

/// Lists the windows of regular apps on every Space, most recently used first, and performs actions on them.
///
/// Windows of the visible Spaces come from the Accessibility API. Windows of the other Spaces and of
/// full-screen apps are listed by the window server; the Accessibility API only hands out their elements
/// once we have met them (focus / creation notifications) or found them by brute force, so elements are cached.
/// AX calls run on private queues because an unresponsive app can block them.
final class WindowManager {
    /// Called on the main thread when the focused window may have changed.
    var onFocusChange: (() -> Void)?

    private let queue = DispatchQueue(label: "Fenestra.windows", qos: .userInteractive)
    private let discoveryQueue = DispatchQueue(label: "Fenestra.discovery", qos: .utility)

    // Only touched on `queue`.
    /// Window IDs, most recently focused first.
    private var windowMRU: [CGWindowID] = []
    /// Accessibility elements of the windows we have met, including those now on other Spaces.
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var lastDiscovery: [pid_t: Date] = [:]

    // Only touched on the main thread.
    /// App PIDs, most recently activated first.
    private var appMRU: [pid_t] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { appMRU = [front.processIdentifier] }
    }

    // MARK: - Focus tracking

    /// Starts following focus changes (needs the Accessibility permission). Safe to call more than once.
    func startTracking() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let pid = Self.app(in: note)?.processIdentifier else { return }
                appMRU.removeAll { $0 == pid }
                appMRU.insert(pid, at: 0)
                noteFocusedWindow(of: pid)
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                self?.noteFocusedWindow(of: pid)
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = Self.app(in: note) else { return }
                self?.observe(app, attempt: 0)
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let pid = Self.app(in: note)?.processIdentifier else { return }
                if let observer = observers.removeValue(forKey: pid) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                appMRU.removeAll { $0 == pid }
            },
        ]

        let apps = Self.regularApps()
        apps.forEach { observe($0, attempt: 0) }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { noteFocusedWindow(of: pid) }
        // Find the windows already open on other Spaces before the first ⌘⇥.
        queue.async { self.scheduleDiscovery(Set(apps.map(\.processIdentifier))) }
    }

    private static func app(in note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func observe(_ app: NSRunningApplication, attempt: Int) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, !app.isTerminated, pid != ProcessInfo.processInfo.processIdentifier else { return }
        if app.activationPolicy == .regular,
           let observer = Self.makeObserver(pid: pid, refcon: Unmanaged.passUnretained(self).toOpaque()) {
            observers[pid] = observer
            return
        }
        // Freshly launched apps need a moment before they answer Accessibility requests.
        guard attempt < 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [weak self] in
            self?.observe(app, attempt: attempt + 1)
        }
    }

    private static func makeObserver(pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let observer else { return nil }
        let application = AXUIElementCreateApplication(pid)
        let notifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification]
        let registered = notifications.filter { AXObserverAddNotification(observer, application, $0 as CFString, refcon) == .success }
        guard !registered.isEmpty else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        if notification == kAXWindowCreatedNotification {
            queue.async {
                if let id = PrivateAPI.windowID(of: element) { self.elements[id] = element }
            }
        } else {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { noteFocusedWindow(of: pid) }
        }
    }

    private func noteFocusedWindow(of pid: pid_t) {
        queue.async { self.touchFocusedWindow(of: pid) }
        onFocusChange?()
    }

    /// On `queue`: moves the app's focused window to the front of the recency list.
    private func touchFocusedWindow(of pid: pid_t) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        guard let id = PrivateAPI.windowID(of: window) else { return }
        elements[id] = window
        touch(id)
    }

    private func touch(_ id: CGWindowID) {
        windowMRU.removeAll { $0 == id }
        windowMRU.insert(id, at: 0)
        if windowMRU.count > 400 { windowMRU.removeLast(windowMRU.count - 400) }
    }

    // MARK: - Listing

    func fetchItems(frontPID: pid_t?, includeWindowlessApps: Bool, completion: @escaping ([SwitcherItem]) -> Void) {
        let appOrder = appMRU
        queue.async {
            let items = self.collectItems(appOrder: appOrder, frontPID: frontPID, includeWindowlessApps: includeWindowlessApps)
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// Synchronous: call it from `queue` (or from the `--list` debug mode).
    func collectItems(appOrder: [pid_t], frontPID: pid_t?, includeWindowlessApps: Bool) -> [SwitcherItem] {
        let apps = Self.regularApps()
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let allWindows = Self.windowServerInfo()
        let onScreen = Self.onScreenWindowOrder()

        if let frontPID { touchFocusedWindow(of: frontPID) }
        windowMRU.removeAll { allWindows[$0] == nil }
        elements = elements.filter { allWindows[$0.key] != nil }

        var items: [SwitcherItem] = []
        var listed = Set<CGWindowID>()

        // Visible Spaces, plus minimized windows and hidden apps: the Accessibility API is authoritative.
        for app in apps {
            for (id, element) in Self.windowElements(of: app) where !listed.contains(id) {
                elements[id] = element
                guard let attributes = Self.attributes(of: element),
                      let item = Self.item(app: app, id: id, element: element, attributes: attributes) else { continue }
                items.append(item)
                listed.insert(id)
            }
        }

        // Other desktops and full-screen apps, as listed by the window server.
        var undiscovered = Set<pid_t>()
        for space in PrivateAPI.hiddenSpaces() {
            for id in PrivateAPI.windowIDs(onSpace: space.id) where !listed.contains(id) {
                guard let info = allWindows[id], info.layer == 0, let app = appsByPID[info.pid] else { continue }
                var item: SwitcherItem?
                if let element = elements[id], let attributes = Self.attributes(of: element) {
                    item = Self.item(app: app, id: id, element: element, attributes: attributes)
                } else {
                    item = Self.item(app: app, id: id, info: info)
                    undiscovered.insert(info.pid)
                }
                guard var item else { continue }
                item.spaceLabel = space.label
                items.append(item)
                listed.insert(id)
            }
        }

        // Windows minimized or hidden while on another Space are on no Space any more: only our cache knows them.
        for (id, element) in elements where !listed.contains(id) {
            guard let info = allWindows[id], let app = appsByPID[info.pid], let attributes = Self.attributes(of: element),
                  let item = Self.item(app: app, id: id, element: element, attributes: attributes),
                  item.isMinimized || item.isHidden else { continue }
            items.append(item)
            listed.insert(id)
        }
        scheduleDiscovery(undiscovered)

        let mruRank = Dictionary(windowMRU.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let screenRank = Dictionary(onScreen.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let appRank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func sortKey(_ item: SwitcherItem) -> (Int, Int, Int) {
            if let rank = mruRank[item.windowID] { return (0, rank, 0) }
            if let rank = screenRank[item.windowID] { return (1, rank, 0) }
            return (2, appRank[item.pid] ?? Int.max, -Int(item.windowID)) // newer windows first
        }
        items.sort { sortKey($0) < sortKey($1) }

        guard includeWindowlessApps else { return items }
        let withWindows = Set(items.map(\.pid))
        let windowless = apps
            .filter { !withWindows.contains($0.processIdentifier) }
            .sorted { (appRank[$0.processIdentifier] ?? Int.max) < (appRank[$1.processIdentifier] ?? Int.max) }
            .map { SwitcherItem(app: $0, window: nil, windowID: 0, title: "", size: .zero, isMinimized: false, isHidden: $0.isHidden) }
        return items + windowless
    }

    /// On `queue`: looks for the elements of windows on other Spaces, at most every 30 s per app.
    private func scheduleDiscovery(_ pids: Set<pid_t>) {
        let now = Date()
        let due = pids.filter { now.timeIntervalSince(lastDiscovery[$0] ?? .distantPast) > 30 }
        guard !due.isEmpty else { return }
        due.forEach { lastDiscovery[$0] = now }
        discoveryQueue.async { due.forEach { self.discoverWindows(of: $0, budget: 0.15) } }
    }

    /// On `discoveryQueue`.
    private func discoverWindows(of pid: pid_t, budget: TimeInterval) {
        let found = PrivateAPI.windowElementsByBruteForce(pid: pid, budget: budget)
            .compactMap { element in PrivateAPI.windowID(of: element).map { ($0, element) } }
        queue.async {
            for (id, element) in found where self.elements[id] == nil { self.elements[id] = element }
        }
    }

    private static func regularApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }
    }

    private struct WindowServerInfo {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        let alpha: Double
        let name: String?
    }

    /// Every window known to the window server, on any Space, on screen or not.
    private static func windowServerInfo() -> [CGWindowID: WindowServerInfo] {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: WindowServerInfo] = [:]
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            result[id] = WindowServerInfo(pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                                          alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                                          name: entry[kCGWindowName as String] as? String)
        }
        return result
    }

    private static func onScreenWindowOrder() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// The app's windows on the visible Spaces (plus its minimized windows).
    private static func windowElements(of app: NSRunningApplication) -> [(CGWindowID, AXUIElement)] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { element in PrivateAPI.windowID(of: element).map { ($0, element) } }
    }

    private static let windowAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXSizeAttribute,
    ] as CFArray

    /// nil when the app does not answer (it may be busy): callers then fall back to the window server's info.
    private static func attributes(of element: AXUIElement) -> [AnyObject]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, windowAttributes, [], &values) == .success,
              let attributes = values as? [AnyObject], attributes.count == 5 else { return nil }
        return attributes
    }

    /// nil when the element is not a real window (palette, popover, tiny helper window…).
    private static func item(app: NSRunningApplication, id: CGWindowID, element: AXUIElement, attributes: [AnyObject]) -> SwitcherItem? {
        guard attributes[0] as? String == kAXWindowRole,
              let subrole = attributes[1] as? String,
              subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
        var size = CGSize.zero
        if CFGetTypeID(attributes[4]) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(attributes[4], to: AXValue.self), .cgSize, &size)
        }
        guard size.width >= 60, size.height >= 40 else { return nil }
        return SwitcherItem(app: app, window: element, windowID: id, title: attributes[2] as? String ?? "", size: size,
                            isMinimized: attributes[3] as? Bool ?? false, isHidden: app.isHidden)
    }

    /// A window we have no Accessibility element for yet: trust the window server (the title needs Screen Recording).
    private static func item(app: NSRunningApplication, id: CGWindowID, info: WindowServerInfo) -> SwitcherItem? {
        // Same size floor as the Accessibility path: Stage Manager reports strip windows at their reduced size.
        guard info.alpha > 0, info.bounds.width >= 60, info.bounds.height >= 40 else { return nil }
        return SwitcherItem(app: app, window: nil, windowID: id, title: info.name ?? "", size: info.bounds.size,
                            isMinimized: false, isHidden: false)
    }

    // MARK: - Actions

    func focus(_ item: SwitcherItem) {
        if item.app.isHidden { item.app.unhide() }
        queue.async {
            guard item.isWindow else { return Self.activate(item.app) }
            self.touch(item.windowID)
            if let window = item.window, item.isMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            // Also switches to the window's Space when it is on another desktop or in full screen.
            if !PrivateAPI.focus(windowID: item.windowID, pid: item.pid) { Self.activate(item.app) }
            if let window = item.window {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }

    private static func activate(_ app: NSRunningApplication) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.async { app.activate(options: .activateAllWindows) }
    }

    func close(_ item: SwitcherItem) {
        withElement(of: item) { window in
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
        }
    }

    func setMinimized(_ item: SwitcherItem, _ minimized: Bool) {
        withElement(of: item) { window in
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                         minimized ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    /// Runs `action` on `queue` with the window's element, searching for it first if the window
    /// sits on another Space and we have never met it.
    private func withElement(of item: SwitcherItem, _ action: @escaping (AXUIElement) -> Void) {
        guard item.isWindow else { return }
        if let window = item.window { return queue.async { action(window) } }
        discoveryQueue.async {
            self.discoverWindows(of: item.pid, budget: 0.4)
            self.queue.async {
                if let window = self.elements[item.windowID] { action(window) }
            }
        }
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String, element: element)
}
