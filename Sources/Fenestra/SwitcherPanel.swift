import AppKit

/// The floating ⌘⇥ overlay: a search bar, window previews in a grid, matching Chrome tabs as rows,
/// apps without windows as a row of icons, and the selected item's full title at the bottom.
/// Always dark, like a HUD.
final class SwitcherPanel: NSPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private enum Layout {
        static let margin: CGFloat = 22
        static let searchTop: CGFloat = 16
        static let searchHeight: CGFloat = 36
        static let contentTop: CGFloat = searchTop + searchHeight + 16
        static let gap: CGFloat = 10
        static let appTile: CGFloat = 64
        static let appGap: CGFloat = 4
        static let tabHeader: CGFloat = 22
        static let tabRow: CGFloat = 32
        static let tabGap: CGFloat = 2
        static let emptyHeight: CGFloat = 64
        static let sectionGap: CGFloat = 21
        static let footerHeight: CGFloat = 46
        static let minWidth: CGFloat = 560
        static let cornerRadius: CGFloat = 30
    }

    private let container = FlippedView()
    private let searchBackground = NSView()
    private let searchIcon = NSImageView()
    private let searchField = NSTextField(labelWithString: "")
    private let caret = NSView()
    private let tabsHeader = NSTextField(labelWithString: "Onglets Chrome")
    private let emptyField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let separator = NSView()
    private var tiles: [SwitcherTile] = []
    private var items: [SwitcherItem] = []
    private var query = ""
    private var mouseLocationAtPresent = NSPoint.zero

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu // after isFloatingPanel, which resets the level to .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        searchBackground.wantsLayer = true
        searchBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        searchBackground.layer?.cornerRadius = 11
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        searchIcon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        searchField.font = .systemFont(ofSize: 15)
        searchField.lineBreakMode = .byTruncatingHead
        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        caret.layer?.cornerRadius = 1
        tabsHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        tabsHeader.textColor = NSColor.white.withAlphaComponent(0.45)
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = NSColor.white.withAlphaComponent(0.5)
        emptyField.alignment = .center
        emptyField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        for view in [searchBackground, searchIcon, searchField, caret, tabsHeader, emptyField, separator, titleField] {
            container.addSubview(view)
        }
        container.autoresizingMask = [.width, .height]
        contentView = Self.makeBackground(containing: container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func makeBackground(containing content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Layout.cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.45)
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Layout.cornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    func present(_ items: [SwitcherItem], selection: Int, thumbnails: [CGWindowID: CGImage], query: String = "") {
        self.items = items
        self.query = query
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        layoutTiles(on: screen, thumbnails: thumbnails)
        select(selection)
        guard !isVisible else { return }
        mouseLocationAtPresent = mouse
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        items = []
    }

    func select(_ index: Int) {
        for tile in tiles { tile.isSelected = tile.index == index }
        titleField.attributedStringValue = items.indices.contains(index) ? Self.footer(for: items[index]) : NSAttributedString()
    }

    func setThumbnail(_ image: CGImage, for windowID: CGWindowID) {
        for case let tile as WindowTileView in tiles where tile.windowID == windowID { tile.setThumbnail(image) }
    }

    /// The tile in the row above or below `index` that is closest horizontally, wrapping around.
    func index(from index: Int, verticalStep step: Int) -> Int? {
        guard let current = tiles.first(where: { $0.index == index }) else { return nil }
        let rows = Set(tiles.map { $0.frame.midY.rounded() }).sorted()
        guard let row = rows.firstIndex(of: current.frame.midY.rounded()) else { return nil }
        let target = rows[((row + step) % rows.count + rows.count) % rows.count]
        return tiles
            .filter { $0.frame.midY.rounded() == target }
            .min { abs($0.frame.midX - current.frame.midX) < abs($1.frame.midX - current.frame.midX) }?
            .index
    }

    private static func footer(for item: SwitcherItem) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let primary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.6), .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: item.appName, attributes: primary)
        var details: [String] = []
        if let tab = item.tab {
            details.append(item.title.isEmpty ? tab.url : item.title)
            if !tab.host.isEmpty { details.append(tab.host) }
        } else if !item.isWindow {
            details.append("aucune fenêtre ouverte")
        } else if item.displayTitle != item.appName {
            details.append(item.displayTitle)
        }
        if let space = item.spaceLabel { details.append(space) }
        if item.isMinimized { details.append("réduite") } else if item.isHidden { details.append("masquée") }
        if !details.isEmpty { text.append(NSAttributedString(string: "   " + details.joined(separator: "  ·  "), attributes: secondary)) }
        return text
    }

    private func hovered(_ index: Int) {
        // The panel appears under a still cursor: only a real mouse move selects a tile.
        guard NSEvent.mouseLocation != mouseLocationAtPresent else { return }
        onHover?(index)
    }

    private func layoutTiles(on screen: NSScreen, thumbnails: [CGWindowID: CGImage]) {
        tiles.forEach { $0.removeFromSuperview() }
        let area = screen.visibleFrame
        // While open, the panel keeps its width and its top edge: typing only changes what is below.
        let keptFrame: NSRect? = isVisible ? frame : nil
        let maxWidth = keptFrame?.width ?? area.width * 0.86
        let maxHeight = area.height * 0.84
        let windowIndices = items.indices.filter { items[$0].isWindow }
        let tabIndices = items.indices.filter { items[$0].isTab }
        let appIndices = items.indices.filter { items[$0].isApp }

        // Apps without windows: compact rows of icons.
        let appColumns = max(1, Int((maxWidth - 2 * Layout.margin + Layout.appGap) / (Layout.appTile + Layout.appGap)))
        let appRows = (appIndices.count + appColumns - 1) / appColumns
        let appsHeight = appRows == 0 ? 0 : CGFloat(appRows) * (Layout.appTile + Layout.appGap) - Layout.appGap
        let appsWidth = CGFloat(min(appIndices.count, appColumns)) * (Layout.appTile + Layout.appGap) - Layout.appGap
        let tabsHeight = tabIndices.isEmpty ? 0 : Layout.tabHeader + CGFloat(tabIndices.count) * (Layout.tabRow + Layout.tabGap) - Layout.tabGap
        let emptyHeight = items.isEmpty ? Layout.emptyHeight : 0

        func gridHeight(rows: Int, _ metrics: TileMetrics) -> CGFloat {
            rows == 0 ? 0 : CGFloat(rows) * metrics.tileSize.height + CGFloat(rows - 1) * Layout.gap
        }
        func panelHeight(gridHeight: CGFloat) -> CGFloat {
            let sections = [gridHeight, tabsHeight, appsHeight, emptyHeight].filter { $0 > 0 }
            return Layout.contentTop + sections.reduce(0, +) + CGFloat(max(0, sections.count - 1)) * Layout.sectionGap + Layout.footerHeight
        }

        // Window previews: shrink them until the whole panel fits on screen.
        var metrics = TileMetrics(scale: 1)
        var columns = 1, rows = 0
        if !windowIndices.isEmpty {
            for scale in stride(from: 1.0, through: 0.45, by: -0.05) {
                metrics = TileMetrics(scale: scale)
                let fitting = Int((maxWidth - 2 * Layout.margin + Layout.gap) / (metrics.tileSize.width + Layout.gap))
                columns = max(1, min(windowIndices.count, fitting))
                rows = (windowIndices.count + columns - 1) / columns
                if panelHeight(gridHeight: gridHeight(rows: rows, metrics)) <= maxHeight { break }
            }
            columns = (windowIndices.count + rows - 1) / rows // spread tiles evenly across rows
        }

        let tile = metrics.tileSize
        let gridWidth = rows == 0 ? 0 : CGFloat(columns) * tile.width + CGFloat(columns - 1) * Layout.gap
        let width = keptFrame?.width ?? min(max(max(gridWidth, appsWidth) + 2 * Layout.margin, Layout.minWidth), area.width)
        let height = panelHeight(gridHeight: gridHeight(rows: rows, metrics))
        let frame = (keptFrame.map { NSRect(x: $0.minX, y: $0.maxY - height, width: width, height: height) }
            ?? NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)).integral
        setFrame(frame, display: true)
        container.frame = NSRect(origin: .zero, size: frame.size)
        layoutSearchBar(width: frame.width)

        func rowStart(count: Int, itemWidth: CGFloat, gap: CGFloat) -> CGFloat {
            (frame.width - (CGFloat(count) * (itemWidth + gap) - gap)) / 2
        }

        var newTiles: [SwitcherTile] = []
        var y = Layout.contentTop
        var isFirstSection = true
        /// Moves `y` past the gap between sections; returns where the gap starts.
        func startSection() -> CGFloat? {
            defer { isFirstSection = false }
            guard !isFirstSection else { return nil }
            y += Layout.sectionGap
            return y - Layout.sectionGap
        }

        if rows > 0 {
            _ = startSection()
            for (position, index) in windowIndices.enumerated() {
                let row = position / columns, column = position % columns
                let x = rowStart(count: min(columns, windowIndices.count - row * columns), itemWidth: tile.width, gap: Layout.gap)
                    + CGFloat(column) * (tile.width + Layout.gap)
                let item = items[index]
                let view = WindowTileView(index: index, item: item, thumbnail: thumbnails[item.windowID], metrics: metrics)
                view.frame.origin = NSPoint(x: x.rounded(), y: (y + CGFloat(row) * (tile.height + Layout.gap)).rounded())
                newTiles.append(view)
            }
            y += gridHeight(rows: rows, metrics)
        }

        tabsHeader.isHidden = tabIndices.isEmpty
        if !tabIndices.isEmpty {
            _ = startSection()
            tabsHeader.frame = NSRect(x: Layout.margin + 10, y: y, width: frame.width - 2 * Layout.margin, height: 16)
            y += Layout.tabHeader
            for index in tabIndices {
                let view = TabRowView(index: index, item: items[index], width: frame.width - 2 * Layout.margin)
                view.frame.origin = NSPoint(x: Layout.margin, y: y)
                newTiles.append(view)
                y += Layout.tabRow + Layout.tabGap
            }
            y -= Layout.tabGap
        }

        separator.isHidden = true
        if !appIndices.isEmpty {
            if let gapStart = startSection() {
                separator.isHidden = false
                separator.frame = NSRect(x: Layout.margin * 2, y: gapStart + Layout.sectionGap / 2, width: frame.width - Layout.margin * 4, height: 1)
            }
            for (position, index) in appIndices.enumerated() {
                let row = position / appColumns, column = position % appColumns
                let x = rowStart(count: min(appColumns, appIndices.count - row * appColumns), itemWidth: Layout.appTile, gap: Layout.appGap)
                    + CGFloat(column) * (Layout.appTile + Layout.appGap)
                let view = AppTileView(index: index, item: items[index], side: Layout.appTile)
                view.frame.origin = NSPoint(x: x.rounded(), y: (y + CGFloat(row) * (Layout.appTile + Layout.appGap)).rounded())
                newTiles.append(view)
            }
            y += appsHeight
        }

        emptyField.isHidden = !items.isEmpty
        if items.isEmpty {
            _ = startSection()
            emptyField.stringValue = "Aucune fenêtre ni aucun onglet pour « \(query) »"
            emptyField.frame = NSRect(x: Layout.margin, y: y + 22, width: frame.width - 2 * Layout.margin, height: 20)
            y += emptyHeight
        }

        for view in newTiles {
            view.onHover = { [weak self] index in self?.hovered(index) }
            view.onClick = { [weak self] index in self?.onClick?(index) }
            container.addSubview(view)
        }
        tiles = newTiles
        titleField.frame = NSRect(x: Layout.margin, y: y + 12, width: frame.width - 2 * Layout.margin, height: 20)
    }

    /// A search field look-alike: the panel never takes the keyboard focus, the event tap feeds it.
    private func layoutSearchBar(width: CGFloat) {
        searchBackground.frame = NSRect(x: Layout.margin, y: Layout.searchTop, width: width - 2 * Layout.margin, height: Layout.searchHeight)
        searchIcon.frame = NSRect(x: Layout.margin + 12, y: Layout.searchTop + 10, width: 16, height: 16)
        let textX = Layout.margin + 36
        let textWidth = width - 2 * Layout.margin - 48
        if query.isEmpty {
            searchField.stringValue = "Tape pour chercher une fenêtre ou un onglet Chrome"
            searchField.textColor = NSColor.white.withAlphaComponent(0.35)
        } else {
            searchField.stringValue = query
            searchField.textColor = .white
        }
        searchField.frame = NSRect(x: textX, y: Layout.searchTop + 8, width: textWidth, height: 20)
        let typedWidth = min(ceil(searchField.attributedStringValue.size().width), textWidth)
        caret.isHidden = query.isEmpty
        caret.frame = NSRect(x: textX + typedWidth + 2, y: Layout.searchTop + 9, width: 2, height: 18)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

struct TileMetrics {
    static let padding: CGFloat = 10
    static let labelHeight: CGFloat = 16
    let scale: CGFloat

    var thumbSize: CGSize { CGSize(width: (208 * scale).rounded(), height: (130 * scale).rounded()) }
    var tileSize: CGSize {
        CGSize(width: thumbSize.width + 2 * Self.padding,
               height: thumbSize.height + 2 * Self.padding + 8 + Self.labelHeight)
    }
}

/// Selection highlight and mouse handling shared by the two kinds of tiles.
class SwitcherTile: NSView {
    let index: Int
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { updateAppearance() } }
    }

    init(index: Int, size: CGSize, cornerRadius: CGFloat) {
        self.index = index
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func updateAppearance() {
        layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.15).cgColor : nil
        layer?.borderWidth = isSelected ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?(index) } }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(index) }
    }
}

