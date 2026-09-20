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
    var isEnabled: Bool { tap != nil && AXIsProcessTrusted() }

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
    private var remappedCutKey = false
    private var swallowedKeys = Set<Int64>()
    private var generation = UUID()

    func start() {
        guard tap == nil else { return }
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
        remappedCutKey = false
        swallowedKeys.removeAll()
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if key == 7, remappedCutKey {
                remappedCutKey = false
                event.setIntegerValueField(.keyboardEventKeycode, value: 8)
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(99)])
            } else if swallowedKeys.remove(key) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if swallowedKeys.contains(key) { return nil }
        if key == 7, remappedCutKey { return nil }
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        // Copying anywhere cancels cut intent even before Finder refreshes the clipboard.
        if key == 8, modifiers == .maskCommand { reset(); return Unmanaged.passUnretained(event) }
        let isCut = key == 7 && modifiers == .maskCommand
        let isPaste = key == 9 && (modifiers == .maskCommand || modifiers == [.maskCommand, .maskAlternate])
        guard isCut || isPaste else { return Unmanaged.passUnretained(event) }
        pollClipboard()
        guard FinderContext.hasFileFocus() else { return Unmanaged.passUnretained(event) }
        if isMoving || (isPaste && isCapturing) {
            swallowedKeys.insert(key)
            return nil
        }
        if isCut {
            reset()
            isCapturing = true
            clipboardVersion = NSPasteboard.general.changeCount
            captureDeadline = ProcessInfo.processInfo.systemUptime + 1.5
            // Let Finder produce its native file clipboard, including multiple items.
            // This modifies the original event, with no synthetic-event recursion.
            event.setIntegerValueField(.keyboardEventKeycode, value: 8)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(99)])
            remappedCutKey = true
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
            return Unmanaged.passUnretained(event)
        }
        guard !items.isEmpty else { return Unmanaged.passUnretained(event) }
        swallowedKeys.insert(key)
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
        return nil
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
                onChange?()
            } else if ProcessInfo.processInfo.systemUptime > captureDeadline {
                reset()
            }
        } else if !items.isEmpty && pasteboard.changeCount != clipboardVersion {
            reset()
        }
    }
}
