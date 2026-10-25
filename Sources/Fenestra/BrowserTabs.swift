import AppKit
import CoreServices

struct BrowserTab {
    /// The browser's own AppleScript window id (not a CGWindowID).
    let windowID: Int
    /// 1-based position of the tab in its window.
    var index: Int
    let isActive: Bool
    let url: String

    /// "docs.github.com" for "https://www.docs.github.com/…".
    var host: String {
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Chrome's tabs, read and driven through AppleScript. macOS asks once for the permission to control Chrome.
enum BrowserTabs {
    static let bundleIDs = ["com.google.Chrome"]

    enum Permission { case granted, notAsked, denied }

    private static let queue = DispatchQueue(label: "Fenestra.tabs", qos: .userInitiated)

    static func runningBrowsers() -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    /// With `ask`, shows macOS's consent dialog if the user has not answered yet (and waits for the answer).
    static func permission(for browser: NSRunningApplication, ask: Bool = false) -> Permission {
        guard let bundleID = browser.bundleIdentifier else { return .denied }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .granted
        case -1744: return .notAsked // errAEEventWouldRequireUserConsent
        default: return .denied
        }
    }

    /// The tabs of every running browser we are allowed to control. Completion on the main thread.
    static func fetch(completion: @escaping ([SwitcherItem]) -> Void) {
        let browsers = runningBrowsers()
        queue.async {
            let tabs = browsers.filter { permission(for: $0) == .granted }.flatMap(tabs(of:))
            DispatchQueue.main.async { completion(tabs) }
        }
    }

    /// Synchronous: call it off the main thread.
    static func tabs(of browser: NSRunningApplication) -> [SwitcherItem] {
        guard let bundleID = browser.bundleIdentifier, let output = run(listScript(bundleID)) else { return [] }
        return output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let windowID = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let tab = BrowserTab(windowID: windowID, index: index, isActive: fields[2] == "true",
                                 url: fields[4].trimmingCharacters(in: .whitespacesAndNewlines))
            return SwitcherItem(app: browser, window: nil, windowID: 0, title: fields[3], size: .zero,
                                isMinimized: false, isHidden: browser.isHidden, tab: tab)
        }
    }

    static func focus(_ item: SwitcherItem) {
        guard let tab = item.tab, let bundleID = item.app.bundleIdentifier else { return }
        if item.app.isHidden { item.app.unhide() }
        queue.async {
            _ = run("""
            tell application id "\(bundleID)"
                set targetWindow to window id \(tab.windowID)
                if minimized of targetWindow then set minimized of targetWindow to false
                set active tab index of targetWindow to \(tab.index)
                set index of targetWindow to 1
                activate
            end tell
            """)
        }
    }

    static func close(_ item: SwitcherItem) {
        guard let tab = item.tab, let bundleID = item.app.bundleIdentifier else { return }
        queue.async {
            _ = run("tell application id \"\(bundleID)\" to close tab \(tab.index) of window id \(tab.windowID)")
        }
    }

    /// One record per tab (separated by U+001E): window id, tab index, active, title, URL (separated by U+001F).
    /// Titles and URLs are read in bulk: one Apple event per property instead of one per tab.
    private static func listScript(_ bundleID: String) -> String {
        """
        set recordSeparator to character id 30
        set fieldSeparator to character id 31
        tell application id "\(bundleID)"
            set windowIDs to id of every window
            set activeIndexes to active tab index of every window
            set tabTitles to title of every tab of every window
            set tabURLs to URL of every tab of every window
        end tell
        set output to ""
        repeat with w from 1 to count of windowIDs
            set titles to item w of tabTitles
            set urls to item w of tabURLs
            repeat with t from 1 to count of titles
                set isActive to ((item w of activeIndexes) = t)
                set output to output & (item w of windowIDs as text) & fieldSeparator & (t as text) & fieldSeparator ¬
                    & (isActive as text) & fieldSeparator & (item t of titles) & fieldSeparator & (item t of urls) & recordSeparator
            end repeat
        end repeat
        return output
        """
    }

    /// Runs an AppleScript with osascript, so that a busy browser never blocks Fenestra.
    private static func run(_ script: String, timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
