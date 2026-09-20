import AppKit
import ApplicationServices

final class ShortcutController {
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var items: [CutItem] = []
    private(set) var isMoving = false
    private(set) var isCapturing = false
    enum AccessState: String {
        case checking, needsAccessibility, tapUnavailable, ready
    }

    private(set) var accessState: AccessState = .checking
    var isEnabled: Bool {
        guard let tap else { return false }
        return AXIsProcessTrusted() && CGEvent.tapIsEnabled(tap: tap)
    }

    var accessMessage: String {
        switch accessState {
        case .checking: return "Tastaturzugriff wird geprüft …"
        case .needsAccessibility: return "macOS hat dieser laufenden App keine Bedienungshilfen-Rechte erteilt."
        case .tapUnavailable: return "Bedienungshilfen sind freigegeben, aber macOS konnte den Tastaturfilter nicht starten. Bitte CMD-X neu starten."
        case .ready: return "Bereit: ⌘X und ⌘V sind für Dateien im Finder aktiviert."
        }
    }

    private func setAccessState(_ state: AccessState) {
        guard accessState != state else { return }
        accessState = state
        NSLog("[CMD-X] keyboard access state=%@", state.rawValue)
        onChange?()
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var clipboardVersion = NSPasteboard.general.changeCount
    private var captureDeadline: TimeInterval = 0
    private static let forwardedEventTag: Int64 = 0x434D4458
    private enum RouteAction {
        case pending
        case forward(Int64?)
        case consume
    }
    private final class KeyRoute {
        let key: Int64
        let pid: pid_t
        let generation: UUID
        var events: [CGEvent]
        var action: RouteAction = .pending
        var released = false
        init(key: Int64, pid: pid_t, generation: UUID, event: CGEvent) {
            self.key = key
            self.pid = pid
            self.generation = generation
            events = [event]
        }
    }
    private var routedKeys: [Int64: KeyRoute] = [:]
    private var generation = UUID()

    func start() {
        if let tap {
            guard AXIsProcessTrusted() else { stop(); return }
            CGEvent.tapEnable(tap: tap, enable: true)
            setAccessState(CGEvent.tapIsEnabled(tap: tap) ? .ready : .tapUnavailable)
            return
        }
        guard AXIsProcessTrusted() else {
            setAccessState(.needsAccessibility)
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setAccessState(.tapUnavailable)
            return
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.pollClipboard() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setAccessState(.ready)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        routedKeys.removeAll()
        setAccessState(AXIsProcessTrusted() ? .checking : .needsAccessibility)
        if !isMoving { reset() }
    }

    func cancel() {
        guard !isMoving else { return }
        reset()
    }

    private func reset() {
        items = []
        isCapturing = false
        generation = UUID()
        onChange?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[CMD-X] event tap disabled (%@); enabling again", String(type.rawValue))
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.forwardedEventTag {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if let route = routedKeys[key], !(route.released && type == .keyDown) {
            if type == .keyUp { route.released = true }
            switch route.action {
            case .pending:
                if let copy = event.copy() { route.events.append(copy) }
                return nil
            case .forward(let replacement):
                // A held cut key must not repeatedly replace our captured clipboard.
                if type == .keyDown && replacement != nil { return nil }
                if type == .keyUp { routedKeys.removeValue(forKey: key) }
                remap(event, key: replacement)
                return Unmanaged.passUnretained(event)
            case .consume:
                if type == .keyUp { routedKeys.removeValue(forKey: key) }
                return nil
            }
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if key == 8, modifiers == .maskCommand { reset(); return Unmanaged.passUnretained(event) }
        let isCut = key == 7 && modifiers == .maskCommand
        let isPaste = key == 9 && (modifiers == .maskCommand || modifiers == [.maskCommand, .maskAlternate])
        guard isCut || isPaste,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder",
              let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        // An ordinary paste needs no AX inspection or interception.
        if isPaste && items.isEmpty && !isCapturing && !isMoving { return Unmanaged.passUnretained(event) }
        let route = KeyRoute(key: key, pid: app.processIdentifier, generation: generation, event: copy)
        routedKeys[key] = route
        NSLog("[CMD-X] Finder shortcut received: %@", isCut ? "cut" : "paste")
        // Finder must receive control again before we ask its main thread about AX.
        // No Accessibility RPC or clipboard/file read runs in the event-tap callback.
        DispatchQueue.main.async { [weak self] in self?.processShortcut(route, isCut: isCut) }
        return nil
    }

    private func processShortcut(_ route: KeyRoute, isCut: Bool) {
        guard tap != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == route.pid,
              route.generation == generation else {
            NSLog("[CMD-X] deferred shortcut cancelled: application or clipboard intent changed")
            resolve(route, action: .consume)
            return
        }
        let focus = FinderContext.inspectFileFocus()
        NSLog("[CMD-X] Finder focus: %@", focus.detail)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == route.pid,
              route.generation == generation else {
            resolve(route, action: .consume)
            return
        }
        guard focus.isFileView else {
            // Replay the original down/up sequence for text editing and unknown focus.
            resolve(route, action: .forward(nil))
            return
        }
        pollClipboard()
        if isMoving || (!isCut && isCapturing) {
            resolve(route, action: .consume)
            return
        }
        if isCut {
            reset()
            isCapturing = true
            clipboardVersion = NSPasteboard.general.changeCount
            captureDeadline = ProcessInfo.processInfo.systemUptime + 1.5
            NSLog("[CMD-X] requesting native Finder copy")
            onChange?()
            resolve(route, action: .forward(8))
            return
        }
        guard !items.isEmpty else {
            resolve(route, action: .forward(nil))
            return
        }
        resolve(route, action: .consume)
        isMoving = true
        let currentGeneration = generation
        let movingItems = items
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onChange?()
            FinderMover.move(movingItems) { [weak self] result in
                guard let self else { return }
                self.isMoving = false
                let pasteboard = NSPasteboard.general
                if self.generation == currentGeneration && pasteboard.changeCount == self.clipboardVersion {
                    self.items = result.remaining
                    // Discard stale native file references after success; on partial
                    // success, retain only the failed items. Never touch newer copies.
                    pasteboard.clearContents()
                    if !result.remaining.isEmpty {
                        pasteboard.writeObjects(result.remaining.map { $0.url as NSURL })
                    }
                    self.clipboardVersion = pasteboard.changeCount
                } else {
                    self.reset()
                }
                self.onChange?()
                if let message = result.message { self.onError?(message) }
            }
        }
    }

    private func resolve(_ route: KeyRoute, action: RouteAction) {
        route.action = action
        if case .forward(let replacement) = action {
            for event in route.events {
                if replacement != nil && event.type == .keyDown &&
                    event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { continue }
                remap(event, key: replacement)
                event.setIntegerValueField(.eventSourceUserData, value: Self.forwardedEventTag)
                event.postToPid(route.pid)
            }
        }
        route.events.removeAll()
        if route.released, routedKeys[route.key] === route {
            routedKeys.removeValue(forKey: route.key)
        }
    }

    private func remap(_ event: CGEvent, key: Int64?) {
        guard let key else { return }
        event.setIntegerValueField(.keyboardEventKeycode, value: key)
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(99)])
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        if isCapturing {
            if pasteboard.changeCount != clipboardVersion {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
                    reset()
                    return
                }
                clipboardVersion = pasteboard.changeCount
                isCapturing = false
                let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                var seen = Set<URL>()
                items = urls.filter { seen.insert($0).inserted }.compactMap { CutItem(url: $0) }
                if items.count != seen.count { items = [] }
                NSLog("[CMD-X] Finder clipboard captured: %d file URL(s), %d cut item(s)", urls.count, items.count)
                onChange?()
            } else if ProcessInfo.processInfo.systemUptime > captureDeadline {
                NSLog("[CMD-X] Finder copy timed out: clipboard did not change")
                reset()
            }
        } else if !items.isEmpty && pasteboard.changeCount != clipboardVersion {
            reset()
        }
    }
}