/// A window: its preview with the app icon on the corner, the title below.
/// Until a preview exists, a stylized window with the app icon stands in for it.
final class WindowTileView: SwitcherTile {
    let windowID: CGWindowID

    private let item: SwitcherItem
    private let thumbArea: CGRect
    private let shadowView = NSView()
    private let preview = FlippedView()
    private let trafficLights = (0..<3).map { _ in NSView() }
    private let bigIcon = NSImageView()
    private let appBadge = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let pills: [NSView]

    init(index: Int, item: SwitcherItem, thumbnail: CGImage?, metrics: TileMetrics) {
        self.item = item
        windowID = item.windowID
        let padding = TileMetrics.padding
        thumbArea = CGRect(origin: CGPoint(x: padding, y: padding), size: metrics.thumbSize)
        pills = [item.spaceLabel, item.isMinimized ? "Réduite" : item.isHidden ? "Masquée" : nil]
            .compactMap { $0 }
            .map(Self.pill)
        super.init(index: index, size: metrics.tileSize, cornerRadius: 14)

        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.35
        shadowView.layer?.shadowRadius = 6
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(shadowView)

        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.layer?.contentsGravity = .resize
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        for dot in trafficLights {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            preview.addSubview(dot)
        }
        addSubview(preview)

        bigIcon.image = item.app.icon
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(bigIcon)

        appBadge.image = item.app.icon
        appBadge.imageScaling = .scaleProportionallyUpOrDown
        appBadge.wantsLayer = true
        appBadge.layer?.shadowOpacity = 0.4
        appBadge.layer?.shadowRadius = 3
        appBadge.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(appBadge)

        pills.forEach { addSubview($0) }

        titleField.stringValue = item.displayTitle
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = CGRect(x: padding, y: thumbArea.maxY + 8, width: thumbArea.width, height: TileMetrics.labelHeight)
        addSubview(titleField)

        setThumbnail(thumbnail)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setThumbnail(_ image: CGImage?) {
        let shape = image.map { CGSize(width: $0.width, height: $0.height) } ?? item.size
        let frame = shape.width > 0 && shape.height > 0 ? Self.fit(shape, in: thumbArea) : thumbArea
        preview.frame = frame
        shadowView.frame = frame
        shadowView.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: 8, cornerHeight: 8, transform: nil)
        preview.layer?.contents = image
        preview.layer?.backgroundColor = image == nil ? NSColor.white.withAlphaComponent(0.07).cgColor : nil
        preview.alphaValue = item.isMinimized || item.isHidden ? 0.55 : 1

        // Placeholder: a stylized window (traffic lights + big app icon).
        for (offset, dot) in trafficLights.enumerated() {
            dot.isHidden = image != nil
            dot.frame = CGRect(x: 9 + CGFloat(offset) * 10, y: 8, width: 6, height: 6)
            dot.layer?.cornerRadius = 3
        }
        let side = min(frame.height * 0.45, 56)
        bigIcon.frame = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2 + 4, width: side, height: side)
        bigIcon.isHidden = image != nil

