import AppKit
import ApplicationServices

/// Private macOS APIs (SkyLight / HIServices), resolved at runtime so that a missing symbol
/// degrades to the public fallback instead of crashing at launch.
enum PrivateAPI {
    private typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias GetWindowOfElement = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTags = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func load<T>(_ name: String, as _: T.Type) -> T? {
        let symbol = skyLight.flatMap { dlsym($0, name) } ?? dlsym(defaultHandle, name)
        return symbol.map { unsafeBitCast($0, to: T.self) }
    }

    private static let setSymbolicHotKeyEnabled = load("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabled.self)
    private static let getWindowOfElement = load("_AXUIElementGetWindow", as: GetWindowOfElement.self)
    private static let getProcessForPID = load("GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = load("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    private static let postEventRecord = load("SLPSPostEventRecordTo", as: PostEventRecordTo.self)
    private static let mainConnection = load("CGSMainConnectionID", as: MainConnectionID.self)
    private static let captureWindowList = load("CGSHWCaptureWindowList", as: CaptureWindowList.self)
    private static let copyManagedDisplaySpaces = load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copyWindowsWithOptionsAndTags = load("CGSCopyWindowsWithOptionsAndTags", as: CopyWindowsWithOptionsAndTags.self)
    private static let createWithRemoteToken = load("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)

    /// Symbolic hot keys owned by the Dock's app switcher: ⌘⇥ and ⌘⇧⇥.
    private static let commandTabHotKeys: [Int32] = [1, 2]
    /// "Move focus to next window": ⌘` on a US keyboard, ⌘< on a French one.
    private static let nextWindowHotKey: Int32 = 27

    /// The "move focus to next window" shortcut as set in System Settings › Keyboard › Shortcuts.
    /// Read once, so that restoring it from a crash handler touches no preferences.
    static let nextWindowShortcut: (isEnabled: Bool, keyCode: Int) = {
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let entry = hotKeys?[String(nextWindowHotKey)] as? [String: Any]
        let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int] ?? []
        return (entry?["enabled"] as? Bool ?? true, parameters.count > 1 ? parameters[1] : 50 /* kVK_ANSI_Grave */)
    }()

    /// Turns off the native shortcuts Fenestra handles, so the keys reach our event tap.
    static func takeOverNativeShortcuts(nextWindow: Bool) {
        guard let setSymbolicHotKeyEnabled else { return }
        for hotKey in commandTabHotKeys { _ = setSymbolicHotKeyEnabled(hotKey, false) }
        _ = setSymbolicHotKeyEnabled(nextWindowHotKey, nextWindow ? false : nextWindowShortcut.isEnabled)
    }

    /// Back to macOS's behaviour: ⌘⇥ on, "next window" as the user set it.
    static func restoreNativeShortcuts() {
        guard let setSymbolicHotKeyEnabled else { return }
        for hotKey in commandTabHotKeys { _ = setSymbolicHotKeyEnabled(hotKey, true) }
        _ = setSymbolicHotKeyEnabled(nextWindowHotKey, nextWindowShortcut.isEnabled)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindowOfElement else { return nil }
        var windowID: CGWindowID = 0
        return getWindowOfElement(element, &windowID) == .success && windowID != 0 ? windowID : nil
    }

    /// Brings one specific window to the front and makes it key (the technique used by yabai and AltTab).
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let getProcessForPID, let setFrontProcess else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr,
              setFrontProcess(&psn, windowID, 0x200 /* kCPSUserGenerated */) == 0 else { return false }
        makeKeyWindow(windowID, psn: &psn)
        return true
    }

    private static func makeKeyWindow(_ windowID: CGWindowID, psn: inout ProcessSerialNumber) {
        guard let postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        for phase: UInt8 in [0x01, 0x02] {
            bytes[0x08] = phase
            _ = postEventRecord(&psn, &bytes)
        }
    }

    // MARK: - Spaces

    struct Space {
        let id: UInt64
        /// "Bureau 2", "Plein écran"…
        let label: String
    }

    /// The Spaces that are not currently visible on any display, desktops and full-screen apps alike.
    static func hiddenSpaces() -> [Space] {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var spaces: [Space] = []
        for display in displays {
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID)
            var desktopNumber = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(space) else { continue }
                let isFullScreen = space["type"] as? Int == 4 || space["TileLayoutManager"] != nil
                if !isFullScreen { desktopNumber += 1 }
                if id != current { spaces.append(Space(id: id, label: isFullScreen ? "Plein écran" : "Bureau \(desktopNumber)")) }
            }
        }
        return spaces
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    /// The windows shown on a Space, front to back.
    static func windowIDs(onSpace space: UInt64) -> [CGWindowID] {
        guard let mainConnection, let copyWindowsWithOptionsAndTags else { return [] }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let spaces = [NSNumber(value: space)] as CFArray
        let windows = copyWindowsWithOptionsAndTags(mainConnection(), 0, spaces, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
        return windows?.map(\.uint32Value) ?? []
    }

    /// Accessibility elements of an app's windows on every Space, found by trying element IDs one by one
    /// (`kAXWindowsAttribute` only returns the windows of the current Space). Same technique as AltTab.
    static func windowElementsByBruteForce(pid: pid_t, budget: TimeInterval) -> [AXUIElement] {
        guard let createWithRemoteToken else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })
        var windows: [AXUIElement] = []
        for elementID: UInt64 in 0..<1500 where Date() < deadline {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
               let subrole = subrole as? String, subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole {
                windows.append(element)
            }
        }
        return windows
    }

    // MARK: - Screenshots

    static var canCaptureWindows: Bool { mainConnection != nil && captureWindowList != nil }

    /// Synchronous window screenshot (needs the Screen Recording permission).
    /// Windows parked in the Stage Manager strip come back fully transparent: the window server does not draw them.
    static func captureWindow(_ windowID: CGWindowID) -> CGImage? {
        guard let mainConnection, let captureWindowList else { return nil }
        var id = windowID
        let options: UInt32 = (1 << 11) | (1 << 9) | (1 << 19) // ignoreGlobalClipShape | nominalResolution | fullSize
        let images = captureWindowList(mainConnection(), &id, 1, options)?.takeRetainedValue() as? [CGImage]
        return images?.first
    }
}
