import AppKit

/// Drives one ⌘⇥ session: list the windows → show the panel after a short delay → focus the chosen window.
/// Typing searches the windows and the Chrome tabs; the panel then stays open until ↩ or Esc.
final class SwitcherController {
    /// Quick ⌘⇥ taps switch to the previous window without ever flashing the panel.
    private static let panelDelay: TimeInterval = 0.09

    private let interceptor: KeyboardInterceptor
    private let windowManager = WindowManager()
    private let thumbnails = ThumbnailProvider()
    private lazy var panel: SwitcherPanel = {
        let panel = SwitcherPanel()
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.selection = index
            self?.activateSelection()
        }
        return panel
    }()

    /// Everything listed for the session. `items` is what the panel shows: the same list, or the search results.
    private var allItems: [SwitcherItem] = []
    private var tabs: [SwitcherItem] = []
    private var items: [SwitcherItem] = []
    private var query = ""
    /// For ⌘` / ⌘<: the app whose windows (and tabs) are listed.
    private var onlyPID: pid_t?
    private var isFetchingTabs = false
    private var selection = 0
    private var session = 0
    private var isLoading = false
    private var pendingSteps = 0
    private var confirmWhenLoaded = false
    private var showTask: DispatchWorkItem?

    init(interceptor: KeyboardInterceptor) {
        self.interceptor = interceptor
    }

    /// Call once the Accessibility permission is granted.
    func start() {
        windowManager.onFocusChange = { [weak self] in self?.thumbnails.windowsDidChange() }
        windowManager.startTracking()
        thumbnails.startBackgroundCapture()
    }

    func handle(_ command: SwitcherCommand) {
        switch command {
        case .begin(let backward, let appOnly): begin(backward: backward, appOnly: appOnly)
        case .step(let delta): step(delta)
        case .stepRow(let delta): stepRow(delta)
        case .confirm: confirm()
        case .cancel: end()
        case .action(let key): perform(key)
        case .type(let text): type(text)
        case .deleteBackward: deleteBackward()
        case .toggleHideAll, .tile: break // handled by the app delegate
        }
    }

    /// `appOnly`: cycle through the front app's windows only (⌘` / ⌘<).
    private func begin(backward: Bool, appOnly: Bool) {
        reset()
        let current = session
        isLoading = true
        pendingSteps = backward ? -1 : 1
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        onlyPID = appOnly ? frontPID : nil
        let startedAt = Date()

        windowManager.fetchItems(frontPID: frontPID, includeWindowlessApps: Settings.showWindowlessApps && !appOnly) { [weak self] items in
            guard let self, session == current, isLoading else { return }
            isLoading = false
            let items = appOnly ? items.filter { $0.isWindow && $0.pid == frontPID } : items
            // Nothing to cycle through with a single window of the app.
            guard items.count > (appOnly ? 1 : 0) else { return end() }
            allItems = items

            // Typed before the list arrived: go straight to the results.
            if !query.isEmpty {
                fetchTabsIfNeeded()
                return applySearch()
            }
            self.items = items
            // Index 0 is normally the window we come from, so ⌘⇥ lands on index 1 —
            // unless the front app has no window in the list (e.g. Finder on the desktop).
            let comesFromFirst = items[0].isWindow && items[0].pid == frontPID
            selection = wrapped((pendingSteps > 0 && !comesFromFirst ? -1 : 0) + pendingSteps)
            if confirmWhenLoaded { return activateSelection() }

            let task = DispatchWorkItem { [weak self] in self?.showPanel() }
            showTask = task
            let delay = max(0, Self.panelDelay - Date().timeIntervalSince(startedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }

    private func showPanel() {
        showTask?.cancel()
        showTask = nil
        let isFirstShow = !panel.isVisible
        let showThumbnails = Settings.showThumbnails
        panel.present(items, selection: selection, thumbnails: showThumbnails ? thumbnails.cache : [:], query: query)
        guard isFirstShow else { return }
        // Reading the tabs takes a few tenths of a second: start while the user looks at the panel,
        // so they are there when the search begins. Quick ⌘⇥ taps never get here.
        fetchTabsIfNeeded()
        guard showThumbnails else { return }

        thumbnails.refresh(allItems.filter(\.isWindow)) { [weak self] id, image in
            self?.panel.setThumbnail(image, for: id)
        }
    }

    // MARK: - Search

    private func type(_ text: String) {
        query += text
        guard !isLoading else { return } // applied when the list arrives
        fetchTabsIfNeeded()
        applySearch()
    }

    private func deleteBackward() {
        guard !query.isEmpty else { return }
        query.removeLast()
        if !isLoading { applySearch() }
    }

    private func applySearch() {
        if query.isEmpty {
            items = allItems
            selection = 0
        } else {
            (items, selection) = Search.results(for: query, in: allItems + tabs)
        }
        showPanel()
    }

    private func fetchTabsIfNeeded() {
        guard Settings.searchBrowserTabs, tabs.isEmpty, !isFetchingTabs else { return }
        isFetchingTabs = true
        let current = session
        BrowserTabs.fetch { [weak self] tabs in
            guard let self, session == current else { return }
            isFetchingTabs = false
            let windows = allItems.filter(\.isWindow)
            let onlyPID = onlyPID
            self.tabs = tabs.filter { tab in
                // The active tab of a listed window is already there as that window.
                let shownAsWindow = tab.tab!.isActive && windows.contains { $0.pid == tab.pid && $0.title.hasPrefix(tab.title) }
                return !shownAsWindow && (onlyPID == nil || tab.pid == onlyPID)
            }
            if !query.isEmpty && !self.tabs.isEmpty { applySearch() }
        }
    }

    // MARK: - Navigation

    private func step(_ delta: Int) {
        if isLoading {
            pendingSteps += delta
        } else if !items.isEmpty {
            select(wrapped(selection + delta))
        }
    }

    /// ↑ / ↓ move to the closest tile in the row above / below, wrapping around.
    private func stepRow(_ delta: Int) {
        guard !isLoading, let target = panel.index(from: selection, verticalStep: delta) else { return }
        select(target)
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        panel.select(index)
    }

    private func confirm() {
        if isLoading {
            confirmWhenLoaded = true
        } else if items.isEmpty {
            end()
        } else {
            activateSelection()
        }
    }

    private func activateSelection() {
        guard items.indices.contains(selection) else { return end() }
        let item = items[selection]
        end()
        if item.isTab {
            BrowserTabs.focus(item)
        } else {
            windowManager.focus(item)
        }
    }

    // MARK: - Actions

    /// ⌥W close (window or tab), ⌥M minimize, ⌥H hide the app, ⌥Q quit the app.
    private func perform(_ key: Character) {
        guard !isLoading, items.indices.contains(selection) else { return }
        let item = items[selection]
        switch key {
        case "w":
            if let tab = item.tab {
                BrowserTabs.close(item)
                // The tabs after it in the same window move up by one.
                tabs.removeAll { $0.tab?.windowID == tab.windowID && $0.tab?.index == tab.index }
                for index in tabs.indices where tabs[index].tab!.windowID == tab.windowID && tabs[index].tab!.index > tab.index {
                    tabs[index].tab!.index -= 1
                }
            } else if item.isWindow {
                windowManager.close(item)
                allItems.removeAll { $0.windowID == item.windowID }
            } else {
                return
            }
        case "m":
            guard item.isWindow else { return }
            windowManager.setMinimized(item, !item.isMinimized)
            for index in allItems.indices where allItems[index].windowID == item.windowID { allItems[index].isMinimized.toggle() }
        case "h":
            let hide = !item.isHidden
            _ = hide ? item.app.hide() : item.app.unhide()
            for index in allItems.indices where allItems[index].pid == item.pid { allItems[index].isHidden = hide }
            for index in tabs.indices where tabs[index].pid == item.pid { tabs[index].isHidden = hide }
        case "q":
            item.app.terminate()
            allItems.removeAll { $0.pid == item.pid }
            tabs.removeAll { $0.pid == item.pid }
        default:
            return
        }

        let previousSelection = selection
        items = query.isEmpty ? allItems : Search.results(for: query, in: allItems + tabs).items
        guard !items.isEmpty || !query.isEmpty else { return end() }
        selection = min(previousSelection, max(0, items.count - 1))
        if panel.isVisible { showPanel() }
    }

    private func end() {
        reset()
        interceptor.isSessionActive = false
    }

    private func reset() {
        session += 1
        isLoading = false
        confirmWhenLoaded = false
        isFetchingTabs = false
        showTask?.cancel()
        showTask = nil
        thumbnails.cancel()
        panel.dismiss()
        allItems = []
        tabs = []
        items = []
        query = ""
        onlyPID = nil
    }

    private func wrapped(_ index: Int) -> Int {
        items.isEmpty ? 0 : ((index % items.count) + items.count) % items.count
    }
}
