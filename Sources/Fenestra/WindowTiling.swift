import AppKit
import Carbon.HIToolbox

enum TilingAction {
    case left, right, top, bottom
    case maximize, center
    case firstThird, centerThird, lastThird
    /// Back to the frame the window had before Fenestra arranged it.
    case restore
}

/// ⌃⌥ shortcuts that arrange the front window on its screen: halves (pressing again cycles ½ → ⅓ → ⅔),
/// thirds, full screen (pressing again restores), centred, and back to the original frame.
final class WindowTiling {
    /// A screen in Accessibility coordinates (origin at the top-left of the main screen, y going down).
    struct ScreenArea {
        let frame: CGRect
        /// Without the menu bar and the Dock.
        let visible: CGRect
    }

    private let queue = DispatchQueue(label: "Fenestra.tiling", qos: .userInteractive)
    // Only touched on `queue`.
    private var originalFrames: [CGWindowID: CGRect] = [:]
    private var last: (windowID: CGWindowID, action: TilingAction, step: Int, frame: CGRect)?

    /// ⌃⌥ + key → action. Letters follow the keyboard layout. Main thread only.
    static func keyMap() -> [Int: TilingAction] {
        var map: [Int: TilingAction] = [
            kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_UpArrow: .top, kVK_DownArrow: .bottom,
            kVK_Return: .maximize, kVK_ANSI_KeypadEnter: .maximize, kVK_Delete: .restore,
        ]
        for (letter, action) in [("c", TilingAction.center), ("d", .firstThird), ("f", .centerThird), ("g", .lastThird)] {
            if let keyCode = KeyboardInterceptor.keyCode(typing: letter) { map[keyCode] = action }
        }
        return map
    }

    /// Main thread only.
    static func screenAreas() -> [ScreenArea] {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { ScreenArea(frame: flipped($0.frame), visible: flipped($0.visibleFrame)) }
    }

    /// Arranges the focused window of the front app.
    func perform(_ action: TilingAction) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let screens = Self.screenAreas()
        queue.async {
            guard let window = Self.focusedWindow(of: pid) else { return }
            self.apply(action, to: window, screens: screens)
        }
    }

    /// On `queue` (or from the `--tiling-test` debug mode). Returns the window's frame afterwards.
    @discardableResult
    func apply(_ action: TilingAction, to window: AXUIElement, screens: [ScreenArea]) -> CGRect? {
        guard !Self.bool(window, "AXFullScreen"), !Self.bool(window, kAXMinimizedAttribute),
              let id = PrivateAPI.windowID(of: window), let current = Self.frame(of: window),
              let screen = screens.max(by: { $0.frame.intersection(current).area < $1.frame.intersection(current).area })
        else { return nil }

        let repeated = last.map { $0.windowID == id && $0.action == action && $0.frame.isClose(to: current) } ?? false
        let step = repeated ? last!.step + 1 : 0
        var target: CGRect
        switch action {
        case .restore:
            guard let original = originalFrames.removeValue(forKey: id) else { return current }
            target = original
        case .maximize where step % 2 == 1:
            // Pressed again: back to the size it had before.
            guard let original = originalFrames.removeValue(forKey: id) else { return current }
            target = original
        default:
            target = Self.target(for: action, step: step, in: screen.visible, current: current)
            if originalFrames[id] == nil { originalFrames[id] = current }
        }

        Self.setFrame(target.integral, of: window)
        let result = Self.frame(of: window) ?? target
        last = action == .restore ? nil : (id, action, step, result)
        return result
    }

    private static func target(for action: TilingAction, step: Int, in area: CGRect, current: CGRect) -> CGRect {
        let fraction: CGFloat = [1.0 / 2, 1.0 / 3, 2.0 / 3][step % 3]
        let third = area.width / 3
        switch action {
        case .left:
            return CGRect(x: area.minX, y: area.minY, width: area.width * fraction, height: area.height)
        case .right:
            return CGRect(x: area.maxX - area.width * fraction, y: area.minY, width: area.width * fraction, height: area.height)
        case .top:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * fraction)
        case .bottom:
            return CGRect(x: area.minX, y: area.maxY - area.height * fraction, width: area.width, height: area.height * fraction)
        case .maximize, .restore:
            return area
        case .center:
            let size = CGSize(width: min(current.width, area.width), height: min(current.height, area.height))
            return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        case .firstThird:
            return CGRect(x: area.minX, y: area.minY, width: third, height: area.height)
        case .centerThird:
            return CGRect(x: area.minX + third, y: area.minY, width: third, height: area.height)
        case .lastThird:
            return CGRect(x: area.minX + 2 * third, y: area.minY, width: third, height: area.height)
        }
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Size, position, then size again: a window moving to another screen may be clamped by the first resize.
    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var position = frame.origin, size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        // Apps with "enhanced user interface" on (Chrome, Electron…) animate every change: turn it off meanwhile.
        let application = AXUIElementCreateApplication(pid)
        let enhanced = bool(application, "AXEnhancedUserInterface")
        if enhanced { AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if enhanced { AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 3 && abs(minY - other.minY) < 3 && abs(width - other.width) < 3 && abs(height - other.height) < 3
    }
}
