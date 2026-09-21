import AppKit
import ApplicationServices

final class ShortcutController {
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var items: [CutItem] = []
    private(set) var isMoving = false
    private(set) var isCapturing = false
    enum AccessState: String {
        case checking, needsAccessibility, needsPostEventAccess, tapUnavailable, ready
    }

    private(set) var accessState: AccessState = .checking
    var isEnabled: Bool {
        guard let tap else { return false }
        return AXIsProcessTrusted() && CGPreflightPostEventAccess() && CGEvent.tapIsEnabled(tap: tap)
    }

    var accessMessage: String {
        switch accessState {
        case .checking: return "Tastaturzugriff wird geprüft …"
        case .needsAccessibility: return "macOS hat dieser laufenden App keine Bedienungshilfen-Rechte erteilt."
        case .needsPostEventAccess: return "macOS hat Tastatureingriffe für diese App noch nicht freigegeben."
        case .tapUnavailable: return "Die Freigaben sind vorhanden, aber der Tastaturfilter ist nicht aktiv."
        case .ready: return "Bereit: ⌘X und ⌘V sind für Dateien im Finder aktiviert."
        }
    }

    private func setAccessState(_ state: AccessState) {
        guard accessState != state else { return }
        accessState = state
        NSLog("[CMD-X] keyboard access state=%@", state.rawValue)
        onChange?()
    }

    private(set) var lastShortcut = "Noch kein ⌘X/⌘V empfangen."
    private(set) var lastFocus = "Noch nicht geprüft."
    private(set) var lastOperation = "Noch keine Dateiaktion."
    private var shortcutCount = 0

    var diagnosticReport: String {
        let tapEnabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        return """
        CMD-X Diagnose: permission-flow-2
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: \(Bundle.main.bundleURL.path)
        Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")
        PID: \(ProcessInfo.processInfo.processIdentifier)
        AX trusted: \(AXIsProcessTrusted())
        PostEvent allowed: \(CGPreflightPostEventAccess())
        Event tap created: \(tap != nil)
        Event tap enabled: \(tapEnabled)
        State: \(accessState.rawValue)
        Shortcuts received: \(shortcutCount)
        Last shortcut: \(lastShortcut)
        Last Finder focus: \(lastFocus)
        Last operation: \(lastOperation)
        Pending items: \(items.count)
        Capturing: \(isCapturing); moving: \(isMoving)
        """
    }

    // Explicit user action only. Let macOS show its own consent UI; never also
    // open System Settings or request a second permission in the same action.
    func requestAccess() {
        if !CGPreflightPostEventAccess() {
            NSLog("[CMD-X] requesting PostEvent consent")
            _ = CGRequestPostEventAccess()
        } else if !AXIsProcessTrusted() {
            NSLog("[CMD-X] requesting AX consent")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        start()
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
        guard AXIsProcessTrusted() else {
            if tap != nil { stop() }
            setAccessState(.needsAccessibility)
            return
        }
        guard CGPreflightPostEventAccess() else {
            if tap != nil { stop() }
            setAccessState(.needsPostEventAccess)
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            setAccessState(CGEvent.tapIsEnabled(tap: tap) ? .ready : .tapUnavailable)
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
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            setAccessState(.tapUnavailable)
            return
        }
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.pollClipboard() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setAccessState(CGEvent.tapIsEnabled(tap: newTap) ? .ready : .tapUnavailable)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        routedKeys.removeAll()
        if !AXIsProcessTrusted() { setAccessState(.needsAccessibility) }
        else if !CGPreflightPostEventAccess() { setAccessState(.needsPostEventAccess) }
        else { setAccessState(.checking) }
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
        if isCut || isPaste {
            shortcutCount += 1
            lastShortcut = "\(isCut ? "⌘X" : "⌘V") – \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")"
        }
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
        lastFocus = focus.detail
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
            lastOperation = "Finder copy requested"
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
                lastOperation = "Finder clipboard: \(urls.count) URLs, \(items.count) cut items"
                NSLog("[CMD-X] Finder clipboard captured: %d file URL(s), %d cut item(s)", urls.count, items.count)
                onChange?()
            } else if ProcessInfo.processInfo.systemUptime > captureDeadline {
                lastOperation = "Finder copy timed out; clipboard unchanged"
                NSLog("[CMD-X] Finder copy timed out: clipboard did not change")
                reset()
            }
        } else if !items.isEmpty && pasteboard.changeCount != clipboardVersion {
            reset()
        }
    }
}
