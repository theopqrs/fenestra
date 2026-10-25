import Foundation

enum Settings {
    private enum Key {
        static let enabled = "enabled"
        static let thumbnails = "showThumbnails"
        static let windowlessApps = "showWindowlessApps"
        static let cycleAppWindows = "cycleAppWindows"
        static let hideAllShortcut = "hideAllShortcut"
        static let searchBrowserTabs = "searchBrowserTabs"
        static let windowTiling = "windowTiling"
        static let askedScreenRecording = "askedScreenRecording"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [Key.enabled: true, Key.thumbnails: true, Key.windowlessApps: true,
                                     Key.cycleAppWindows: true, Key.hideAllShortcut: true, Key.searchBrowserTabs: true,
                                     Key.windowTiling: true])
    }

    /// Whether ⌃⌥ + arrows / letters arrange the front window.
    static var windowTiling: Bool {
        get { defaults.bool(forKey: Key.windowTiling) }
        set { defaults.set(newValue, forKey: Key.windowTiling) }
    }

    /// Whether typing in ⌘⇥ also searches the Chrome tabs.
    static var searchBrowserTabs: Bool {
        get { defaults.bool(forKey: Key.searchBrowserTabs) }
        set { defaults.set(newValue, forKey: Key.searchBrowserTabs) }
    }

    /// Whether ⌥⌘M hides every app (and shows them back).
    static var hideAllShortcut: Bool {
        get { defaults.bool(forKey: Key.hideAllShortcut) }
        set { defaults.set(newValue, forKey: Key.hideAllShortcut) }
    }

    /// Whether Fenestra also replaces "next window of the app" (⌘` / ⌘<).
    static var cycleAppWindows: Bool {
        get { defaults.bool(forKey: Key.cycleAppWindows) }
        set { defaults.set(newValue, forKey: Key.cycleAppWindows) }
    }

    /// Whether Fenestra replaces ⌘⇥ (when false, the Dock's switcher is restored).
    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    static var showThumbnails: Bool {
        get { defaults.bool(forKey: Key.thumbnails) }
        set { defaults.set(newValue, forKey: Key.thumbnails) }
    }

    /// Also list apps that have no window on the current Space (selecting one activates the app).
    static var showWindowlessApps: Bool {
        get { defaults.bool(forKey: Key.windowlessApps) }
        set { defaults.set(newValue, forKey: Key.windowlessApps) }
    }

    static var askedScreenRecording: Bool {
        get { defaults.bool(forKey: Key.askedScreenRecording) }
        set { defaults.set(newValue, forKey: Key.askedScreenRecording) }
    }
}
