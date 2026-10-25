import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Window previews. Needs the Screen Recording permission; without it the switcher shows app icons.
///
/// The window server only renders windows that are actually displayed: windows parked in the Stage Manager
/// strip, for instance, capture as blank images. So previews are taken whenever windows are visible (after
/// focus changes, regularly for the front window, and when the switcher opens), kept in memory and on disk,
/// and the switcher shows each window as it last looked.
final class ThumbnailProvider {
    static let maxPixelSize: CGFloat = 460

    /// Latest preview per window. Main thread only.
    private(set) var cache: [CGWindowID: CGImage] = [:]
    private let queue = DispatchQueue(label: "Fenestra.thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    /// Only touched on `queue`.
    private var disk = DiskCache()
    private var timer: Timer?
    private var pendingCapture: DispatchWorkItem?

    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }
    private var isActive: Bool { Settings.isEnabled && Settings.showThumbnails && isAuthorized }

    func startBackgroundCapture() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.captureFrontWindows(limit: 1) }
        windowsDidChange()
    }

    /// Call after focus changes: captures the newly visible windows once Stage Manager's animation has settled.
    func windowsDidChange() {
        pendingCapture?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.captureFrontWindows(limit: 4) }
        pendingCapture = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
    }

    private func captureFrontWindows(limit: Int) {
        guard isActive, PrivateAPI.canCaptureWindows else { return }
        queue.async {
            for window in Self.frontWindows(limit: limit) {
                guard let image = Self.capture(window.id) else { continue }
                self.disk.save(image, window.id, pid: window.pid)
                DispatchQueue.main.async { self.cache[window.id] = image }
            }
        }
    }

    /// Shows the previews we already have for `windows` (memory, then disk), then captures them again.
    /// Blank captures are ignored, so a window that can't be captured right now keeps its last preview.
    func refresh(_ windows: [SwitcherItem], onImage: @escaping (CGWindowID, CGImage) -> Void) {
        let current = lock.withLock { generation += 1; return generation }
        let ids = Set(windows.map(\.windowID))
        cache = cache.filter { ids.contains($0.key) }
        guard isActive, !windows.isEmpty else { return }

        let missing = windows.filter { cache[$0.windowID] == nil }
        let isCurrent = { [weak self] in self?.lock.withLock { self?.generation == current } ?? false }
        let deliver = { [weak self] (id: CGWindowID, image: CGImage) in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[id] = image
                if isCurrent() { onImage(id, image) }
            }
        }

        queue.async {
            for window in missing where isCurrent() {
                if let image = self.disk.load(window.windowID, pid: window.pid) { deliver(window.windowID, image) }
            }
            if PrivateAPI.canCaptureWindows {
                for window in windows where isCurrent() {
                    guard let image = Self.capture(window.windowID) else { continue }
                    self.disk.save(image, window.windowID, pid: window.pid)
                    deliver(window.windowID, image)
                }
            } else {
                let ids = windows.map(\.windowID)
                Task.detached(priority: .userInitiated) {
                    await Self.captureWithScreenCaptureKit(ids, isCurrent: isCurrent, deliver: deliver)
                }
            }
            self.disk.pruneIfNeeded()
        }
    }

    /// Stops delivering images from the running refresh.
    func cancel() {
        lock.withLock { generation += 1 }
    }

    /// A downscaled preview, or nil when the window server has nothing to show for this window right now.
    private static func capture(_ id: CGWindowID) -> CGImage? {
        guard let image = PrivateAPI.captureWindow(id).flatMap(downscaled), !isBlank(image) else { return nil }
        return image
    }

    /// The front-most windows of regular apps on screen: the ones the window server can capture.
    private static func frontWindows(limit: Int) -> [(id: CGWindowID, pid: pid_t)] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [(id: CGWindowID, pid: pid_t)] = []
        for entry in list where windows.count < limit {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            windows.append((id, pid))
        }
        return windows
    }

    private static func captureWithScreenCaptureKit(_ windowIDs: [CGWindowID], isCurrent: () -> Bool,
                                                    deliver: (CGWindowID, CGImage) -> Void) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in windowIDs where isCurrent() {
            guard let window = windows[id], window.frame.width > 1, window.frame.height > 1 else { continue }
            let scale = min(2, maxPixelSize / max(window.frame.width, window.frame.height))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
               !isBlank(image) {
                deliver(id, image)
            }
        }
    }

    /// True when less than half of the capture is drawn: what the window server returns for a window it does
    /// not render (fully transparent, or a small scaled-down fragment for a Stage Manager strip window).
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 128 }.count
        return opaque < side * side / 2
    }

    private static func downscaled(_ image: CGImage) -> CGImage? {
        guard image.width > 1, image.height > 1 else { return nil }
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxPixelSize else { return image }
        let scale = maxPixelSize / longest
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Previews saved on disk so that they survive a restart of Fenestra. Window IDs only mean something
/// until the Mac restarts, so previews are filed per boot and named after the owner PID and window ID.
private struct DiskCache {
    private let folder: URL
    private var lastSave: [CGWindowID: Date] = [:]
    private var lastPrune = Date.distantPast

    init() {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Fenestra", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        folder = root.appendingPathComponent(Self.bootID(), isDirectory: true)
        for old in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != folder.lastPathComponent {
            try? fileManager.removeItem(at: old)
        }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func bootID() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        return "boot-\(bootTime.tv_sec)"
    }

    func load(_ id: CGWindowID, pid: pid_t) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(id, pid) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              !ThumbnailProvider.isBlank(image) else { return nil }
        return image
    }

    /// At most one write per window every 30 s: previews are refreshed far more often than that.
    mutating func save(_ image: CGImage, _ id: CGWindowID, pid: pid_t) {
        let now = Date()
        guard now.timeIntervalSince(lastSave[id] ?? .distantPast) > 30,
              let destination = CGImageDestinationCreateWithURL(url(id, pid) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        lastSave[id] = now
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Every few minutes, deletes the previews of windows that no longer exist.
    mutating func pruneIfNeeded() {
        guard Date().timeIntervalSince(lastPrune) > 300 else { return }
        lastPrune = Date()
        let alive = Set((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let id = file.deletingPathExtension().lastPathComponent.split(separator: "-").last.flatMap { CGWindowID($0) }
            if let id, !alive.contains(id) { try? FileManager.default.removeItem(at: file) }
        }
        lastSave = lastSave.filter { alive.contains($0.key) }
    }

    private func url(_ id: CGWindowID, _ pid: pid_t) -> URL {
        folder.appendingPathComponent("\(pid)-\(id).png")
    }
}
