import AppKit

/// ⌥⌘M: hides every app to clear the screen (instant, unlike minimizing each window into the Dock).
/// Pressing it again shows those apps back and returns to the app that was in front.
final class HideAll {
    private var hiddenApps: [NSRunningApplication] = []
    private var previousFront: NSRunningApplication?

    func toggle() {
        let stillHidden = hiddenApps.filter { !$0.isTerminated && $0.isHidden }
        if stillHidden.isEmpty { hideAll() } else { showBack(stillHidden) }
    }

    private func hideAll() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated && $0.processIdentifier != ownPID
        }
        guard !apps.isEmpty else { return }
        previousFront = NSWorkspace.shared.frontmostApplication
        hiddenApps = apps
        apps.forEach { $0.hide() }
    }

    private func showBack(_ apps: [NSRunningApplication]) {
        apps.forEach { $0.unhide() }
        hiddenApps = []
        guard let front = previousFront, !front.isTerminated else { return }
        // Once the apps are back, bring the previous front app forward again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(front.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}
