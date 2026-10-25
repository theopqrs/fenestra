import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let interceptor = KeyboardInterceptor()
    private lazy var switcher = SwitcherController(interceptor: interceptor)
    private let hideAll = HideAll()
    private let tiling = WindowTiling()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var wasTrusted = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        Settings.registerDefaults()
        installSafetyNet()
        // Never let an unresponsive app freeze the switcher for the default 6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        interceptor.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .toggleHideAll: hideAll.toggle()
            case .tile(let action): tiling.perform(action)
            default: switcher.handle(command)
            }
        }
        setUpStatusItem()

        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        applyState()
        // ⌥⌘M follows the keyboard layout (M moves between QWERTY and AZERTY).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.applyState() }
        // Accessibility can be granted or revoked while we run.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() != wasTrusted else { return }
            applyState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
        PrivateAPI.restoreNativeShortcuts()
    }

    /// Takes ⌘⇥ over from the Dock when enabled and allowed, and gives it back otherwise.
    private func applyState() {
        wasTrusted = AXIsProcessTrusted()
        if Settings.isEnabled, wasTrusted, interceptor.start() {
            interceptor.windowCycleKeyCode = Settings.cycleAppWindows ? PrivateAPI.nextWindowShortcut.keyCode : nil
            interceptor.hideAllKeyCode = Settings.hideAllShortcut ? KeyboardInterceptor.keyCode(typing: "m") : nil
            interceptor.baseCharacters = KeyboardInterceptor.layoutCharacterMap()
            interceptor.tilingKeys = Settings.windowTiling ? WindowTiling.keyMap() : [:]
            PrivateAPI.takeOverNativeShortcuts(nextWindow: Settings.cycleAppWindows)
            switcher.start()
            if Settings.showThumbnails, !CGPreflightScreenCaptureAccess(), !Settings.askedScreenRecording {
                Settings.askedScreenRecording = true
                CGRequestScreenCaptureAccess()
            }
        } else {
            interceptor.stop()
            PrivateAPI.restoreNativeShortcuts()
        }
        updateStatusIcon()
    }

    /// If Fenestra is killed or crashes while ⌘⇥ is taken over, give the shortcut back to the Dock.
    private func installSafetyNet() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(signalNumber) { received in
                PrivateAPI.restoreNativeShortcuts()
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        NSSetUncaughtExceptionHandler { _ in PrivateAPI.restoreNativeShortcuts() }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let running = interceptor.isRunning
        let image = NSImage(systemSymbolName: running ? "rectangle.stack.fill" : "rectangle.stack",
                            accessibilityDescription: "Fenestra")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = !running
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let status = !trusted ? "En attente de l'autorisation Accessibilité"
            : interceptor.isRunning ? "⌘⇥ affiche toutes vos fenêtres"
            : "En pause — le ⌘⇥ de macOS est rétabli"

        menu.addItem(.sectionHeader(title: "Fenestra"))
        let statusItem = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(.separator())

        let cycleKey = "⌘" + KeyboardInterceptor.displayName(ofKeyCode: PrivateAPI.nextWindowShortcut.keyCode)
        addItem(to: menu, "Remplacer ⌘⇥", #selector(toggleEnabled), checked: Settings.isEnabled)
        addItem(to: menu, "\(cycleKey) : fenêtres de l'app active", #selector(toggleCycleAppWindows), checked: Settings.cycleAppWindows)
        addItem(to: menu, "⌥⌘M : tout masquer / tout réafficher", #selector(toggleHideAllShortcut), checked: Settings.hideAllShortcut)
        addItem(to: menu, "⌃⌥ : ranger les fenêtres", #selector(toggleWindowTiling), checked: Settings.windowTiling)
        addItem(to: menu, "Aperçus des fenêtres", #selector(toggleThumbnails), checked: Settings.showThumbnails && screenRecording)
        addItem(to: menu, "Inclure les apps sans fenêtre", #selector(toggleWindowlessApps), checked: Settings.showWindowlessApps)
        addItem(to: menu, "Chercher dans les onglets Chrome", #selector(toggleBrowserTabs), checked: Settings.searchBrowserTabs)
        addItem(to: menu, "Ouvrir à l'ouverture de session", #selector(toggleLoginItem),
                checked: SMAppService.mainApp.status == .enabled)

        let chromeNeedsPermission = Settings.searchBrowserTabs
            && BrowserTabs.runningBrowsers().contains { BrowserTabs.permission(for: $0) != .granted }
        if !trusted || (Settings.showThumbnails && !screenRecording) || chromeNeedsPermission {
            menu.addItem(.separator())
            if !trusted {
                addItem(to: menu, "Autoriser l'accessibilité…", #selector(openAccessibilitySettings))
            }
            if Settings.showThumbnails && !screenRecording {
                addItem(to: menu, "Autoriser l'enregistrement de l'écran (aperçus)…", #selector(openScreenRecordingSettings))
            }
            if chromeNeedsPermission {
                addItem(to: menu, "Autoriser l'accès aux onglets Chrome…", #selector(requestBrowserPermission))
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Pendant ⌘⇥"))
        for shortcut in ["Tape pour chercher (fenêtres et onglets Chrome)", "⇥  ⇧⇥  ← → ↑ ↓   naviguer",
                         "relâcher ⌘ ou ↩   y aller", "⌥W  fermer la fenêtre ou l'onglet", "⌥M  réduire la fenêtre",
                         "⌥H  masquer l'app", "⌥Q  quitter l'app", "esc  annuler"] {
            menu.addItem(withTitle: shortcut, action: nil, keyEquivalent: "").isEnabled = false
        }

        if Settings.windowTiling {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Ranger la fenêtre active (⌃⌥)"))
            for shortcut in ["← →  moitié gauche / droite (encore : ⅓, ⅔)", "↑ ↓  moitié haut / bas (encore : ⅓, ⅔)",
                             "↩  plein écran (encore : taille d'avant)", "C  centrer", "D F G  tiers gauche / centre / droite",
                             "⌫  taille d'origine"] {
                menu.addItem(withTitle: shortcut, action: nil, keyEquivalent: "").isEnabled = false
            }
        }

        menu.addItem(.separator())
        addItem(to: menu, "Quitter Fenestra", #selector(quit), key: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, checked: Bool? = nil, key: String = "") {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        if let checked { item.state = checked ? .on : .off }
    }

    @objc private func toggleEnabled() {
        Settings.isEnabled.toggle()
        applyState()
    }

    @objc private func toggleCycleAppWindows() {
        Settings.cycleAppWindows.toggle()
        applyState()
    }

    @objc private func toggleHideAllShortcut() {
        Settings.hideAllShortcut.toggle()
        applyState()
    }

    @objc private func toggleWindowTiling() {
        Settings.windowTiling.toggle()
        applyState()
    }

    @objc private func toggleBrowserTabs() {
        Settings.searchBrowserTabs.toggle()
        if Settings.searchBrowserTabs { requestBrowserPermission() }
    }

    /// Asks macOS for the permission to read Chrome's tabs, or opens the Automation settings if it was refused.
    @objc private func requestBrowserPermission() {
        let browsers = BrowserTabs.runningBrowsers()
        DispatchQueue.global(qos: .userInitiated).async {
            let refused = browsers.contains { BrowserTabs.permission(for: $0, ask: true) == .denied }
            guard refused else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
    }

    @objc private func toggleThumbnails() {
        if Settings.showThumbnails && !CGPreflightScreenCaptureAccess() {
            return openScreenRecordingSettings()
        }
        Settings.showThumbnails.toggle()
        if Settings.showThumbnails && !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            openScreenRecordingSettings()
        }
    }

    @objc private func toggleWindowlessApps() {
        Settings.showWindowlessApps.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.messageText = "Impossible de modifier l'ouverture à la session"
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
