import AppKit
import Carbon.HIToolbox

enum SwitcherCommand {
    /// `appOnly`: only the windows of the front app (⌘` / ⌘<).
    case begin(backward: Bool, appOnly: Bool)
    case step(Int)
    case stepRow(Int)
    case confirm
    case cancel
    /// ⌥ + a letter while the switcher is open: W close, M minimize, H hide app, Q quit app.
    case action(Character)
    /// Text typed while the switcher is open: it searches.
    case type(String)
    case deleteBackward
    /// ⌥⌘M: hide every app, or show them back.
    case toggleHideAll
    /// ⌃⌥ + arrow / letter: arrange the front window.
    case tile(TilingAction)
}

/// Watches the keyboard through a CGEventTap that runs on its own thread, so a busy main
/// thread never delays system-wide key events. Commands are delivered on the main thread.
final class KeyboardInterceptor {
    var onCommand: ((SwitcherCommand) -> Void)?

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var sessionActive = false
    private var searching = false
    private var cycleKeyCode: Int?
    private var hideKeyCode: Int?
    private var layoutCharacters: [Int: Character] = [:]
    private var tilingKeyMap: [Int: TilingAction] = [:]

    /// True between ⌘⇥ and the release of ⌘ (or ↩ / Esc once a search started). While true, every key
    /// press is swallowed.
    var isSessionActive: Bool {
        get { lock.withLock { sessionActive } }
        set { lock.withLock { sessionActive = newValue; if !newValue { searching = false } } }
    }

    /// Once something is typed, releasing ⌘ no longer validates: the panel stays open for the search.
    private var isSearching: Bool {
        get { lock.withLock { searching } }
        set { lock.withLock { searching = newValue } }
    }

    /// What each key types without modifier, for ⌥ + letter actions (⌥ changes the typed character).
    var baseCharacters: [Int: Character] {
        get { lock.withLock { layoutCharacters } }
        set { lock.withLock { layoutCharacters = newValue } }
    }

    /// Keys that, held with ⌃⌥, arrange the front window; empty to leave them to the apps.
    var tilingKeys: [Int: TilingAction] {
        get { lock.withLock { tilingKeyMap } }
        set { lock.withLock { tilingKeyMap = newValue } }
    }

    /// The key that, held with ⌘, cycles through the front app's windows; nil to leave it to macOS.
    var windowCycleKeyCode: Int? {
        get { lock.withLock { cycleKeyCode } }
        set { lock.withLock { cycleKeyCode = newValue } }
    }

    /// The key that, held with ⌥⌘, hides / shows back every app; nil to leave it to the apps.
    var hideAllKeyCode: Int? {
        get { lock.withLock { hideKeyCode } }
        set { lock.withLock { hideKeyCode = newValue } }
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let interceptor = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
                return interceptor.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Fenestra.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
        isSessionActive = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .flagsChanged:
            // Releasing ⌘ validates the selection, unless a search is under way. Modifier events always go through.
            if !event.flags.contains(.maskCommand), isSessionActive, !isSearching {
                isSessionActive = false
                send(.confirm)
            }
            return pass
        case .keyDown, .keyUp:
            break
        default:
            return pass
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let cycleKey = windowCycleKeyCode
        guard isSessionActive else {
            guard type == .keyDown else { return pass }
            // Holding the keys must not repeat an arrangement or flip the apps back and forth.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if flags.contains(.maskControl), flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskShift),
               let action = tilingKeys[keyCode] {
                if !isRepeat { send(.tile(action)) }
                return nil
            }
            guard flags.contains(.maskCommand), !flags.contains(.maskControl) else { return pass }
            if flags.contains(.maskAlternate) {
                guard keyCode == hideAllKeyCode, !flags.contains(.maskShift) else { return pass }
                if !isRepeat { send(.toggleHideAll) }
                return nil
            }
            guard keyCode == kVK_Tab || keyCode == cycleKey else { return pass }
            isSessionActive = true
            send(.begin(backward: flags.contains(.maskShift), appOnly: keyCode == cycleKey))
            return nil
        }

        guard type == .keyDown else { return nil }
        if keyCode == cycleKey, !isSearching, !flags.contains(.maskAlternate) {
            send(.step(flags.contains(.maskShift) ? -1 : 1))
            return nil
        }
        switch keyCode {
        case kVK_Tab: send(.step(flags.contains(.maskShift) ? -1 : 1))
        case kVK_RightArrow: send(.step(1))
        case kVK_LeftArrow: send(.step(-1))
        case kVK_DownArrow: send(.stepRow(1))
        case kVK_UpArrow: send(.stepRow(-1))
        case kVK_Escape:
            isSessionActive = false
            send(.cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            isSessionActive = false
            send(.confirm)
        case kVK_Delete:
            send(.deleteBackward)
        default:
            if flags.contains(.maskAlternate) {
                if let character = baseCharacters[keyCode] { send(.action(character)) }
            } else if let text = Self.typedText(of: event) {
                isSearching = true
                send(.type(text))
            }
        }
        return nil
    }

    /// The text a key press types (honouring the keyboard layout), nil for keys that type nothing
    /// visible (function keys, dead keys…).
    private static func typedText(of event: CGEvent) -> String? {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        let text = String(utf16CodeUnits: characters, count: length)
        let isPrintable = !text.isEmpty && text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
        return isPrintable ? text : nil
    }

    /// What each key types without modifier on the current keyboard layout. Main thread only.
    static func layoutCharacterMap() -> [Int: Character] {
        withCurrentLayout { layout in
            var map: [Int: Character] = [:]
            for keyCode in 0..<128 {
                if let character = self.character(ofKeyCode: keyCode, in: layout).lowercased().first { map[keyCode] = character }
            }
            return map
        } ?? [:]
    }

    /// What a key prints with the current keyboard layout ("`" on a US keyboard, "<" on a French one).
    /// Main thread only.
    static func displayName(ofKeyCode keyCode: Int) -> String {
        let name = withCurrentLayout { character(ofKeyCode: keyCode, in: $0) } ?? ""
        return name.isEmpty ? "`" : name
    }

    /// The key that types `character` with the current keyboard layout (M is not at the same place on
    /// AZERTY and QWERTY). Main thread only.
    static func keyCode(typing character: String) -> Int? {
        withCurrentLayout { layout in (0..<128).first { self.character(ofKeyCode: $0, in: layout).lowercased() == character } } ?? nil
    }

    private static func withCurrentLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T) -> T? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        return withExtendedLifetime(source) {
            body(unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self))
        }
    }

    private static func character(ofKeyCode keyCode: Int, in layout: UnsafePointer<UCKeyboardLayout>) -> String {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        return String(utf16CodeUnits: characters, count: length)
    }

    private func send(_ command: SwitcherCommand) {
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
    }
}