        let badge: CGFloat = thumbArea.height > 90 ? 30 : 22
        appBadge.frame = CGRect(x: frame.minX - 6, y: frame.maxY - badge + 6, width: badge, height: badge)
        appBadge.isHidden = image == nil

        var x = frame.minX + 6
        for pill in pills {
            pill.frame.origin = CGPoint(x: x, y: frame.minY + 6)
            pill.isHidden = pill.frame.maxX > frame.maxX - 4
            x = pill.frame.maxX + 4
        }
    }

    override func updateAppearance() {
        super.updateAppearance()
        titleField.font = .systemFont(ofSize: 11.5, weight: isSelected ? .semibold : .medium)
        titleField.textColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.7)
    }

    private static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = (size.width * scale).rounded(), height = (size.height * scale).rounded()
        return CGRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(), width: width, height: height)
    }

    private static func pill(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: label.frame.width + 12, height: label.frame.height + 4))
        label.frame.origin = CGPoint(x: 6, y: 2)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        view.layer?.cornerRadius = view.frame.height / 2
        view.addSubview(label)
        return view
    }
}

/// A browser tab in the search results: browser icon, tab title, site on the right.
final class TabRowView: SwitcherTile {
    private let titleField: NSTextField

    init(index: Int, item: SwitcherItem, width: CGFloat) {
        let host = item.tab?.host ?? ""
        titleField = NSTextField(labelWithString: item.title.isEmpty ? host : item.title)
        super.init(index: index, size: CGSize(width: width, height: 32), cornerRadius: 9)

        let icon = NSImageView(frame: CGRect(x: 10, y: 7, width: 18, height: 18))
        icon.image = item.app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let site = NSTextField(labelWithString: host)
        site.font = .systemFont(ofSize: 12)
        site.textColor = NSColor.white.withAlphaComponent(0.45)
        site.alignment = .right
        site.lineBreakMode = .byTruncatingHead
        site.sizeToFit()
        let siteWidth = min(site.frame.width, width * 0.35)
        site.frame = CGRect(x: width - 12 - siteWidth, y: 8, width: siteWidth, height: 16)
        addSubview(site)

        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = CGRect(x: 38, y: 7, width: site.frame.minX - 50, height: 18)
        addSubview(titleField)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateAppearance() {
        super.updateAppearance()
        titleField.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        titleField.textColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.8)
    }
}

/// An app without windows: just its icon (the footer shows its name).
final class AppTileView: SwitcherTile {
    init(index: Int, item: SwitcherItem, side: CGFloat) {
        super.init(index: index, size: CGSize(width: side, height: side), cornerRadius: 14)
        let icon = NSImageView(frame: bounds.insetBy(dx: 9, dy: 9))
        icon.image = item.app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = item.isHidden ? 0.45 : 1
        addSubview(icon)
        toolTip = item.appName
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
